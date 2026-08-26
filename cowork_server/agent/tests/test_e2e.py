"""End-to-end: mock model emits a run_command tool call, then a final answer.

The loop must execute the command via LocalEnvironment, append every message to
SQLite, and return the final answer.
"""

import json

from cowork_agent.environment import LocalEnvironment
from cowork_agent.loop import StopReason
from cowork_agent.model import MockModelClient
from cowork_agent.runtime import build_runtime
from cowork_agent.state import StateStore


def test_run_command_end_to_end(tmp_path):
    db = str(tmp_path / "run.db")
    marker = tmp_path / "made-by-agent.txt"

    # The tool call travels as a <tool_call> block in the assistant content — the
    # one wire format. A stringy timeout still exercises registry coercion.
    run_call = "<tool_call>" + json.dumps(
        {
            "name": "run_command",
            "arguments": {"command": f"echo hello > {marker}", "timeout": "30"},
        }
    ) + "</tool_call>"
    model = MockModelClient([run_call, "I created the file."])

    loop = build_runtime(
        model,
        db_path=db,
        environment=LocalEnvironment(),
        system_prompt="You are a CoWork agent.",
    )
    result = loop.run("e2e-session", "please make a file")

    # returned the final answer
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "I created the file."

    # the command actually ran via LocalEnvironment
    assert marker.exists()
    assert marker.read_text().strip() == "hello"

    # every message persisted, in order, resumable from a fresh store
    store = StateStore(db)
    sid = store.resolve_session("e2e-session")
    assert sid is not None
    convo = store.get_conversation(sid)
    roles = [m.role for m in convo]
    assert roles == ["system", "user", "assistant", "tool", "assistant"]

    tool_msg = convo[3].content
    assert tool_msg["name"] == "run_command"
    assert tool_msg["content"]["exit_code"] == 0
    assert tool_msg["content"]["timed_out"] is False


def test_tool_error_is_captured_not_raised(tmp_path):
    # A failing command returns a non-zero exit in the tool result; the loop
    # keeps going and still finishes cleanly.
    model = MockModelClient(
        [
            '<tool_call>{"name":"run_command","arguments":{"command":"exit 3"}}</tool_call>',
            "done anyway",
        ]
    )
    loop = build_runtime(model, db_path=str(tmp_path / "e.db"))
    result = loop.run("s", "go")
    assert result.final_answer == "done anyway"
    store = StateStore(str(tmp_path / "e.db"))
    convo = store.get_conversation(result.session_id)
    assert convo[-2].content["content"]["exit_code"] == 3
