"""parse_schedule (all forms) + due-job computation + advance-before-exec +
hash-diff monitor. All time is pinned — no real-clock dependence."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from cowork_manager.scheduler import (
    Job,
    JobMode,
    MonitorSignal,
    Scheduler,
    parse_schedule,
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
