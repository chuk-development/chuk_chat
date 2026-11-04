"""Agent-side automation guards (docs/WIRE_CONTRACT.md, "Automation guards"):
the spec help in errors, ``target``, the model's 5-minute floor, the
catch-up window, the transient-failure test and derived session keys."""

from __future__ import annotations

import socket

from chuk_agents_runtime.automations import (
    MAX_CATCH_UP_SECONDS,
    MIN_CATCH_UP_SECONDS,
    SPEC_HELP,
    RecordingBackend,
    catch_up_window,
    error_digest,
    is_transient_failure,
    owner_session_key,
    parse_catch_up,
    parse_target,
    register_automation_tools,
    schedule_period,
    target_session_key,
)
from chuk_agents_runtime.registry import ToolRegistry


def _registry(backend) -> ToolRegistry:
    registry = ToolRegistry()
    register_automation_tools(registry, backend)
    return registry


def test_a_bad_spec_error_carries_copyable_help():
    out = _registry(RecordingBackend()).dispatch("schedule_task", {"spec": "daily at nine", "prompt": "x"})
    assert out["ok"] is False and SPEC_HELP in out["error"]
    assert "'0 9 * * 1-5'" in out["error"] and "'in 10m'" in out["error"]


def test_the_model_cannot_set_a_schedule_faster_than_five_minutes():
    backend = RecordingBackend()
    reg = _registry(backend)
    assert reg.dispatch("schedule_task", {"spec": "every 2m", "prompt": "x"})["ok"] is False
    assert reg.dispatch("schedule_task", {"spec": "*/1 * * * *", "prompt": "x"})["ok"] is False
    assert reg.dispatch("schedule_task", {"spec": "every 5m", "prompt": "x"})["ok"] is True
    # A one-shot has no period.
    assert reg.dispatch("schedule_task", {"spec": "in 1m", "prompt": "x"})["ok"] is True


def test_target_reaches_the_backend_and_a_bad_one_is_refused():
    backend = RecordingBackend()
    reg = _registry(backend)
    row = reg.dispatch("schedule_task", {"spec": "every 1h", "prompt": "x", "target": "new_once"})
    assert row["target"] == "new_once" and backend.calls[-1][-1] == "new_once"
    bad = reg.dispatch("schedule_task", {"spec": "every 1h", "prompt": "x", "target": "other"})
    assert bad["ok"] is False and SPEC_HELP in bad["error"]
    schema = reg.openai_tool("schedule_task")["function"]["parameters"]
    assert schema["properties"]["target"]["enum"] == ["this_session", "new_once", "new"]


def test_target_on_an_old_backend_is_refused_not_dropped():
    class Old:
        def schedule(self, spec, prompt, name):
            return {"ok": True}

        def start_watcher(self, *a):
            return {"ok": True}

        def list(self):
            return []

        def control(self, *a):
            return {"ok": True}

    reg = _registry(Old())
    out = reg.dispatch("schedule_task", {"spec": "every 1h", "prompt": "x", "target": "new"})
    assert out["ok"] is False


def test_no_creating_tools_in_a_run_that_may_not_create():
    names = set(_registry(RecordingBackend(creating=False)).names())
    assert not names & {"schedule_task", "start_watcher", "watch_url", "watch_mail"}
    assert {"list_automations", "pause_automation", "resume_automation", "cancel_automation"} <= names


def test_period_and_catch_up_window():
    assert schedule_period({"every": 600}) == 600
    assert schedule_period({"cron": "*/5 9 * * *"}) == 300
    assert schedule_period({"at": "2030-01-01T00:00:00+00:00"}) is None
    assert catch_up_window({"every": 60}) == MIN_CATCH_UP_SECONDS
    assert catch_up_window({"every": 3600}) == 1800
    assert catch_up_window({"every": 86400}) == MAX_CATCH_UP_SECONDS
    assert catch_up_window({"cron": "0 9 * * *"}) == MAX_CATCH_UP_SECONDS
    assert catch_up_window({"at": "2030-01-01T00:00:00+00:00"}) == MAX_CATCH_UP_SECONDS
    assert catch_up_window({"every": 86400}, 6 * 3600) == 6 * 3600
    assert parse_catch_up("30m") == 1800 and parse_catch_up(None) is None and parse_catch_up(0) == 0


def test_targets_and_derived_session_keys():
    assert parse_target(None) == "this_session" and parse_target("new-once") == "new_once"
    assert target_session_key("a", "x1", "this_session", 3) == "a"
    assert target_session_key("a", "x1", "new_once", 3) == "a#auto-x1"
    assert target_session_key("a", "x1", "new", 3) == "a#auto-x1-3"
    assert owner_session_key("a#auto-x1-3") == "a" and owner_session_key("a") == "a"


def test_transient_failures_are_network_before_the_model_answered():
    class ConnectError(Exception):
        pass

    wrapped = RuntimeError("model call failed")
    wrapped.__cause__ = ConnectError("boom")
    assert is_transient_failure(wrapped)
    assert is_transient_failure(socket.gaierror("Temporary failure in name resolution"))
    assert is_transient_failure(OSError("[Errno 101] Network is unreachable"))
    assert not is_transient_failure(ValueError("bad tool argument"))
    assert not is_transient_failure(wrapped, model_answered=True)
    assert not is_transient_failure(None)


def test_error_digest_folds_numbers_and_space():
    assert error_digest("timeout at 10:01  id 42") == error_digest("Timeout at 11:59 id 7")
    assert error_digest("disk full") != error_digest("login failed")
