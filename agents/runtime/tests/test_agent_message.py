"""``send_message``: a chat message while the agent keeps working (CHAT-79)."""

from __future__ import annotations

from chuk_agents_runtime.agent_message import (
    MAX_MESSAGE_CHARS,
    MAX_MESSAGES_PER_RUN,
    PROMPT_SECTION,
    register_message_tools,
)
from chuk_agents_runtime.prompt import build_system_prompt
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore


class _Backend:
    def __init__(self, fail: bool = False) -> None:
        self.sent: list[str] = []
        self.fail = fail

    def send(self, text: str) -> dict:
        if self.fail:
            return {"ok": False, "error": "socket gone"}
        self.sent.append(text)
        return {"ok": True}


def _handler(backend):
    registry = ToolRegistry()
    assert register_message_tools(registry, backend) == ["send_message"]
    return registry, lambda **kw: registry.dispatch("send_message", kw)


def test_a_message_goes_out_and_the_run_goes_on():
    backend = _Backend()
    _registry, send = _handler(backend)
    result = send(text="Ich schau mir deine Mails an, dauert etwa eine Minute.")
    assert result["ok"] is True
    assert backend.sent == ["Ich schau mir deine Mails an, dauert etwa eine Minute."]


def test_empty_long_and_too_many_are_refused():
    backend = _Backend()
    _registry, send = _handler(backend)
    assert send(text="  ")["ok"] is False
    assert send(text="x" * (MAX_MESSAGE_CHARS + 1))["ok"] is False
    for _ in range(MAX_MESSAGES_PER_RUN):
        assert send(text="step")["ok"] is True
    assert send(text="one more")["ok"] is False
    assert len(backend.sent) == MAX_MESSAGES_PER_RUN


def test_no_backend_no_tool_and_no_prompt_rule():
    registry = ToolRegistry()
    assert register_message_tools(registry, None) == []
    assert not registry.has("send_message")


def test_the_prompt_rule_rides_with_the_tool():
    registry, _send = _handler(_Backend())
    prompt = build_system_prompt(registry, progress=PROMPT_SECTION)
    assert "send_message" in prompt and "Keep the user informed" in prompt


def test_a_stored_message_replays_as_itself(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("local:Mail:1:abc")
    store.append_message(sid, "user", {"content": "check my mail"})
    mid = store.append_event(sid, {"type": "message", "text": "Looking now."})
    events = store.replay_events(sid)
    mine = [e for e in events if e.get("type") == "message"]
    assert mine == [{"type": "message", "text": "Looking now.", "replay": True, "mid": mid}]


# -- CHAT-89: the loop makes sure the user hears something ---------------

import threading
import time

from chuk_agents_runtime.agent_message import make_interim_writer
from chuk_agents_runtime.loop import AgentLoop
from chuk_agents_runtime.model import MockModelClient, ModelResponse, tool_call_response


def _loop_registry(backend):
    registry = ToolRegistry()
    register_message_tools(registry, backend)
    registry.register(
        "mail_list",
        {"type": "object", "properties": {}},
        lambda: {"mails": []},
    )
    return registry


def _wait_for(predicate, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def test_text_before_the_tools_goes_out_once(tmp_path):
    backend = _Backend()
    model = MockModelClient(
        [tool_call_response(("mail_list", {}), text="Ich schaue in deine Mails."), "Nichts Neues."]
    )
    loop = AgentLoop(model, _loop_registry(backend), StateStore(str(tmp_path / "s.db")))
    result = loop.run("local:Mail:1:a", "Check meine Mails")
    assert backend.sent == ["Ich schaue in deine Mails."]
    assert result.final_answer == "Nichts Neues."


def test_no_text_the_writer_says_it(tmp_path):
    backend = _Backend()
    seen = {}

    def writer(message, tools):
        seen["args"] = (message, list(tools))
        return "Ich schaue gerade in deine Mails."

    model = MockModelClient([tool_call_response(("mail_list", {})), "Nichts Neues."])
    loop = AgentLoop(
        model, _loop_registry(backend), StateStore(str(tmp_path / "s.db")), interim_writer=writer
    )
    loop.run("local:Mail:1:a", "Check meine Mails")
    assert _wait_for(lambda: backend.sent == ["Ich schaue gerade in deine Mails."])
    assert seen["args"] == ("Check meine Mails", ["mail_list"])


def test_model_sent_its_own_message_no_second_one(tmp_path):
    backend = _Backend()
    calls = []
    model = MockModelClient(
        [tool_call_response(("send_message", {"text": "Moment."}), ("mail_list", {})), "ok"]
    )
    loop = AgentLoop(
        model,
        _loop_registry(backend),
        StateStore(str(tmp_path / "s.db")),
        interim_writer=lambda m, t: calls.append(1) or "x",
    )
    loop.run("local:Mail:1:a", "Check meine Mails")
    assert backend.sent == ["Moment."]
    assert calls == []


def test_unattended_run_gets_no_interim(tmp_path):
    backend = _Backend()
    model = MockModelClient([tool_call_response(("mail_list", {}), text="Looking."), "ok"])
    loop = AgentLoop(
        model, _loop_registry(backend), StateStore(str(tmp_path / "s.db")),
        interim_writer=lambda m, t: "x",
    )
    loop.run("local:Mail:1:a", "hourly check", source="schedule")
    time.sleep(0.1)
    assert backend.sent == []


def test_writer_uses_a_fresh_client_and_closes_it():
    closed = []

    class _Client:
        def complete(self, messages):
            assert "Check meine Mails" in messages[0]["content"]
            return ModelResponse(text='"Ich schaue in deine Mails."')

        def close(self):
            closed.append(1)

    write = make_interim_writer(_Client)
    assert write("Check meine Mails", ["mail_list"]) == "Ich schaue in deine Mails."
    assert closed == [1]
