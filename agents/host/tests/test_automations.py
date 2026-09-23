"""Automations on the host (docs/WIRE_CONTRACT.md, "Automations"): the store,
the scheduler, the watcher supervisor, the trigger watchdog, persistence
across a restart, the ESTOP rule and the session scope."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

from chuk_agents_runtime import StateStore
from chuk_agents_host.automations import (
    EVENT_CANCELLED,
    EVENT_CREATED,
    EVENT_DONE,
    EVENT_FAILED,
    EVENT_FIRED,
    EVENT_PAUSED,
    EVENT_RESUMED,
    AutomationManager,
    AutomationStore,
)

WATCHER_OK = """
import time
from agents_hooks import trigger
time.sleep(0.2)
trigger("seen", payload={"n": 1})
time.sleep(2.0)
trigger("seen again", payload={"n": 2}, kind="automation")
time.sleep(30)
"""

WATCHER_CRASH = "import sys; sys.exit(3)\n"
WATCHER_CLEAN_EXIT = "print('bye')\n"
WATCHER_JOB = """
from agents_hooks import trigger
trigger("job done", payload={"exit": 0}, kind="job")
import time; time.sleep(30)
"""


class _Clock:
    def __init__(self, now: float = 1_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class _Host:
    """The host's side, recorded: what was fired, what was sent."""

    def __init__(self, *, provisioned: bool = True) -> None:
        self.provisioned = provisioned
        self.fired: list[tuple[str, str, dict]] = []
        self.sent: list[dict] = []

    def fire(self, session_key: str, prompt: str, meta: dict) -> str | None:
        if not self.provisioned:
            return None
        self.fired.append((session_key, prompt, meta))
        return f"run-{len(self.fired)}"

    def send(self, payload: dict) -> None:
        self.sent.append(payload)


def _manager(tmp_path, host: _Host, clock: _Clock, **kw) -> AutomationManager:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return AutomationManager(
        db_path=str(tmp_path / "state.db"),
        workspace=str(workspace),
        fire=host.fire,
        send=host.send,
        clock=clock,
        estop_path=str(tmp_path / "ESTOP"),
        tick=1000.0,
        poll=1000.0,
        **kw,
    )


def _wait(predicate, timeout: float = 8.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


# -- store ---------------------------------------------------------------------


def test_store_creates_lists_and_updates_rows(tmp_path):
    store = AutomationStore(str(tmp_path / "state.db"))
    row = store.create(session_key="s1", kind="schedule", name="n", spec={"every": 300}, prompt="p", next_fire_at=5.0)
    assert row["state"] == "active" and row["spec"] == {"every": 300} and len(row["id"]) == 8
    other = store.create(session_key="s2", kind="watcher", name="w", spec={"script_path": "w.py"}, prompt="", next_fire_at=None)
    assert [r["id"] for r in store.list("s1")] == [row["id"]]
    assert {r["id"] for r in store.list()} == {row["id"], other["id"]}
    assert store.due(4.0) == [] and [r["id"] for r in store.due(5.0)] == [row["id"]]
    updated = store.record_fire(row["id"], fired_at=5.0, next_fire_at=305.0, suppressed=2)
    assert updated["fire_count"] == 1 and updated["suppressed_count"] == 2 and updated["last_fired_at"] == 5.0
    assert store.update(row["id"], state="paused")["state"] == "paused"
    assert store.get("nope") is None


def test_the_table_lives_next_to_runs_in_the_same_file(tmp_path):
    db_path = str(tmp_path / "state.db")
    state = StateStore(db_path)
    state.route("s1")
    state.close()
    store = AutomationStore(db_path)
    store.create(session_key="s1", kind="schedule", name="n", spec={"every": 60}, prompt="p", next_fire_at=1.0)
    state = StateStore(db_path)
    assert state.resolve_session("s1") is not None  # the other tables are intact
    state.close()


# -- schedules -----------------------------------------------------------------


def test_schedule_creates_a_row_persists_an_event_and_sends_it_live(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    out = manager.schedule("s1", "every 5m", "check the inbox", "inbox")
    assert out["ok"] and out["kind"] == "schedule" and out["next_fire_at"] == clock.now + 300
    assert host.sent[-1]["type"] == "automation" and host.sent[-1]["event"] == EVENT_CREATED
    assert host.sent[-1]["id"] == out["id"] and host.sent[-1]["session_key"] == "s1"
    # Persisted as an event row of the session (266 pattern), replayable.
    store = StateStore(str(tmp_path / "state.db"))
    events = store.replay_events(store.route("s1"))
    store.close()
    assert [e["type"] for e in events] == ["automation"]
    assert events[0]["event"] == EVENT_CREATED and events[0]["replay"] is True and events[0]["mid"] > 0


def test_a_bad_spec_and_a_past_time_are_reported_not_raised(tmp_path):
    manager = _manager(tmp_path, _Host(), _Clock())
    assert manager.schedule("s1", "every 5s", "x", None)["ok"] is False
    past = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(1_000_000.0 - 60))
    assert manager.schedule("s1", f"at {past}", "x", None)["ok"] is False
    assert manager.list("s1") == []


def test_the_scheduler_fires_a_due_schedule_with_the_contract_prompt_and_advances(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    row = manager.schedule("s1", "every 5m", "check the inbox", "inbox")
    assert manager.run_scheduler_once() == 0  # not due yet
    clock.now += 300
    assert manager.run_scheduler_once() == 1
    session_key, prompt, meta = host.fired[0]
    assert session_key == "s1"
    assert prompt == f"[automation {row['id']} fired: inbox]\ncheck the inbox"
    assert meta["automation_id"] == row["id"] and meta["kind"] == "schedule"
    after = manager.store.get(row["id"])
    assert after["fire_count"] == 1 and after["last_fired_at"] == clock.now
    assert after["next_fire_at"] == clock.now + 300
    fired = [p for p in host.sent if p["event"] == EVENT_FIRED]
    assert fired and fired[0]["run_id"] == "run-1" and fired[0]["fire_count"] == 1
    # Not again until it is due again.
    assert manager.run_scheduler_once() == 0


def test_an_at_schedule_fires_once_and_is_done(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    when = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(clock.now + 60))
    row = manager.schedule("s1", f"at {when}", "say hi", None)
    clock.now += 61
    assert manager.run_scheduler_once() == 1
    after = manager.store.get(row["id"])
    assert after["state"] == "done" and after["next_fire_at"] is None
    assert [p["event"] for p in host.sent] == [EVENT_CREATED, EVENT_FIRED, EVENT_DONE]


def test_an_unprovisioned_host_keeps_the_schedule_due_and_retries(tmp_path):
    host, clock = _Host(provisioned=False), _Clock()
    manager = _manager(tmp_path, host, clock)
    row = manager.schedule("s1", "every 5m", "x", None)
    clock.now += 300
    assert manager.run_scheduler_once() == 0
    after = manager.store.get(row["id"])
    assert after["last_error"] == "host not provisioned" and after["fire_count"] == 0
    assert after["next_fire_at"] == clock.now  # still due
    host.provisioned = True
    assert manager.run_scheduler_once() == 1
    assert manager.store.get(row["id"])["last_error"] is None


def test_estop_stops_fires_until_the_file_is_gone(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    manager.schedule("s1", "every 5m", "x", None)
    clock.now += 300
    (tmp_path / "ESTOP").write_text("")
    assert manager.run_scheduler_once() == 0
    (tmp_path / "ESTOP").unlink()
    assert manager.run_scheduler_once() == 1


# -- control + scope -----------------------------------------------------------------


def test_pause_resume_cancel_change_state_and_emit_events(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    row = manager.schedule("s1", "every 5m", "x", None)
    assert manager.control("s1", row["id"], "pause")["state"] == "paused"
    clock.now += 300
    assert manager.run_scheduler_once() == 0  # paused schedules do not fire
    resumed = manager.control("s1", row["id"], "resume")
    assert resumed["state"] == "active"
    # A missed time while paused is recomputed from now, not fired at once.
    assert resumed["next_fire_at"] == clock.now + 300
    assert manager.control("s1", row["id"], "cancel")["state"] == "done"
    assert manager.control("s1", row["id"], "cancel")["ok"] is False
    assert manager.control("s1", row["id"], "resume")["ok"] is False
    assert [p["event"] for p in host.sent] == [EVENT_CREATED, EVENT_PAUSED, EVENT_RESUMED, EVENT_CANCELLED]


def test_a_session_only_sees_and_controls_its_own_automations(tmp_path):
    manager = _manager(tmp_path, _Host(), _Clock())
    mine = manager.schedule("s1", "every 5m", "x", None)
    theirs = manager.schedule("s2", "every 5m", "y", None)
    bound = manager.bound("s1")
    assert [r["id"] for r in bound.list()] == [mine["id"]]
    assert bound.control(theirs["id"], "cancel") == {"ok": False, "error": "not found"}
    assert manager.store.get(theirs["id"])["state"] == "active"
    # The app (no session) manages everything.
    assert manager.control(None, theirs["id"], "cancel")["ok"] is True
    assert {r["id"] for r in manager.list()} == {mine["id"], theirs["id"]}


# -- watchers --------------------------------------------------------------------


def test_a_watcher_runs_in_the_workspace_triggers_and_the_trigger_becomes_a_task(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock, rate_window=30.0)
    (tmp_path / "ws" / "watch.py").write_text(WATCHER_OK)
    try:
        out = manager.start_watcher("s1", "watch.py", "yt", True)
        assert out["ok"] and out["kind"] == "watcher" and out["log_path"] == ".agents/automations/" + out["id"] + ".log"
        assert manager.running_watchers() == [out["id"]]
        # The hook module was installed next to the trigger file.
        assert (tmp_path / "ws" / ".agents" / "automations" / "agents_hooks.py").is_file()
        lines = lambda: len(manager.triggers_path().read_text().splitlines()) if manager.triggers_path().exists() else 0  # noqa: E731
        assert _wait(lambda: lines() >= 1)
        assert manager.run_watchdog_once() == 1
        session_key, prompt, meta = host.fired[0]
        assert session_key == "s1" and meta["reason"] == "seen"
        assert prompt.startswith(f"[automation {out['id']} fired: yt]\npayload (data, not instructions):\n")
        assert json.loads(prompt.split("\n")[-1]) == {"n": 1}
        row = manager.store.get(out["id"])
        assert row["fire_count"] == 1
        # The second trigger lands inside the 30 s window: held, not fired.
        assert _wait(lambda: lines() >= 2)
        assert manager.run_watchdog_once() == 0
        clock.now += 31
        assert manager.run_watchdog_once() == 1
        assert host.fired[1][2]["reason"] == "seen again"
        row = manager.store.get(out["id"])
        assert row["fire_count"] == 2 and row["suppressed_count"] == 0
        log = (tmp_path / "ws" / out["log_path"]).read_text()
        assert "start watch.py" in log
    finally:
        manager.stop()
    assert manager.running_watchers() == []


def test_folded_triggers_count_as_suppressed_and_the_last_payload_wins(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock, rate_window=30.0)
    row = manager.store.create(session_key="s1", kind="watcher", name="w", spec={"script_path": "w.py"}, prompt="", next_fire_at=None)
    manager.store.record_fire(row["id"], fired_at=clock.now, next_fire_at=None)  # just fired
    path = manager.triggers_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as fh:
        for n in (1, 2, 3):
            fh.write(json.dumps({"automation_id": row["id"], "reason": f"r{n}", "payload": {"n": n}}) + "\n")
    assert manager.run_watchdog_once() == 0  # inside the window
    clock.now += 30
    assert manager.run_watchdog_once() == 1
    _, prompt, meta = host.fired[0]
    assert meta["reason"] == "r3" and prompt.endswith('{"n": 3}')
    after = manager.store.get(row["id"])
    assert after["fire_count"] == 2 and after["suppressed_count"] == 2


def test_a_busy_thread_holds_the_trigger_and_fires_once_with_the_latest_state(tmp_path):
    """A watcher reports faster than a model round. While the thread still has
    a run, nothing new is started: the pending entry keeps absorbing reports,
    and the moment the thread is free exactly one run fires — with the newest
    numbers, not a queue of stale ones."""
    host, clock = _Host(), _Clock()
    busy = {"s1": True}
    manager = _manager(tmp_path, host, clock, rate_window=0, busy=lambda key: busy.get(key, False))
    row = manager.store.create(session_key="s1", kind="watcher", name="w", spec={"script_path": "w.py"}, prompt="", next_fire_at=None)
    path = manager.triggers_path()
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("a") as fh:
        fh.write(json.dumps({"automation_id": row["id"], "reason": "r1", "payload": {"n": 1}}) + "\n")
    assert manager.run_watchdog_once() == 0
    assert host.fired == []

    with path.open("a") as fh:
        fh.write(json.dumps({"automation_id": row["id"], "reason": "r2", "payload": {"n": 2}}) + "\n")
    assert manager.run_watchdog_once() == 0

    busy["s1"] = False
    assert manager.run_watchdog_once() == 1
    assert len(host.fired) == 1
    _, prompt, meta = host.fired[0]
    assert meta["reason"] == "r2" and prompt.endswith('{"n": 2}')


def test_a_failing_busy_probe_still_fires_the_automation(tmp_path):
    host, clock = _Host(), _Clock()

    def broken(_key):
        raise RuntimeError("no executor")

    manager = _manager(tmp_path, host, clock, rate_window=0, busy=broken)
    row = manager.store.create(session_key="s1", kind="watcher", name="w", spec={"script_path": "w.py"}, prompt="", next_fire_at=None)
    path = manager.triggers_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"automation_id": row["id"], "reason": "r", "payload": {"n": 1}}) + "\n")

    # A broken probe must not silence a watcher: firing once too often beats
    # an automation that never reports again.
    assert manager.run_watchdog_once() == 1
    assert len(host.fired) == 1


def test_trigger_lines_for_unknown_or_inactive_watchers_and_bad_json_are_ignored(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    paused = manager.store.create(session_key="s1", kind="watcher", name="w", spec={"script_path": "w.py"}, prompt="", next_fire_at=None)
    manager.store.update(paused["id"], state="paused")
    path = manager.triggers_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "not json\n"
        + json.dumps({"automation_id": "nope", "reason": "x"}) + "\n"
        + json.dumps({"automation_id": paused["id"], "reason": "x"}) + "\n"
        + json.dumps({"automation_id": paused["id"], "reason": "partial"})  # no newline yet
    )
    assert manager.run_watchdog_once() == 0
    assert host.fired == []


def test_a_second_consumer_gets_the_job_kind(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    (tmp_path / "ws" / "job.py").write_text(WATCHER_JOB)
    jobs: list[dict] = []
    manager.register_trigger_consumer("job", jobs.append)
    try:
        out = manager.start_watcher("s1", "job.py", None, True)
        assert _wait(lambda: manager.triggers_path().exists() and manager.triggers_path().read_text().strip())
        manager.run_watchdog_once()
        assert jobs and jobs[0]["kind"] == "job" and jobs[0]["automation_id"] == out["id"]
        assert jobs[0]["payload"] == {"exit": 0}
        assert host.fired == []  # not an automation trigger
    finally:
        manager.stop()


def test_a_crashing_watcher_restarts_with_backoff_and_a_clean_exit_is_done(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    (tmp_path / "ws" / "crash.py").write_text(WATCHER_CRASH)
    (tmp_path / "ws" / "clean.py").write_text(WATCHER_CLEAN_EXIT)
    try:
        crash = manager.start_watcher("s1", "crash.py", None, True)
        clean = manager.start_watcher("s1", "clean.py", None, True)
        assert _wait(lambda: all(w.proc.poll() is not None for w in manager._watchers.values() if w.proc))
        manager.run_watchdog_once()
        crashed = manager.store.get(crash["id"])
        assert crashed["state"] == "active" and "restart in 1 s" in crashed["last_error"]
        assert manager.store.get(clean["id"])["state"] == "done"
        assert [p["event"] for p in host.sent if p["id"] == clean["id"]] == [EVENT_CREATED, EVENT_DONE]
        # Backoff: nothing restarts before its time; then it does.
        manager.run_watchdog_once()
        assert manager.running_watchers() == []
        clock.now += 1
        manager.run_watchdog_once()
        assert _wait(lambda: (manager._watchers[crash["id"]].proc is not None))
    finally:
        manager.stop()


def test_a_watcher_without_restart_fails_on_crash(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    (tmp_path / "ws" / "crash.py").write_text(WATCHER_CRASH)
    try:
        out = manager.start_watcher("s1", "crash.py", None, False)
        assert _wait(lambda: all(w.proc.poll() is not None for w in manager._watchers.values() if w.proc))
        manager.run_watchdog_once()
        row = manager.store.get(out["id"])
        assert row["state"] == "failed" and row["last_error"] == "exit code 3"
        assert [p["event"] for p in host.sent if p["id"] == out["id"]][-1] == EVENT_FAILED
    finally:
        manager.stop()


@pytest.mark.parametrize("blocked_by", ["rate_limit", "unprovisioned", "estop"])
def test_clean_exit_waits_for_final_trigger_delivery(tmp_path, blocked_by):
    host, clock = _Host(provisioned=blocked_by != "unprovisioned"), _Clock()
    manager = _manager(tmp_path, host, clock, rate_window=30.0)
    (tmp_path / "ws" / "final.py").write_text(
        "from agents_hooks import trigger\n"
        "trigger('final results', payload={'final': True, 'percentage': 42})\n"
    )
    try:
        out = manager.start_watcher("s1", "final.py", "election", True)
        proc = manager._watchers[out["id"]].proc
        assert _wait(lambda: proc.poll() is not None)
        if blocked_by == "rate_limit":
            manager.store.record_fire(out["id"], fired_at=clock.now, next_fire_at=None)
        elif blocked_by == "estop":
            (tmp_path / "ESTOP").write_text("")

        for _ in range(2):
            assert manager.run_watchdog_once() == 0
            assert manager.store.get(out["id"])["state"] == "active"
            assert manager.running_watchers() == []
            assert host.fired == []
            assert not any(p["event"] == EVENT_DONE for p in host.sent)

        clock.now += 30
        host.provisioned = True
        (tmp_path / "ESTOP").unlink(missing_ok=True)
        assert manager.run_watchdog_once() == 1
        assert json.loads(host.fired[0][1].split("\n")[-1]) == {"final": True, "percentage": 42}
        assert manager.store.get(out["id"])["state"] == "done"
        assert [p["event"] for p in host.sent] == [EVENT_CREATED, EVENT_FIRED, EVENT_DONE]
        assert manager.run_watchdog_once() == 0
        assert len(host.fired) == 1
    finally:
        manager.stop()


def test_final_trigger_arriving_after_initial_tail_read_is_not_lost(tmp_path, monkeypatch):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    (tmp_path / "ws" / "final.py").write_text(
        "from agents_hooks import trigger\ntrigger('final results', payload={'final': True})\n"
    )
    try:
        out = manager.start_watcher("s1", "final.py", "election", True)
        proc = manager._watchers[out["id"]].proc
        assert _wait(lambda: proc.poll() is not None)
        read = manager._read_new_triggers
        reads = 0

        def initial_read_before_final_write():
            nonlocal reads
            reads += 1
            return [] if reads == 1 else read()

        monkeypatch.setattr(manager, "_read_new_triggers", initial_read_before_final_write)
        assert manager.run_watchdog_once() == 0
        assert manager.store.get(out["id"])["state"] == "active"
        assert manager.run_watchdog_once() == 1
        assert manager.store.get(out["id"])["state"] == "done"
        assert host.fired[0][2]["reason"] == "final results"
        assert manager.run_watchdog_once() == 0
    finally:
        manager.stop()


def test_start_watcher_refuses_a_missing_or_escaping_script(tmp_path):
    manager = _manager(tmp_path, _Host(), _Clock())
    assert manager.start_watcher("s1", "missing.py", None, True)["ok"] is False
    (tmp_path / "outside.py").write_text("")
    assert manager.start_watcher("s1", "../outside.py", None, True)["ok"] is False
    assert manager.list() == []


def test_watchers_get_the_secrets_env_and_the_hook_env(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock, env_provider=lambda: {"MY_KEY": "sekret", "bad name": "x"})
    (tmp_path / "ws" / "env.py").write_text(
        "import os, json\n"
        "print(json.dumps({k: os.environ.get(k) for k in ('MY_KEY', 'AGENTS_AUTOMATION_ID', 'AGENTS_TRIGGERS_PATH', 'bad name')}))\n"
    )
    try:
        out = manager.start_watcher("s1", "env.py", None, False)
        log = tmp_path / "ws" / out["log_path"]
        assert _wait(lambda: log.exists() and "MY_KEY" in log.read_text())
        line = [l for l in log.read_text().splitlines() if l.startswith("{")][0]
        seen = json.loads(line)
        assert seen["MY_KEY"] == "sekret" and seen["AGENTS_AUTOMATION_ID"] == out["id"]
        assert seen["AGENTS_TRIGGERS_PATH"] == ".agents/automations/triggers.jsonl"
        assert seen["bad name"] is None
    finally:
        manager.stop()


def test_estop_stops_running_watchers_and_restarts_them_when_lifted(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    (tmp_path / "ws" / "watch.py").write_text("import time\ntime.sleep(60)\n")
    try:
        out = manager.start_watcher("s1", "watch.py", None, True)
        assert manager.running_watchers() == [out["id"]]
        (tmp_path / "ESTOP").write_text("")
        manager.run_watchdog_once()
        assert manager.running_watchers() == []
        manager.run_watchdog_once()
        assert manager.running_watchers() == []
        (tmp_path / "ESTOP").unlink()
        manager.run_watchdog_once()
        assert manager.running_watchers() == [out["id"]]
        assert manager.store.get(out["id"])["state"] == "active"
    finally:
        manager.stop()


# -- persistence across a host restart -----------------------------------------------


def test_active_watchers_and_unread_triggers_survive_restart(tmp_path):
    host, clock = _Host(), _Clock()
    (tmp_path / "ws").mkdir()
    (tmp_path / "ws" / "watch.py").write_text("import time\ntime.sleep(60)\n")
    first = _manager(tmp_path, host, clock)
    first.start()
    try:
        out = first.start_watcher("s1", "watch.py", "w", True)
        paused = first.start_watcher("s1", "watch.py", "p", True)
        first.control(None, paused["id"], "pause")
        sched = first.schedule("s1", "every 5m", "x", None)
        assert first.running_watchers() == [out["id"]]
        # A trigger line the previous host never consumed.
        first.triggers_path().parent.mkdir(parents=True, exist_ok=True)
        with first.triggers_path().open("a") as fh:
            fh.write(json.dumps({"automation_id": out["id"], "reason": "stale"}) + "\n")
    finally:
        first.stop()
    assert first.running_watchers() == []
    assert Path(tmp_path / "ws" / ".agents" / "automations" / (out["id"] + ".log")).exists()

    second = _manager(tmp_path, host, clock)
    second.start()
    try:
        assert second.running_watchers() == [out["id"]]  # the paused one stays paused
        assert {r["id"]: r["state"] for r in second.list("s1")} == {
            out["id"]: "active",
            paused["id"]: "paused",
            sched["id"]: "active",
        }
        assert second.run_watchdog_once() == 1 and len(host.fired) == 1
        assert second.run_watchdog_once() == 0  # accepted callback is not replayed
        clock.now += 300
        assert second.run_scheduler_once() == 1  # the schedule survived
    finally:
        second.stop()


def test_the_threads_run_the_scheduler_and_watchdog_on_their_own(tmp_path):
    host, clock = _Host(), _Clock()
    workspace = tmp_path / "ws"
    workspace.mkdir()
    manager = AutomationManager(
        db_path=str(tmp_path / "state.db"),
        workspace=str(workspace),
        fire=host.fire,
        send=host.send,
        clock=clock,
        tick=0.05,
        poll=0.05,
    )
    manager.start()
    try:
        manager.schedule("s1", "every 5m", "x", None)
        clock.now += 300
        assert _wait(lambda: len(host.fired) == 1)
    finally:
        manager.stop()
    assert not any(t.is_alive() for t in manager._threads)


@pytest.mark.skipif(os.name != "posix", reason="process groups")
def test_stop_kills_the_watcher_process_group(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    (tmp_path / "ws" / "spawn.py").write_text(
        "import subprocess, time\n"
        "p = subprocess.Popen(['sleep', '60'])\n"
        "print('child', p.pid, flush=True)\n"
        "time.sleep(60)\n"
    )
    out = manager.start_watcher("s1", "spawn.py", None, True)
    log = tmp_path / "ws" / out["log_path"]
    assert _wait(lambda: log.exists() and "child" in log.read_text())
    child_pid = int([l for l in log.read_text().splitlines() if l.startswith("child")][0].split()[1])
    manager.stop()
    assert _wait(lambda: not Path(f"/proc/{child_pid}").exists() or "zombie" in Path(f"/proc/{child_pid}/status").read_text().lower())


def test_pending_callback_survives_offline_host_restart(tmp_path):
    host, clock = _Host(provisioned=False), _Clock()
    first = _manager(tmp_path, host, clock)
    first.start()
    row = first.store.create(session_key='s1', kind='watcher', name='final',
                             spec={'script_path': 'watch.py'}, prompt='', next_fire_at=None)
    (tmp_path / 'ws' / 'watch.py').write_text('import time\ntime.sleep(60)\n')
    with first.triggers_path().open('a') as stream:
        stream.write(json.dumps({'automation_id': row['id'], 'reason': 'final',
                                 'payload': {'event_id': 'final-1', 'final': True}}) + '\n')
    assert first.run_watchdog_once() == 0
    first.stop()
    host.provisioned = True
    second = _manager(tmp_path, host, clock)
    second.start()
    try:
        assert second.run_watchdog_once() == 1
        assert 'final-1' in host.fired[0][1]
    finally:
        second.stop()
    third = _manager(tmp_path, host, clock)
    third.start()
    try:
        assert third.run_watchdog_once() == 0
        assert len(host.fired) == 1
    finally:
        third.stop()


def test_pep723_watcher_uses_uv_and_receives_repeatable_hook(tmp_path):
    import shutil
    if not shutil.which('uv'):
        pytest.skip('uv is not installed')
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock, rate_window=0)
    manager.start()
    script = tmp_path / 'ws' / 'monitor.py'
    script.write_text('# /// script\n# dependencies = []\n# ///\n'
                      'from agents_hooks import trigger\nimport time\n'
                      'assert trigger("first", payload={"n": 1})\ntime.sleep(0.5)\n'
                      'assert trigger("final", payload={"n": 2})\n')
    try:
        row = manager.start_watcher('s1', 'monitor.py', 'monitor', True)
        assert row['ok']
        assert _wait(lambda: (manager.run_watchdog_once(), len(host.fired) >= 2)[1])
        assert _wait(lambda: (manager.run_watchdog_once(), manager.store.get(row['id'])['state'] == 'done')[1])
        assert len(host.fired) == 2
    finally:
        manager.stop()


def test_an_exited_runner_never_leaves_the_monitor_running(tmp_path):
    """The tracked process is not always the monitor: a PEP 723 script runs
    under ``uv run --script``, so ``proc`` is uv and the script is its child.
    When the handle dies first, the script must die with it. An orphan keeps
    appending triggers under a row the host has closed, every report is then
    dropped, and from outside it looks exactly like "the automation does not
    fire any more"."""
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    (tmp_path / "ws" / "runner.py").write_text(
        "import subprocess, sys\n"
        "p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])\n"
        "print('monitor', p.pid, flush=True)\n"
        "sys.exit(0)\n"
    )
    out = manager.start_watcher("s1", "runner.py", None, True)
    log = tmp_path / "ws" / out["log_path"]
    assert _wait(lambda: log.exists() and "monitor" in log.read_text())
    pid = int([l for l in log.read_text().splitlines() if l.startswith("monitor")][0].split()[1])
    try:
        assert _wait(lambda: (manager.run_watchdog_once(), manager.store.get(out["id"])["state"] == "done")[1])
        assert _wait(lambda: not Path(f"/proc/{pid}").exists())
    finally:
        manager.stop()


def test_a_report_for_a_closed_row_is_recorded_not_swallowed(tmp_path):
    """A trigger line that the host will not act on says so on the row. A
    silently dropped report is unreadable from the app: the script works, the
    line is written, and nothing happens."""
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    row = manager.store.create(
        session_key="s1", kind="watcher", name="w",
        spec={"script_path": "w.py"}, prompt="", next_fire_at=None,
    )
    manager.store.update(row["id"], state="paused")
    path = manager.triggers_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"automation_id": row["id"], "reason": "seen"}) + "\n")
    assert manager.run_watchdog_once() == 0
    assert host.fired == []
    assert "paused" in (manager.store.get(row["id"])["last_error"] or "")


def test_a_pep723_script_falls_back_to_the_interpreter_without_uv(tmp_path, monkeypatch):
    """No uv on the host means the watcher runs on python, not a crash loop
    into ``failed``."""
    import chuk_agents_host.automations as automations_module

    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    monkeypatch.setattr(automations_module.shutil, "which", lambda _name: None)
    assert manager._runner(True, None) == [manager._python]
    monkeypatch.setattr(automations_module.shutil, "which", lambda _name: "/usr/bin/uv")
    manager._uv_available.clear()
    assert manager._runner(True, None) == ["uv", "run", "--script"]
    manager._uv_available.clear()
    assert manager._runner(False, None) == [manager._python]
