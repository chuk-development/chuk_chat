"""Scheduler / cron / autonomy (§13).

The model emits a schedule string; a tiny deterministic parser turns it into a
spec. Four forms are supported:

- ``every 30m`` / ``every 2h``     -> interval
- ``0 9 * * *`` (5-field cron)      -> cron, validated by ``croniter``
- ``2026-02-03T14:00`` (ISO)        -> one-shot, anchored to a configured tz
- ``30m`` / ``2h`` / ``1d``         -> one-shot from now

An in-process ticker (every 60s in production; driven directly with an injected
clock in tests) computes due jobs. Firing is **at-most-once**: a due job's
``next_run`` is advanced *before* its action runs, so a crash mid-execution
never re-fires the same slot.

Two cost modes ride on top of the normal agent job:

- ``no_agent``     — run a bare callable on schedule, zero model tokens.
- ``monitor`` (hash-diff) — hash a source each tick, wake the caller *only* when
  the bytes change (§13, §7.9). Unchanged ticks cost nothing downstream.
"""

from __future__ import annotations

import hashlib
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any
from zoneinfo import ZoneInfo

from croniter import croniter

# --------------------------------------------------------------------------
# parse_schedule
# --------------------------------------------------------------------------

_DURATION_RE = re.compile(r"^(\d+)([smhd])$")
_EVERY_RE = re.compile(r"^every\s+(\d+[smhd])$", re.IGNORECASE)
_UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400}

# ISO datetime without timezone info, e.g. 2026-02-03T14:00 or with seconds.
_ISO_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$",
)


def _duration_to_seconds(token: str) -> int:
    m = _DURATION_RE.match(token)
    if not m:
        raise ValueError(f"not a duration: {token!r}")
    value, unit = m.groups()
    return int(value) * _UNIT_SECONDS[unit]


def parse_schedule(
    s: str,
    *,
    tz: str | ZoneInfo = "UTC",
    now: datetime | None = None,
) -> dict[str, Any]:
    """Parse a schedule string into a deterministic spec dict.

    Returns one of:

    - ``{"kind": "interval", "seconds": int}``
    - ``{"kind": "cron", "expr": str}``
    - ``{"kind": "once_at", "at": datetime}`` (tz-aware, anchored to ``tz``)
    - ``{"kind": "once_after", "seconds": int}``

    ``tz`` anchors a naive ISO timestamp so it does not drift with the host's
    local zone. ``now`` is accepted only to keep the signature clock-injectable;
    ``once_after`` stays relative and is resolved when the job is scheduled.

    Raises :class:`ValueError` on anything unrecognised or invalid.
    """
    text = s.strip()
    if not text:
        raise ValueError("empty schedule string")

    zone = tz if isinstance(tz, ZoneInfo) else ZoneInfo(tz)

    # 1) interval: "every 30m"
    every = _EVERY_RE.match(text)
    if every:
        return {"kind": "interval", "seconds": _duration_to_seconds(every.group(1))}

    # 2) one-shot ISO datetime, anchored to the configured tz
    if _ISO_RE.match(text):
        naive = datetime.fromisoformat(text)
        at = naive.replace(tzinfo=zone)
        return {"kind": "once_at", "at": at}

    # 3) one-shot from now: "30m" / "2h" / "1d"
    if _DURATION_RE.match(text):
        return {"kind": "once_after", "seconds": _duration_to_seconds(text)}

    # 4) 5-field cron, validated by croniter
    fields = text.split()
    if len(fields) == 5:
        if not croniter.is_valid(text):
            raise ValueError(f"invalid cron expression: {text!r}")
        return {"kind": "cron", "expr": text}

    raise ValueError(f"unrecognised schedule: {s!r}")


def _next_from_spec(
    spec: dict[str, Any], after: datetime
) -> datetime | None:
    """Compute the next fire time strictly after ``after`` for a recurring spec.

    Returns ``None`` for one-shot specs (they do not recur).
    """
    kind = spec["kind"]
    if kind == "interval":
        return after + timedelta(seconds=spec["seconds"])
    if kind == "cron":
        itr = croniter(spec["expr"], after)
        return itr.get_next(datetime)
    return None


def _initial_run(
    spec: dict[str, Any], now: datetime
) -> datetime | None:
    """Compute the first fire time for a freshly scheduled spec."""
    kind = spec["kind"]
    if kind == "interval":
        return now + timedelta(seconds=spec["seconds"])
    if kind == "cron":
        return croniter(spec["expr"], now).get_next(datetime)
    if kind == "once_at":
        return spec["at"]
    if kind == "once_after":
        return now + timedelta(seconds=spec["seconds"])
    raise ValueError(f"unknown spec kind: {kind!r}")


# --------------------------------------------------------------------------
# Jobs & Scheduler
# --------------------------------------------------------------------------


class JobMode(str, Enum):
    """Cost/behaviour mode of a scheduled job (§13)."""

    AGENT = "agent"          # wake a full agent (costs model tokens)
    NO_AGENT = "no_agent"    # run a bare callable, zero tokens
    MONITOR = "monitor"      # hash a source, signal only on change


@dataclass
class Job:
    """One scheduled job.

    ``spec`` is a :func:`parse_schedule` result. ``next_run`` is the next fire
    time (tz-aware); ``None`` means the job is exhausted (a fired one-shot) and
    will never fire again. ``action`` receives this job and the current time and
    returns an opaque result the caller interprets.

    For :attr:`JobMode.MONITOR`, ``source`` is hashed each fire; ``last_hash``
    holds the previous digest so only changes signal.
    """

    id: str
    spec: dict[str, Any]
    mode: JobMode = JobMode.AGENT
    next_run: datetime | None = None
    action: Callable[["Job", datetime], Any] | None = None
    source: Callable[[], bytes] | None = None
    last_hash: str | None = None
    agent_id: str | None = None

    def advance(self, after: datetime) -> None:
        """Move ``next_run`` to the next occurrence after ``after``.

        One-shots become exhausted (``next_run = None``). Called *before* the
        action runs so firing is at-most-once.
        """
        self.next_run = _next_from_spec(self.spec, after)


@dataclass
class MonitorSignal:
    """Result of a monitor-mode fire: whether the watched source changed."""

    job_id: str
    changed: bool
    old_hash: str | None
    new_hash: str
    at: datetime


def _hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@dataclass
class Scheduler:
    """In-process job scheduler with at-most-once firing.

    Production drives :meth:`tick` from a 60s loop; tests drive it directly with
    an injected ``now`` so behaviour is clock-independent. The scheduler holds no
    threads itself — the ticker is the caller's concern — which keeps the firing
    logic pure and testable.
    """

    tz: str = "UTC"
    _jobs: dict[str, Job] = field(default_factory=dict)

    @property
    def zone(self) -> ZoneInfo:
        return ZoneInfo(self.tz)

    def schedule(
        self,
        job_id: str,
        schedule_str: str,
        *,
        now: datetime,
        mode: JobMode = JobMode.AGENT,
        action: Callable[[Job, datetime], Any] | None = None,
        source: Callable[[], bytes] | None = None,
        agent_id: str | None = None,
    ) -> Job:
        """Parse ``schedule_str`` and register a job with its first ``next_run``."""
        spec = parse_schedule(schedule_str, tz=self.tz, now=now)
        job = Job(
            id=job_id,
            spec=spec,
            mode=mode,
            next_run=_initial_run(spec, now),
            action=action,
            source=source,
            agent_id=agent_id,
        )
        self._jobs[job_id] = job
        return job

    def add(self, job: Job) -> Job:
        """Register a pre-built job (its ``next_run`` must already be set)."""
        self._jobs[job.id] = job
        return job

    def remove(self, job_id: str) -> bool:
        return self._jobs.pop(job_id, None) is not None

    def jobs(self) -> list[Job]:
        return list(self._jobs.values())

    def due_jobs(self, now: datetime) -> list[Job]:
        """Return jobs whose ``next_run`` is at or before ``now``.

        This is read-only: it does **not** advance or fire. Used for inspection
        and by :meth:`tick`.
        """
        return [
            job
            for job in self._jobs.values()
            if job.next_run is not None and job.next_run <= now
        ]

    def tick(self, now: datetime) -> list[Any]:
        """Fire every due job at-most-once and return the action results.

        Order of operations per job:

        1. capture the fired slot,
        2. **advance ``next_run`` before executing** (so a crash cannot re-fire),
        3. run the action / monitor.

        Advancement for the whole due set happens before any action runs, so a
        long-running action never causes a sibling slot to be missed or doubled.
        """
        due = self.due_jobs(now)

        # Phase 1: advance every due job first. At-most-once even if an action
        # below raises — the slot is already gone.
        for job in due:
            job.advance(now)

        # Phase 2: execute.
        results: list[Any] = []
        for job in due:
            results.append(self._fire(job, now))
        return results

    def _fire(self, job: Job, now: datetime) -> Any:
        if job.mode is JobMode.MONITOR:
            return self._fire_monitor(job, now)
        # AGENT and NO_AGENT both just run the action; the distinction is the
        # caller's (NO_AGENT actions do no model I/O). A missing action is a
        # no-op, which keeps the scheduler usable as a pure clock in tests.
        if job.action is None:
            return None
        return job.action(job, now)

    def _fire_monitor(self, job: Job, now: datetime) -> MonitorSignal:
        if job.source is None:
            raise ValueError(f"monitor job {job.id!r} has no source")
        digest = _hash_bytes(job.source())
        old = job.last_hash
        changed = old != digest
        job.last_hash = digest
        signal = MonitorSignal(
            job_id=job.id,
            changed=changed,
            old_hash=old,
            new_hash=digest,
            at=now,
        )
        # Only wake the downstream agent on a real change (the cost lever).
        if changed and job.action is not None:
            job.action(job, now)
        return signal


def utc(year: int, month: int, day: int, hour: int = 0, minute: int = 0) -> datetime:
    """Small helper for building tz-aware UTC instants in callers and tests."""
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc)
