"""parse_schedule (all forms) + due-job computation + advance-before-exec +
claim/heartbeat + hash-diff monitor + the ticker.

All time is pinned — every test injects the instant it wants, so nothing here
sleeps or depends on the host clock."""

from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from cowork_manager.scheduler import (
    Job,
    JobMode,
    MonitorSignal,
    Scheduler,
    Ticker,
    parse_schedule,
    unified_diff,
    utc,
)

NOW = utc(2026, 2, 3, 12, 0)


# -- parse_schedule ---------------------------------------------------------


def test_parse_interval() -> None:
    assert parse_schedule("every 30m") == {"kind": "interval", "seconds": 1800}
    assert parse_schedule("every 2h") == {"kind": "interval", "seconds": 7200}


def test_parse_cron_valid() -> None:
    assert parse_schedule("0 9 * * *") == {"kind": "cron", "expr": "0 9 * * *"}


def test_parse_cron_invalid_raises() -> None:
    with pytest.raises(ValueError):
        parse_schedule("99 99 * * *")


def test_parse_once_after() -> None:
    assert parse_schedule("30m") == {"kind": "once_after", "seconds": 1800}
    assert parse_schedule("2h") == {"kind": "once_after", "seconds": 7200}
    assert parse_schedule("1d") == {"kind": "once_after", "seconds": 86400}


def test_parse_once_at_is_timezone_anchored() -> None:
    berlin = parse_schedule("2026-02-03T14:00", tz="Europe/Berlin")
    assert berlin["kind"] == "once_at"
    at = berlin["at"]
    assert at.tzinfo == ZoneInfo("Europe/Berlin")
    # 14:00 Berlin (UTC+1 in February) is 13:00 UTC — the anchor, not host-local.
    assert at.astimezone(timezone.utc) == utc(2026, 2, 3, 13, 0)


def test_parse_once_at_default_utc() -> None:
    spec = parse_schedule("2026-02-03T14:00")
    assert spec["at"] == datetime(2026, 2, 3, 14, 0, tzinfo=ZoneInfo("UTC"))


def test_parse_once_at_does_not_drift_across_dst() -> None:
    # Europe/Berlin switches to CEST on 2026-03-29. The *wall clock* the model
    # asked for must survive that: 14:00 local before and after, i.e. a
    # different UTC instant — not a fixed offset applied blindly.
    before = parse_schedule("2026-03-28T14:00", tz="Europe/Berlin")["at"]
    after = parse_schedule("2026-03-30T14:00", tz="Europe/Berlin")["at"]

    assert before.hour == after.hour == 14
    assert before.utcoffset() == timedelta(hours=1)   # CET
    assert after.utcoffset() == timedelta(hours=2)    # CEST
    assert before.astimezone(timezone.utc) == utc(2026, 3, 28, 13, 0)
    assert after.astimezone(timezone.utc) == utc(2026, 3, 30, 12, 0)


def test_cron_keeps_local_wall_clock_across_dst() -> None:
    # A "0 9 * * *" job in Berlin must fire at 09:00 local every day, including
    # the day the clocks change — the classic scheduler drift bug.
    sch = Scheduler(tz="Europe/Berlin")
    berlin = ZoneInfo("Europe/Berlin")
    job = sch.schedule(
        "daily", "0 9 * * *", now=datetime(2026, 3, 28, 8, 0, tzinfo=berlin)
    )

    assert job.next_run == datetime(2026, 3, 28, 9, 0, tzinfo=berlin)
    job.advance(job.next_run)  # cross the DST boundary
    assert job.next_run == datetime(2026, 3, 29, 9, 0, tzinfo=berlin)
    assert job.next_run.utcoffset() == timedelta(hours=2)


def test_parse_invalid_raises() -> None:
    for bad in ["", "   ", "every", "banana", "0 9 * *", "10x"]:
        with pytest.raises(ValueError):
            parse_schedule(bad)


# -- initial run & due computation -----------------------------------------


def test_interval_first_run_and_due() -> None:
    sch = Scheduler()
    job = sch.schedule("j", "every 30m", now=NOW)
    assert job.next_run == NOW + timedelta(minutes=30)

    assert sch.due_jobs(NOW) == []  # not yet
    assert sch.due_jobs(NOW + timedelta(minutes=30)) == [job]


def test_once_at_due_at_anchor() -> None:
    sch = Scheduler(tz="Europe/Berlin")
    job = sch.schedule("j", "2026-02-03T14:00", now=NOW)
    # 14:00 Berlin == 13:00 UTC
    assert job.next_run.astimezone(timezone.utc) == utc(2026, 2, 3, 13, 0)
    assert sch.due_jobs(utc(2026, 2, 3, 12, 59)) == []
    assert sch.due_jobs(utc(2026, 2, 3, 13, 0)) == [job]


# -- advance-before-exec (at-most-once) ------------------------------------


def test_interval_advances_before_exec() -> None:
    sch = Scheduler()
    observed: list = []

    def action(job: Job, now: datetime):
        # When the action runs, next_run must already be advanced past this slot.
        observed.append(job.next_run)
        return "ran"

    sch.schedule("j", "every 30m", now=NOW, action=action)
    fire_at = NOW + timedelta(minutes=30)
    results = sch.tick(fire_at)

    assert results == ["ran"]
    # Advanced to the NEXT slot before the action saw it.
    assert observed == [fire_at + timedelta(minutes=30)]
    assert sch._jobs["j"].next_run == fire_at + timedelta(minutes=30)


def test_action_crash_does_not_refire_slot() -> None:
    sch = Scheduler()

    def boom(job: Job, now: datetime):
        raise RuntimeError("action failed")

    sch.schedule("j", "every 30m", now=NOW, action=boom)
    fire_at = NOW + timedelta(minutes=30)

    with pytest.raises(RuntimeError):
        sch.tick(fire_at)

    # Slot was advanced BEFORE the crash → the same slot is gone (at-most-once).
    assert sch._jobs["j"].next_run == fire_at + timedelta(minutes=30)
    assert sch.due_jobs(fire_at) == []


def test_once_job_exhausts_after_firing() -> None:
    sch = Scheduler()
    sch.schedule("j", "30m", now=NOW, action=lambda job, now: "done")
    fire_at = NOW + timedelta(minutes=30)

    assert sch.tick(fire_at) == ["done"]
    assert sch._jobs["j"].next_run is None
    assert sch.due_jobs(fire_at + timedelta(hours=99)) == []


def test_tick_fires_only_due_jobs() -> None:
    sch = Scheduler()
    sch.schedule("soon", "every 30m", now=NOW, action=lambda j, n: "soon")
    sch.schedule("later", "every 2h", now=NOW, action=lambda j, n: "later")

    results = sch.tick(NOW + timedelta(minutes=30))
    assert results == ["soon"]


# -- hash-diff monitor mode -------------------------------------------------


def test_monitor_signals_only_on_change() -> None:
    sch = Scheduler()
    state = {"data": b"alpha"}
    woken: list[datetime] = []

    sch.schedule(
        "mon",
        "every 30m",
        now=NOW,
        mode=JobMode.MONITOR,
        source=lambda: state["data"],
        action=lambda job, now: woken.append(now),
    )

    # Tick 1: first observation is a "change" (no prior hash) → signal + wake.
    t1 = NOW + timedelta(minutes=30)
    sig1 = sch.tick(t1)[0]
    assert isinstance(sig1, MonitorSignal)
    assert sig1.changed is True
    assert sig1.old_hash is None
    assert woken == [t1]

    # Tick 2: unchanged bytes → no signal, no wake (the cost lever).
    t2 = NOW + timedelta(minutes=60)
    sig2 = sch.tick(t2)[0]
    assert sig2.changed is False
    assert sig2.old_hash == sig1.new_hash
    assert woken == [t1]  # NOT woken again

    # Tick 3: bytes change → signal + wake, diff carried by the hashes.
    state["data"] = b"bravo"
    t3 = NOW + timedelta(minutes=90)
    sig3 = sch.tick(t3)[0]
    assert sig3.changed is True
    assert sig3.old_hash == sig2.new_hash
    assert sig3.new_hash != sig2.new_hash
    assert woken == [t1, t3]


def test_monitor_carries_a_unified_diff_of_the_change() -> None:
    sch = Scheduler()
    state = {"data": b"alpha\nbeta\n"}
    sch.schedule(
        "mon",
        "every 30m",
        now=NOW,
        mode=JobMode.MONITOR,
        source=lambda: state["data"],
    )

    sch.tick(NOW + timedelta(minutes=30))          # baseline
    state["data"] = b"alpha\ngamma\n"
    sig = sch.tick(NOW + timedelta(minutes=60))[0]

    assert sig.changed is True
    assert "-beta" in sig.diff
    assert "+gamma" in sig.diff
    # The unchanged line rides along as context, never as a change.
    assert " alpha" in sig.diff
    assert "+alpha" not in sig.diff


def test_unified_diff_is_bounded() -> None:
    old = b""
    new = ("line\n" * 500).encode()
    diff = unified_diff(old, new, label="src", max_lines=20)
    assert len(diff.splitlines()) <= 21          # 20 + the truncation marker
    assert "diff truncated" in diff


def test_monitor_without_source_raises() -> None:
    sch = Scheduler()
    job = Job(
        id="m",
        spec={"kind": "interval", "seconds": 60},
        mode=JobMode.MONITOR,
        next_run=NOW,
    )
    sch.add(job)
    with pytest.raises(ValueError):
        sch.tick(NOW)


# -- at-most-once: parallel ticks, claims & heartbeats ---------------------


def test_parallel_ticks_fire_a_due_job_exactly_once() -> None:
    """The at-most-once proof: N threads tick the same instant, one run happens."""
    sch = Scheduler()
    runs: list[datetime] = []
    guard = threading.Lock()

    def action(job: Job, now: datetime) -> str:
        with guard:
            runs.append(now)
        return "ran"

    sch.schedule("j", "every 30m", now=NOW, action=action)
    fire_at = NOW + timedelta(minutes=30)

    workers = 16
    ready = threading.Barrier(workers)
    results: list[list] = []

    def tick() -> None:
        ready.wait()          # line every thread up on the same instant
        results.append(sch.tick(fire_at))

    threads = [threading.Thread(target=tick) for _ in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert len(runs) == 1
    assert sum(len(r) for r in results) == 1
    assert sch.get("j").next_run == fire_at + timedelta(minutes=30)


def test_running_job_with_heartbeat_is_not_dispatched_again() -> None:
    sch = Scheduler()
    dispatched: list[datetime] = []

    # A long run: the action only *starts* it and keeps the claim (autorelease
    # off), the way UnattendedRunner does.
    sch.schedule(
        "long",
        "every 30m",
        now=NOW,
        action=lambda job, now: dispatched.append(now),
        autorelease=False,
        lease_seconds=300,
    )

    t1 = NOW + timedelta(minutes=30)
    sch.tick(t1)
    assert len(dispatched) == 1

    # The next slot comes due while the first run is still working. It beats
    # regularly, so the scheduler must leave it alone.
    t2 = NOW + timedelta(minutes=60)
    sch.heartbeat("long", t2 - timedelta(seconds=30))
    assert sch.due_jobs(t2) == []
    assert sch.tick(t2) == []
    assert len(dispatched) == 1

    # Run finishes and releases → the following slot dispatches normally.
    sch.release("long")
    t3 = NOW + timedelta(minutes=90)
    sch.tick(t3)
    assert len(dispatched) == 2


def test_crashed_run_without_heartbeat_is_released_and_redispatched() -> None:
    sch = Scheduler()
    dispatched: list[datetime] = []

    sch.schedule(
        "long",
        "every 30m",
        now=NOW,
        action=lambda job, now: dispatched.append(now),
        autorelease=False,
        lease_seconds=300,          # 5 min lease
    )

    t1 = NOW + timedelta(minutes=30)
    sch.tick(t1)
    assert len(dispatched) == 1

    # The run dies: no heartbeat ever again. The lease outlives the next slot,
    # so that one is still skipped...
    t2 = t1 + timedelta(minutes=4)
    assert sch.due_jobs(t2) == []

    # ...but once the lease expires the job is taken back and fires again.
    t3 = t1 + timedelta(minutes=30)
    assert sch.tick(t3) == [None]
    assert len(dispatched) == 2
    assert sch.get("long").claimed_at == t3


def test_sync_action_releases_its_claim_automatically() -> None:
    sch = Scheduler()
    sch.schedule("j", "every 30m", now=NOW, action=lambda job, now: "ok")

    sch.tick(NOW + timedelta(minutes=30))
    job = sch.get("j")
    assert job.claimed_at is None
    assert job.heartbeat_at is None


def test_failed_dispatch_releases_the_claim() -> None:
    sch = Scheduler()

    def boom(job: Job, now: datetime):
        raise RuntimeError("dispatch failed")

    sch.schedule("j", "every 30m", now=NOW, action=boom, autorelease=False)
    with pytest.raises(RuntimeError):
        sch.tick(NOW + timedelta(minutes=30))

    # The slot is gone (at-most-once) but the job is not wedged: the next slot
    # fires, because a run that never started must not hold the claim.
    assert sch.get("j").claimed_at is None
    assert len(sch.due_jobs(NOW + timedelta(minutes=60))) == 1


# -- ticker -----------------------------------------------------------------


def test_ticker_drives_the_scheduler_and_stops() -> None:
    sch = Scheduler()
    fired: list[datetime] = []
    clock = {"t": NOW}

    sch.schedule("j", "every 30m", now=NOW, action=lambda j, n: fired.append(n))

    ticker: Ticker

    def fake_wait(seconds: float) -> None:
        # Stand in for the 60s sleep: advance the fake clock instead, and stop
        # the loop once it has crossed the job's slot.
        assert seconds == 60.0
        clock["t"] += timedelta(minutes=15)
        if clock["t"] >= NOW + timedelta(minutes=45):
            ticker.stop(timeout=0)

    ticker = Ticker(sch, interval=60.0, now=lambda: clock["t"], wait=fake_wait)
    ticker.run_forever()

    # Four 15-minute steps cross exactly one 30-minute slot.
    assert fired == [NOW + timedelta(minutes=30)]
    assert ticker.stopped


def test_ticker_survives_a_failing_action() -> None:
    sch = Scheduler()
    seen: list[BaseException] = []

    def boom(job: Job, now: datetime):
        raise RuntimeError("nope")

    sch.schedule("j", "every 30m", now=NOW, action=boom)
    ticker = Ticker(
        sch,
        now=lambda: NOW + timedelta(minutes=30),
        on_error=lambda job, exc: seen.append(exc),
    )

    assert ticker.tick_once() == []
    assert len(seen) == 1 and isinstance(seen[0], RuntimeError)


# -- per-agent routines (§16.1) -------------------------------------------

_ROUTINE_NOW = datetime(2026, 1, 1, tzinfo=timezone.utc)


def test_jobs_for_returns_only_an_agents_routines():
    sch = Scheduler()
    sch.schedule("j1", "every 1h", now=_ROUTINE_NOW, agent_id="amber")
    sch.schedule("j2", "every 1h", now=_ROUTINE_NOW, agent_id="cobalt")
    sch.schedule("j3", "every 1h", now=_ROUTINE_NOW, agent_id="amber")
    sch.schedule("j4", "every 1h", now=_ROUTINE_NOW)  # no owner

    amber = {j.id for j in sch.jobs_for("amber")}
    assert amber == {"j1", "j3"}
    assert sch.jobs_for("nobody") == []


def test_remove_agent_jobs_drops_only_that_agents_and_counts_them():
    sch = Scheduler()
    sch.schedule("j1", "every 1h", now=_ROUTINE_NOW, agent_id="amber")
    sch.schedule("j2", "every 1h", now=_ROUTINE_NOW, agent_id="cobalt")
    sch.schedule("j3", "every 1h", now=_ROUTINE_NOW, agent_id="amber")

    assert sch.remove_agent_jobs("amber") == 2
    assert {j.id for j in sch.jobs()} == {"j2"}
    assert sch.remove_agent_jobs("amber") == 0  # already gone


def test_routine_label_is_namespaced_to_the_bot():
    sch = Scheduler()
    job = sch.schedule("weekly-news", "every 1d", now=_ROUTINE_NOW, agent_id="amber")
    assert job.routine_label("amber-otter") == "[bot:amber-otter] weekly-news"
