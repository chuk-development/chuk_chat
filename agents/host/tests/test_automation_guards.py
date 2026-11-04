"""Automation guards (docs/WIRE_CONTRACT.md, "Automation guards"; research
H37-H40 and DeepSeek 43): no recursion, a per-agent cap, the model's 5-minute
floor, the catch-up window, the retry ladder after a transient failure, one
alert per incident, and the schedule ``target``."""

from __future__ import annotations

from chuk_agents_runtime import StateStore
from chuk_agents_runtime.automations import (
    MAX_AUTOMATIONS_PER_AGENT,
    RETRY_LADDER_SECONDS,
    register_automation_tools,
)
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_host.automations import EVENT_FIRED, EVENT_RETRY, EVENT_SKIPPED, AutomationManager

S = "agent-1"


class _Clock:
    def __init__(self, now: float = 1_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class _Host:
    def __init__(self) -> None:
        self.fired: list[tuple[str, str, dict]] = []
        self.sent: list[dict] = []

    def fire(self, session_key, prompt, meta):
        self.fired.append((session_key, prompt, meta))
        return f"run-{len(self.fired)}"

    def send(self, payload):
        self.sent.append(payload)


def _manager(tmp_path, host, clock, **kw) -> AutomationManager:
    ws = tmp_path / "ws"
    ws.mkdir(parents=True, exist_ok=True)
    return AutomationManager(
        db_path=str(tmp_path / "state.db"),
        workspace=str(ws),
        fire=host.fire,
        send=host.send,
        clock=clock,
        tick=1000.0,
        poll=1000.0,
        **kw,
    )


# -- no recursion ------------------------------------------------------------------


def test_a_run_an_automation_started_cannot_create_automations(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    parent = m.schedule(S, "every 1h", "p", None)
    fired = m.bound(S).with_origin("automation").for_run("run-1", parent["id"])
    assert fired.can_create() is False
    out = fired.schedule({"every": 3600}, "again", None)
    assert out["ok"] is False and "cannot set up new automations" in out["error"]
    assert fired.start_watcher("w.py", None, True)["ok"] is False
    assert fired.watch_url({"url": "https://example.com"}, "p", None)["ok"] is False
    # The tools that create are left out of the run; list / pause / cancel stay.
    registry = ToolRegistry()
    register_automation_tools(registry, fired)
    names = set(registry.names())
    assert "schedule_task" not in names and "start_watcher" not in names and "watch_url" not in names
    assert {"list_automations", "cancel_automation"} <= names
    # A user run of the same session may.
    user = m.bound(S).with_origin("app")
    assert user.can_create() is True
    assert user.schedule({"every": 3600}, "ok", None)["ok"] is True
    assert m.store.get(user.list()[-1]["id"])["created_by"] == "agent"


def test_the_user_can_allow_chaining_per_row_or_per_agent(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    row = m.create({"session_key": S, "kind": "schedule", "spec": "every 1h", "prompt": "p", "allow_chaining": True})
    assert row["ok"] and row["allow_chaining"] is True and row["created_by"] == "user"
    fired = m.bound(S).with_origin("automation").for_run("r", row["id"])
    assert fired.can_create() is True
    made = fired.schedule({"every": 3600}, "child", None)
    assert made["ok"] and made["created_by"] == "automation"

    m2 = _manager(tmp_path / "b", _Host(), _Clock(), chaining_allowed=lambda key: key == S)
    other = m2.schedule(S, "every 1h", "p", None)
    assert m2.bound(S).with_origin("automation").for_run("r", other["id"]).can_create() is True


def test_cap_per_agent(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock(), max_per_agent=3)
    for _ in range(3):
        assert m.schedule(S, "every 1h", "p", None)["ok"]
    out = m.schedule(S, "every 1h", "p", None)
    assert out["ok"] is False and "limit" in out["error"]
    # Another agent has its own count; a cancelled row frees a slot.
    assert m.schedule("agent-2", "every 1h", "p", None)["ok"]
    first = m.store.list(S)[0]["id"]
    m.control(None, first, "cancel")
    assert m.schedule(S, "every 1h", "p", None)["ok"]
    assert MAX_AUTOMATIONS_PER_AGENT == 50


def test_the_model_floor_is_five_minutes_but_the_user_may_go_lower(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    agent = m.bound(S).with_origin("app")
    out = agent.schedule({"every": 120}, "p", None)
    assert out["ok"] is False and "5 minutes" in out["error"] and "every 30m" in out["error"]
    assert agent.schedule({"cron": "* * * * *"}, "p", None)["ok"] is False
    assert agent.schedule({"every": 300}, "p", None)["ok"] is True
    # The app (the user) may set one minute.
    assert m.create({"session_key": S, "kind": "schedule", "spec": "every 1m", "prompt": "p"})["ok"]


# -- catch-up window ---------------------------------------------------------------


def test_a_missed_run_inside_the_window_fires_late_once(tmp_path):
    host, clock = _Host(), _Clock()
    m = _manager(tmp_path, host, clock)
    row = m.schedule(S, "every 1h", "p", None)  # window = 30 min
    clock.now = row["next_fire_at"] + 20 * 60
    assert m.run_scheduler_once() == 1
    assert len(host.fired) == 1


def test_a_missed_run_past_the_window_is_skipped_and_noted(tmp_path):
    host, clock = _Host(), _Clock()
    m = _manager(tmp_path, host, clock)
    row = m.schedule(S, "every 1h", "p", None)
    due = row["next_fire_at"]
    clock.now = due + 45 * 60
    assert m.run_scheduler_once() == 0
    assert host.fired == []
    after = m.store.get(row["id"])
    assert after["skipped_count"] == 1 and after["last_skip_at"] == clock.now
    assert after["next_fire_at"] > clock.now and "skipped" in after["last_error"]
    skipped = [p for p in host.sent if p.get("event") == EVENT_SKIPPED]
    assert skipped and skipped[0]["missed_at"] == due


def test_daily_job_window_is_two_hours_and_a_row_can_override(tmp_path):
    host, clock = _Host(), _Clock()
    m = _manager(tmp_path, host, clock)
    daily = m.schedule(S, "every 1d", "p", None)
    clock.now = daily["next_fire_at"] + 3 * 3600
    assert m.run_scheduler_once() == 0  # 3 h > 2 h cap
    host2, clock2 = _Host(), _Clock()
    m2 = _manager(tmp_path / "b", host2, clock2)
    row = m2.create({"session_key": S, "kind": "schedule", "spec": "every 1d", "prompt": "p", "catch_up": "6h"})
    assert row["catch_up_seconds"] == 6 * 3600
    clock2.now = row["next_fire_at"] + 3 * 3600
    assert m2.run_scheduler_once() == 1


# -- retry ladder and incidents ------------------------------------------------------


def test_transient_failure_retries_at_5_15_30_min_then_alerts(tmp_path):
    host, clock = _Host(), _Clock()
    m = _manager(tmp_path, host, clock)
    row = m.schedule(S, "every 1d", "p", None)
    clock.now = row["next_fire_at"]
    assert m.run_scheduler_once() == 1
    for step, delay in enumerate(RETRY_LADDER_SECONDS, start=1):
        outcome = m.finish_run(f"run-{step}", row["id"], ok=False, error="ConnectError", transient=True)
        assert outcome["changed"] is False and outcome["retry_at"] == clock.now + delay
        assert any(p.get("event") == EVENT_RETRY for p in host.sent)
        clock.now += delay
        assert m.run_scheduler_once() == 1
        assert host.fired[-1][2]["reason"] == "retry"
    # The ladder is spent: the next failure is told (``None`` = no quiet outcome).
    assert m.finish_run("run-x", row["id"], ok=False, error="ConnectError", transient=True) is None
    # The retries did not move the schedule.
    assert m.store.get(row["id"])["fire_count"] == 1


def test_non_transient_failure_does_not_retry(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    row = m.schedule(S, "every 1h", "p", None)
    assert m.finish_run("r1", row["id"], ok=False, error="tool crashed", transient=False) is None
    assert m.store.get(row["id"])["retry_at"] is None


def test_the_same_error_alerts_once_until_success_or_a_new_error(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    row = m.schedule(S, "every 1h", "p", None)
    assert m.finish_run("r1", row["id"], ok=False, error="login failed at 10:01") is None
    again = m.finish_run("r2", row["id"], ok=False, error="login failed at 11:01")
    assert again == {"changed": False, "reported": False, "repeated_error": True}
    assert m.finish_run("r3", row["id"], ok=False, error="disk full") is None
    m.finish_run("r4", row["id"], ok=True)
    assert m.finish_run("r5", row["id"], ok=False, error="disk full") is None


# -- target --------------------------------------------------------------------------


def test_target_new_once_reuses_one_chat_and_new_opens_one_per_run(tmp_path):
    host, clock = _Host(), _Clock()
    m = _manager(tmp_path, host, clock)
    once = m.bound(S).schedule({"every": 3600}, "p", None, target="new_once")
    each = m.bound(S).schedule({"every": 3600}, "p", None, target="new")
    assert once["target"] == "new_once" and each["target"] == "new"
    for _ in range(2):
        clock.now += 3600
        m.run_scheduler_once()
    sessions = [(meta["automation_id"], key) for key, _p, meta in host.fired]
    once_keys = {key for aid, key in sessions if aid == once["id"]}
    each_keys = [key for aid, key in sessions if aid == each["id"]]
    assert once_keys == {f"{S}#auto-{once['id']}"}
    assert each_keys == [f"{S}#auto-{each['id']}-1", f"{S}#auto-{each['id']}-2"]
    meta = host.fired[0][2]
    assert meta["mode_session_key"] == S
    fired = [p for p in host.sent if p.get("event") == EVENT_FIRED]
    assert fired[0]["run_session_key"].startswith(f"{S}#auto-")
    # The rows stay the owner's: the owner lists them, the derived chat too.
    assert {r["id"] for r in m.list(S)} == {once["id"], each["id"]}
    assert {r["id"] for r in m.bound(f"{S}#auto-{once['id']}").list()} == {once["id"], each["id"]}


def test_a_derived_chat_reports_on_change_results(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    row = m.bound(S).schedule({"every": 3600}, "p", None, notify="on_change", target="new_once")
    derived = m.bound(f"{S}#auto-{row['id']}").with_origin("automation").for_run("run-9", row["id"])
    assert derived.wants_result() is True
    assert derived.record_result(True, "x")["ok"] is True


def test_target_spec_error_carries_copyable_help(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    out = m.schedule(S, "every 1h", "p", None, target="elsewhere")
    assert out["ok"] is False and "'0 9 * * 1-5'" in out["error"]


def test_old_rows_read_as_user_rows(tmp_path):
    m = _manager(tmp_path, _Host(), _Clock())
    row = m.store.create(session_key=S, kind="schedule", name="n", spec={"every": 300}, prompt="p", next_fire_at=1.0)
    assert row["created_by"] == "user" and row["target"] == "this_session"
    state = StateStore(str(tmp_path / "state.db"))
    state.close()


def test_a_retry_whose_fire_fails_stays_due_and_a_one_shot_still_fires(tmp_path):
    """CodeRabbit: ``retry_at`` was cleared before the fire, so a fire that did
    not start (host not ready) dropped the retry; a spent one-shot then stayed
    ``active`` with nothing due, forever."""
    host, clock = _Host(), _Clock()
    m = _manager(tmp_path, host, clock)
    row = m.schedule(S, "in 10m", "remind me", None)
    assert row["ok"]
    clock.now = row["next_fire_at"]
    assert m.run_scheduler_once() == 1
    outcome = m.finish_run("run-1", row["id"], ok=False, error="ConnectError", transient=True)
    retry_at = outcome["retry_at"]
    clock.now = retry_at
    working_fire = m._fire
    m._fire = lambda *a: None  # the host cannot start a run right now
    assert m.run_scheduler_once() == 0
    stored = m.store.get(row["id"])
    assert stored["retry_at"] == retry_at  # still due
    assert stored["state"] == "active"
    m._fire = working_fire
    assert m.run_scheduler_once() == 1
    assert host.fired[-1][2]["reason"] == "retry"
    assert m.store.get(row["id"])["retry_at"] is None


def test_an_update_forwards_allow_chaining_catch_up_and_target(tmp_path):
    """CodeRabbit: the host and the app helper dropped the new update keys."""
    from chuk_agents_executor.protocol import automation_update_payload
    from chuk_agents_host.host import LocalHost

    m = _manager(tmp_path, _Host(), _Clock())
    row = m.create({"session_key": S, "kind": "schedule", "spec": "every 1h", "prompt": "p"})
    payload = automation_update_payload(
        automation_id=row["id"], allow_chaining=True, catch_up="30m", target="new"
    )
    assert payload["allow_chaining"] is True and payload["catch_up"] == "30m" and payload["target"] == "new"
    out = LocalHost._save_automation(m, "automation_update", payload)
    assert out["ok"] is True, out
    stored = m.store.get(row["id"])
    assert stored["allow_chaining"] == 1
    assert stored["target"] == "new"
    assert stored["catch_up_seconds"] == 1800
    # Only one of the new keys: not "nothing to change".
    only = LocalHost._save_automation(
        m, "automation_update", automation_update_payload(automation_id=row["id"], allow_chaining=False)
    )
    assert only["ok"] is True and m.store.get(row["id"])["allow_chaining"] == 0
