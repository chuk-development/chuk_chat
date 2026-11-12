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
