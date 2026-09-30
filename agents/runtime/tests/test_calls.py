"""``call_user`` / ``call_status``: the agent-side half of "the agent calls the
user" (docs/WIRE_CONTRACT.md, "The agent calls the user")."""

from __future__ import annotations

from datetime import UTC, datetime

from chuk_agents_runtime import MockModelClient, ToolRegistry, build_runtime
from chuk_agents_runtime.automations import parse_schedule_spec
from chuk_agents_runtime.calls import (
    CALL_TOOL_NAMES,
    MAX_REASON_CHARS,
    RecordingCallBackend,
    register_call_tools,
)


def _registry(backend) -> ToolRegistry:
    registry = ToolRegistry()
    register_call_tools(registry, backend)
    return registry


def test_call_user_rings_and_returns_the_call_id_at_once():
    backend = RecordingCallBackend()
    result = _registry(backend).dispatch("call_user", {"reason": " Your pizza is ready. "})
    assert result == "ringing (call_id c1). Check call_status(call_id) later to see if the user answered."
    assert backend.calls == [
        {"call_id": "c1", "reason": "Your pizza is ready.", "urgency": "normal", "state": "ringing"}
    ]


def test_call_user_tells_the_model_when_no_app_is_connected():
    backend = RecordingCallBackend(delivered=False)
    result = _registry(backend).dispatch("call_user", {"reason": "pizza", "urgency": "HIGH"})
    assert result.startswith("ringing (call_id c1); no app is connected right now, the user may miss it.")
    assert backend.calls[0]["urgency"] == "high"


def test_call_user_refuses_an_empty_reason_and_an_unknown_urgency():
    backend = RecordingCallBackend()
    registry = _registry(backend)
    assert registry.dispatch("call_user", {"reason": "  "})["ok"] is False
    assert registry.dispatch("call_user", {"reason": "pizza", "urgency": "later"})["ok"] is False
    assert backend.calls == []


def test_call_user_cuts_a_long_reason():
    backend = RecordingCallBackend()
    _registry(backend).dispatch("call_user", {"reason": "y" * 3000})
    assert len(backend.calls[0]["reason"]) == MAX_REASON_CHARS


def test_call_user_reports_a_backend_refusal():
    class Refusing(RecordingCallBackend):
        def ring(self, reason: str, urgency: str) -> dict:
            return {"ok": False, "error": "calls are off"}

    result = _registry(Refusing()).dispatch("call_user", {"reason": "pizza"})
    assert result == {"ok": False, "error": "calls are off"}


def test_call_status_reads_through_the_bound_backend():
    backend = RecordingCallBackend()
    registry = _registry(backend)
    registry.dispatch("call_user", {"reason": "pizza"})
    assert registry.dispatch("call_status", {"call_id": "c1"})["state"] == "ringing"
    assert registry.dispatch("call_status", {"call_id": "zz"}) == {"ok": False, "error": "not found"}
    assert registry.dispatch("call_status", {"call_id": " "})["ok"] is False


def test_no_backend_means_no_call_tools(tmp_path):
    registry = ToolRegistry()
    register_call_tools(registry, None)
    assert not any(registry.has(name) for name in CALL_TOOL_NAMES)
    loop = build_runtime(
        MockModelClient(["ok"]), db_path=str(tmp_path / "s.db"), workspace=str(tmp_path),
        version_workspace=False, enable_memory=False, enable_mcp=False,
    )
    names = {t["function"]["name"] for t in loop.registry.openai_tools()}
    assert not names & set(CALL_TOOL_NAMES)


def test_build_runtime_offers_the_call_tools_to_the_model(tmp_path):
    loop = build_runtime(
        MockModelClient(["ok"]), db_path=str(tmp_path / "s.db"), workspace=str(tmp_path),
        version_workspace=False, enable_memory=False, enable_mcp=False,
        calls=RecordingCallBackend(),
    )
    names = {t["function"]["name"] for t in loop.registry.openai_tools()}
    assert set(CALL_TOOL_NAMES) <= names


def test_in_spec_is_a_one_shot_relative_time():
    now = datetime(2026, 9, 29, 12, 0, tzinfo=UTC).timestamp()
    assert parse_schedule_spec("in 10m", now=now) == {"at": "2026-09-29T12:10:00+00:00"}
    assert parse_schedule_spec("in: 90", now=now) == {"at": "2026-09-29T12:01:30+00:00"}
    # A short one-shot is fine: the interval floor is for repeating schedules.
    assert parse_schedule_spec("IN 30s", now=now) == {"at": "2026-09-29T12:00:30+00:00"}
