"""The request prefix stays byte-stable from one request to the next (bead
cowork-g85d).

Providers cache the prompt by prefix (Fireworks, RunAnywhere, DeepSeek do it
by themselves). The prefix is: the ``tools`` array (every chat template
renders it before the history), the system prompt, then the history. One byte
that changes early costs the cache everything after it. These tests send real
requests through the production model (OpenAI-compatible SSE on a mock
transport) and compare the bodies.
"""

from __future__ import annotations

import json

import httpx2
from pai_fakes import FakeChatEndpoint, FakeSession, text_turn, tool_turn

from chuk_agents_runtime.context import ContextLadder, LadderConfig
from chuk_agents_runtime.loop import AgentLoop
from chuk_agents_runtime.pai.convert import found_tools
from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore

SYSTEM = "You are a test agent. " * 20


def _registry(run_command=None) -> ToolRegistry:
    reg = ToolRegistry()
    for name in ("run_command", "read_file", "write_file"):
        reg.register(
            name,
            {"description": f"core {name}", "type": "object", "properties": {"x": {"type": "string"}}},
            (run_command if name == "run_command" and run_command else lambda x="": {"ok": True}),
        )
    for name in ("shell_start", "shell_list", "shell_kill", "job_status"):
        reg.register(
            name,
            {"description": f"deferred {name}", "type": "object", "properties": {}},
            (lambda n: (lambda: {"tool": n}))(name),
            deferrable=True,
        )
        reg.defer(name)
    return reg


def _loop(tmp_path, endpoint: FakeChatEndpoint, registry=None, **kwargs) -> AgentLoop:
    model, settings = chuk_chat_model(
        FakeSession(),
        ChukModelSpec(model_id="m"),
        base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )
    return AgentLoop(
        model,
        registry or _registry(),
        StateStore(str(tmp_path / "s.db")),
        model_settings=settings,
        deferred_mode="pai",
        system_prompt=SYSTEM,
        **kwargs,
    )


def _tools(request: dict) -> list[str]:
    return [t["function"]["name"] for t in request["body"].get("tools") or []]


def _canon(value) -> str:
    return json.dumps(value, sort_keys=False, separators=(",", ":"), ensure_ascii=False)


# -- found_tools -------------------------------------------------------------


def test_found_tools_lists_each_tool_once_in_the_order_it_was_found():
    rows = [
        {"role": "user", "content": "go"},
        {
            "role": "tool",
            "name": "search_tools",
            "tool_call_id": "s1",
            "content": {"discovered_tools": [{"name": "shell_list"}, {"name": "shell_start"}]},
        },
        # An unsearched call of a deferred tool counts as found too.
        {
            "role": "assistant",
            "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "job_status", "arguments": {}}}],
        },
        # Found again: no second entry. A string result is read as JSON.
        {
            "role": "tool",
            "name": "search_tools",
            "tool_call_id": "s2",
            "content": json.dumps({"discovered_tools": [{"name": "shell_kill"}, {"name": "shell_list"}]}),
        },
    ]
    order = ["run_command", "shell_start", "shell_list", "shell_kill", "job_status"]
    deferred = ["job_status", "shell_kill", "shell_list", "shell_start"]
    # One search's finds are in registry order, so the result never depends
    # on the order the search ranked them in.
    assert found_tools(rows, deferred=deferred, order=order) == [
        "shell_start",
        "shell_list",
        "job_status",
        "shell_kill",
    ]
    assert found_tools(rows, deferred=[], order=order) == []
    # A core tool is never "found": it is declared anyway.
    assert "run_command" not in found_tools(
        [{"role": "assistant", "tool_calls": [{"function": {"name": "run_command"}}]}],
        deferred=deferred,
        order=order,
    )


# -- two turns, one prefix -----------------------------------------------------


def test_two_consecutive_turns_share_the_prefix_up_to_the_first_new_row(tmp_path):
    endpoint = FakeChatEndpoint([text_turn(["one"]), text_turn(["two"])])
    loop = _loop(tmp_path, endpoint)
    loop.run("s", "hi")
    loop.run("s", "hi")
    first, second = (r["body"] for r in endpoint.requests)
    # The tools array is the first thing a chat template renders.
    assert _canon(first["tools"]) == _canon(second["tools"])
    # The system prompt, then every row the first request carried.
    assert first["messages"][0]["role"] == "system"
    assert _canon(second["messages"][: len(first["messages"])]) == _canon(first["messages"])
    # What follows is only the new turn: the answer and the new prompt.
    assert [m["role"] for m in second["messages"][len(first["messages"]) :]] == ["assistant", "user"]


def test_a_found_tool_is_declared_after_the_core_tools_from_then_on(tmp_path):
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("s1", "search_tools", {"queries": ["shell list"]})]),
            tool_turn([("c1", "shell_list", {})]),
            text_turn(["listed"]),
            text_turn(["hi again"]),
            text_turn(["and again"]),
        ]
    )
    loop = _loop(tmp_path, endpoint)
    loop.run("s", "list my shells")
    loop.run("s", "hi")
    loop.run("s", "hi")
    names = [_tools(r) for r in endpoint.requests]
    assert "shell_list" not in names[0]
    # Once found, the tools sit after the core tools, in one fixed order, and
    # the array is the same on every later request of the conversation.
    assert names[1][:3] == ["run_command", "read_file", "write_file"]
    assert "shell_list" in names[1]
    assert names[1] == names[2] == names[3] == names[4]
    bodies = [r["body"] for r in endpoint.requests]
    assert _canon(bodies[2]["tools"]) == _canon(bodies[3]["tools"]) == _canon(bodies[4]["tools"])
    # A found tool is declared outright, not as a deferred one.
    declared = {t["function"]["name"]: t for t in bodies[3]["tools"]}
    assert "defer_loading" not in declared["shell_list"]


class _DropSearchLadder:
    """Stands in for a context ladder whose summary folded the earlier task
    away: it sends the system prompt and the current task only. The search
    that found the tool is no longer in the payload."""

    config = LadderConfig()
    last_stats = None

    def prepare(self, messages, *, session_id=None, timestamps=None, turn_start=0):
        return [messages[0], *messages[turn_start:]]

    def record_usage(self, usage):
        pass


def test_a_found_tool_stays_declared_when_the_search_leaves_the_payload(tmp_path):
    """Pydantic AI reveals a tool from the search records in the history it
    sends. A summary that folds the search away used to take the tool off
    the next request, which changed the tools array and cost the whole
    cached prefix; the found set is read from the stored rows instead."""
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("s1", "search_tools", {"queries": ["shell list"]})]),
            tool_turn([("c1", "shell_list", {})]),
            text_turn(["listed"]),
            text_turn(["hi again"]),
        ]
    )
    loop = _loop(tmp_path, endpoint, context_ladder=_DropSearchLadder())
    loop.run("s", "list my shells")
    loop.run("s", "hi")
    last_of_first, second = endpoint.requests[2]["body"], endpoint.requests[3]["body"]
    assert not any(m.get("role") == "tool" for m in second["messages"])
    assert _canon(last_of_first["tools"]) == _canon(second["tools"])
    assert "shell_list" in _tools(endpoint.requests[3])


def test_the_found_set_starts_afresh_after_a_long_pause(tmp_path):
    """The idle rule drops the tool traffic before a long pause (the provider
    cache is cold by then), and the found set starts at the same row."""
    import time

    endpoint = FakeChatEndpoint(
        [
            tool_turn([("s1", "search_tools", {"queries": ["shell list"]})]),
            text_turn(["found"]),
            text_turn(["later"]),
        ]
    )
    loop = _loop(tmp_path, endpoint, context_ladder=ContextLadder())
    result = loop.run("s", "find the shell tools")
    # Age every stored row by two hours: the next prompt comes after a pause.
    store = loop.store
    with store._conn() as conn:  # type: ignore[attr-defined]
        conn.execute(
            "UPDATE messages SET created_at = created_at - 7200 WHERE session_id = ?",
            (result.session_id,),
        )
    assert time.time() - store.get_conversation(result.session_id)[-1].created_at > 3600
    loop.run("s", "hi")
    assert "shell_list" in _tools(endpoint.requests[1])
    assert "shell_list" not in _tools(endpoint.requests[2])


def test_the_previous_task_with_its_recall_row_is_a_prefix_of_the_next(tmp_path):
    """A memory recall row follows each prompt. The next task used to drop
    the previous recall row, which changed the payload right after the
    previous prompt and cost the cache the whole previous task."""
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("c1", "run_command", {"x": "ls"})]),
            text_turn(["listed"]),
            text_turn(["two"]),
        ]
    )
    loop = _loop(
        tmp_path,
        endpoint,
        context_ladder=ContextLadder(),
        recall_provider=lambda prompt: [
            {"role_tag": "memory", "role": "user", "content": f"[memory recall]\n- about {prompt}"}
        ],
    )
    loop.run("s", "first task")
    loop.run("s", "second task")
    last_of_first, second = endpoint.requests[1]["body"], endpoint.requests[2]["body"]
    assert _canon(last_of_first["tools"]) == _canon(second["tools"])
    shared = len(last_of_first["messages"])
    assert _canon(second["messages"][:shared]) == _canon(last_of_first["messages"])
    assert any("about first task" in str(m.get("content")) for m in second["messages"])


# -- the recall that runs beside the run (bead chuk_chat-4xc5) ------------------


def _join_recall_threads() -> None:
    import threading

    for thread in threading.enumerate():
        if thread.name == "memory-recall":
            thread.join(5)


def _late_recall_loop(tmp_path, endpoint: FakeChatEndpoint, **kwargs) -> AgentLoop:
    """A loop whose recall answers only after the first request went out, and
    whose ``run_command`` waits for that answer (so the second round is the
    first one that can take it, deterministically)."""
    import time

    def recall(prompt: str) -> list[dict]:
        deadline = time.monotonic() + 5
        while not endpoint.requests and time.monotonic() < deadline:
            time.sleep(0.005)
        return [{"role_tag": "memory", "role": "user", "content": f"[memory recall]\n- about {prompt}"}]

    def run_command(x: str = "") -> dict:
        _join_recall_threads()
        return {"ok": True}

    return _loop(
        tmp_path,
        endpoint,
        registry=_registry(run_command),
        recall_provider=recall,
        recall_wait=0.0,
        **kwargs,
    )


def test_a_late_recall_does_not_hold_the_first_request_and_lands_at_the_tail(tmp_path):
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("c1", "run_command", {"x": "ls"})]),
            text_turn(["listed"]),
            text_turn(["two"]),
        ]
    )
    loop = _late_recall_loop(tmp_path, endpoint, context_ladder=ContextLadder())
    result = loop.run("s", "first task")
    first, second = endpoint.requests[0]["body"], endpoint.requests[1]["body"]
    # The first request went out without the recall...
    assert not any("[memory recall" in str(m.get("content")) for m in first["messages"])
    # ...the second carries it, after everything the first request held.
    assert _canon(second["messages"][: len(first["messages"])]) == _canon(first["messages"])
    assert "about first task" in str(second["messages"][-1].get("content"))
    assert result.timings.recall_ms < 100
    # The next task: the late row stays where it landed, byte for byte.
    loop.run("s", "second task")
    _join_recall_threads()
    third = endpoint.requests[2]["body"]
    assert _canon(third["messages"][: len(second["messages"])]) == _canon(second["messages"])


def test_a_recall_that_misses_a_one_round_run_is_dropped(tmp_path):
    import threading

    release = threading.Event()

    def recall(prompt: str) -> list[dict]:
        release.wait(5)
        return [{"role_tag": "memory", "role": "user", "content": "[memory recall]\n- late"}]

    endpoint = FakeChatEndpoint([text_turn(["hello"]), text_turn(["again"])])
    loop = _loop(tmp_path, endpoint, recall_provider=recall, recall_wait=0.0)
    try:
        result = loop.run("s", "hi")
        assert result.final_answer == "hello"
        assert result.timings.recall_ms < 100
    finally:
        release.set()
        _join_recall_threads()
    # The late answer is not written into the finished run.
    assert all(m.role != "memory" for m in loop.store.get_conversation(result.session_id))
    loop.run("s", "hi")
    first, second = (r["body"] for r in endpoint.requests)
    assert _canon(second["messages"][: len(first["messages"])]) == _canon(first["messages"])


def test_a_recall_back_within_the_wait_sits_right_after_the_prompt(tmp_path):
    endpoint = FakeChatEndpoint([text_turn(["ok"])])
    loop = _loop(
        tmp_path,
        endpoint,
        recall_provider=lambda prompt: [
            {"role_tag": "memory", "role": "user", "content": "[memory recall]\n- fast"}
        ],
        recall_wait=2.0,
    )
    loop.run("s", "question")
    messages = endpoint.requests[0]["body"]["messages"]
    assert messages[-2]["content"] == "question"
    assert messages[-1]["content"] == "[memory recall]\n- fast"
