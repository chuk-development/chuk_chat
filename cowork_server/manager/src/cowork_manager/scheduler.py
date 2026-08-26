"""Scheduler / cron / autonomy (§13).

The model emits a schedule string; a tiny deterministic parser turns it into a
spec. Four forms are supported:

- ``every 30m`` / ``every 2h``     -> interval
- ``0 9 * * *`` (5-field cron)      -> cron, validated by ``croniter``
- ``2026-02-03T14:00`` (ISO)        -> one-shot, anchored to a configured tz
- ``30m`` / ``2h`` / ``1d``         -> one-shot from now

An in-process ticker (every 60s in production; driven directly with an injected
clock in tests) computes due jobs. Firing is **at-most-once** on two axes:

- a due job's ``next_run`` is advanced *before* its action runs, under the
  scheduler lock, so a crash mid-execution never re-fires the same slot and two
  threads ticking the same instant dispatch it once;
- a dispatched job is **claimed**; while the claim is kept alive by heartbeats
  the job is not dispatched again, so a run that outlives its own interval does
  not stack. A claim whose heartbeat went stale (a crashed run) is released on
  the next tick and the job becomes dispatchable again.

Two cost modes ride on top of the normal agent job:

- ``no_agent``     — run a bare callable on schedule, zero model tokens.
- ``monitor`` (hash-diff) — hash a source each tick, wake the caller *only* when
  the bytes change (§13, §7.9), handing it a bounded unified diff. Unchanged
  ticks cost nothing downstream.
"""

from __future__ import annotations

import difflib
import hashlib
import re
import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any
from zoneinfo import ZoneInfo

from croniter import croniter

# A monitor diff is prompt text, so it is charged per token: keep it bounded.
DEFAULT_MAX_DIFF_LINES = 200

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
        seconds = _duration_to_seconds(every.group(1))
        if seconds <= 0:
            # A zero interval would make every tick due forever — reject it here
            # rather than let a model typo spin the ticker.
            raise ValueError(f"interval must be positive: {s!r}")
        return {"kind": "interval", "seconds": seconds}

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
    holds the previous digest so only changes signal, and ``last_bytes`` holds
    the previous content so a change can be handed over as a unified diff.

    ``autorelease`` controls the claim (§13 at-most-once). A synchronous action
    finishes inside :meth:`Scheduler.tick`, so its claim is dropped when the
    action returns. A *dispatched* long run (the unattended agent job) sets
    ``autorelease=False``: it then owns the claim and must call
    :meth:`Scheduler.heartbeat` while it works and :meth:`Scheduler.release`
    when it is done.
    """

    id: str
    spec: dict[str, Any]
    mode: JobMode = JobMode.AGENT
    next_run: datetime | None = None
    action: Callable[[Job, datetime], Any] | None = None
    source: Callable[[], bytes] | None = None
    last_hash: str | None = None
    last_bytes: bytes | None = None
    last_signal: MonitorSignal | None = None
    agent_id: str | None = None
    autorelease: bool = True
    lease_seconds: float = 300.0
    max_diff_lines: int = DEFAULT_MAX_DIFF_LINES
    claimed_at: datetime | None = None
    heartbeat_at: datetime | None = None

    def routine_label(self, agent_name: str) -> str:
        """The Bot Mode display name for a routine: ``[bot:<name>] <job id>``
        (§16.1). Namespaced so an agent's routines read as its own; the caller
        passes the agent's display name because the job holds only the id."""
        return f"[bot:{agent_name}] {self.id}"

    def advance(self, after: datetime) -> None:
        """Move ``next_run`` to the next occurrence after ``after``.

        One-shots become exhausted (``next_run = None``). Called *before* the
        action runs so firing is at-most-once.
        """
        self.next_run = _next_from_spec(self.spec, after)

    def claim_is_live(self, now: datetime) -> bool:
        """True while a dispatched run still holds this job.

        A claim stays live as long as its heartbeat is younger than
        ``lease_seconds``. A crashed run stops beating, the lease expires, and
        the job is dispatchable again.
        """
        if self.claimed_at is None:
            return False
        last = self.heartbeat_at or self.claimed_at
        return (now - last).total_seconds() <= self.lease_seconds


@dataclass
class MonitorSignal:
    """Result of a monitor-mode fire: whether the watched source changed.

    ``diff`` is a bounded unified diff of the previous content against the new
    one, present only when ``changed``. It is what gets injected into the woken
    agent's prompt instead of the whole source.
    """

    job_id: str
    changed: bool
    old_hash: str | None
    new_hash: str
    at: datetime
    diff: str | None = None


def _hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _decode(data: bytes) -> list[str]:
    return data.decode("utf-8", errors="replace").splitlines(keepends=True)


def unified_diff(
    old: bytes,
    new: bytes,
    *,
    label: str = "source",
    max_lines: int = DEFAULT_MAX_DIFF_LINES,
) -> str:
    """Return a bounded unified diff between two byte blobs.

    The output is prompt text, so it is truncated to ``max_lines`` with an
    explicit marker rather than allowed to grow without limit (§7.9).
    """
    lines = list(
        difflib.unified_diff(
            _decode(old),
            _decode(new),
            fromfile=f"{label}@previous",
            tofile=f"{label}@current",
        )
    )
    if max_lines >= 0 and len(lines) > max_lines:
        dropped = len(lines) - max_lines
        lines = lines[:max_lines]
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"... diff truncated, {dropped} more lines\n")
    return "".join(lines)


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
    _lock: threading.RLock = field(default_factory=threading.RLock, repr=False)

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
        autorelease: bool = True,
        lease_seconds: float = 300.0,
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
            autorelease=autorelease,
            lease_seconds=lease_seconds,
        )
        with self._lock:
            self._jobs[job_id] = job
        return job

    def add(self, job: Job) -> Job:
        """Register a pre-built job (its ``next_run`` must already be set)."""
        with self._lock:
            self._jobs[job.id] = job
        return job

    def remove(self, job_id: str) -> bool:
        with self._lock:
            return self._jobs.pop(job_id, None) is not None

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def jobs(self) -> list[Job]:
        with self._lock:
            return list(self._jobs.values())

    def jobs_for(self, agent_id: str) -> list[Job]:
        """An agent's routines (§16.1 Bot Mode: routines belong to a bot). The
        list a per-agent view shows — every job whose ``agent_id`` is this one."""
        with self._lock:
            return [j for j in self._jobs.values() if j.agent_id == agent_id]

    def remove_agent_jobs(self, agent_id: str) -> int:
        """Drop all of an agent's routines, returning how many. A deleted agent
        must not leave its routines firing at nothing — the scheduler's twin of
        the room-delete cascade."""
        with self._lock:
            ids = [jid for jid, j in self._jobs.items() if j.agent_id == agent_id]
            for jid in ids:
                del self._jobs[jid]
            return len(ids)

    def due_jobs(self, now: datetime) -> list[Job]:
        """Return jobs that are due *and* free to run at ``now``.

        A job is due when ``next_run`` is at or before ``now``. A job whose
        claim is still live (a dispatched run that keeps heart-beating) is not
        returned — that is what stops a long run from being dispatched twice.

        This is read-only: it does **not** advance, claim or fire.
        """
        with self._lock:
            return [
                job
                for job in self._jobs.values()
                if job.next_run is not None
                and job.next_run <= now
                and not job.claim_is_live(now)
            ]

    def heartbeat(self, job_id: str, now: datetime) -> bool:
        """Keep a dispatched job's claim alive. Returns False if it is unknown."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return False
            job.heartbeat_at = now
            return True

    def release(self, job_id: str) -> bool:
        """Drop a job's claim so its next slot can be dispatched again."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return False
            job.claimed_at = None
            job.heartbeat_at = None
            return True

    def _claim_due(self, now: datetime) -> list[Job]:
        """Atomically pick the due jobs, advance them and claim them.

        Everything that decides *whether this tick owns the slot* happens under
        one lock: expired claims are dropped, live claims are skipped, the slot
        is advanced, and the job is marked claimed. Two threads ticking the same
        instant therefore hand the job to exactly one of them.
        """
        claimed: list[Job] = []
        with self._lock:
            for job in self._jobs.values():
                if job.next_run is None or job.next_run > now:
                    continue
                if job.claimed_at is not None and not job.claim_is_live(now):
                    # A crashed run: its heartbeat went stale, take the job back.
                    job.claimed_at = None
                    job.heartbeat_at = None
                if job.claim_is_live(now):
                    continue
                job.advance(now)
                job.claimed_at = now
                job.heartbeat_at = now
                claimed.append(job)
        return claimed

    def tick(self, now: datetime) -> list[Any]:
        """Fire every due job at-most-once and return the action results.

        Order of operations per job:

        1. under the lock: skip anything already claimed, **advance ``next_run``
           before executing** (so a crash cannot re-fire), claim the job,
        2. outside the lock: run the action / monitor,
        3. release the claim unless the job dispatched a long run
           (``autorelease=False``), which then owns the claim itself.

        Advancement for the whole due set happens before any action runs, so a
        long-running action never causes a sibling slot to be missed or doubled.
        """
        due = self._claim_due(now)

        results: list[Any] = []
        for job in due:
            try:
                results.append(self._fire(job, now))
            except BaseException:
                # The slot is already gone (at-most-once); free the claim so the
                # *next* slot is not blocked by a run that never started.
                self.release(job.id)
                raise
            if job.autorelease:
                self.release(job.id)
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
        data = job.source()
        digest = _hash_bytes(data)
        old = job.last_hash
        changed = old != digest
        diff = (
            unified_diff(
                job.last_bytes or b"",
                data,
                label=job.id,
                max_lines=job.max_diff_lines,
            )
            if changed
            else None
        )
        job.last_hash = digest
        job.last_bytes = data
        signal = MonitorSignal(
            job_id=job.id,
            changed=changed,
            old_hash=old,
            new_hash=digest,
            at=now,
            diff=diff,
        )
        # The action reads the diff off the job, so publish the signal first.
        job.last_signal = signal
        # Only wake the downstream agent on a real change (the cost lever).
        if changed and job.action is not None:
            job.action(job, now)
        return signal


#: Production tick interval (§13).
DEFAULT_TICK_SECONDS = 60.0


class Ticker:
    """The 60s loop that drives a :class:`Scheduler`.

    The scheduler itself holds no thread — that is what keeps its firing logic
    pure and clock-independent in tests. This is the thin production wrapper:
    call :meth:`tick_once` every ``interval`` seconds until stopped. An action
    that raises is reported to ``on_error`` and does not kill the loop; its slot
    is already advanced, so the failure costs one run, not the schedule.
    """

    def __init__(
        self,
        scheduler: Scheduler,
        *,
        interval: float = DEFAULT_TICK_SECONDS,
        now: Callable[[], datetime] | None = None,
        on_error: Callable[[Job | None, BaseException], None] | None = None,
        wait: Callable[[float], Any] | None = None,
    ) -> None:
        self._scheduler = scheduler
        self._interval = interval
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._on_error = on_error
        self._stop = threading.Event()
        self._wait = wait or self._stop.wait
        self._thread: threading.Thread | None = None

    @property
    def stopped(self) -> bool:
        return self._stop.is_set()

    def tick_once(self) -> list[Any]:
        try:
            return self._scheduler.tick(self._now())
        except BaseException as exc:
            if self._on_error is None:
                raise
            self._on_error(None, exc)
            return []

    def run_forever(self) -> None:
        while not self._stop.is_set():
            self.tick_once()
            self._wait(self._interval)

    def start(self) -> threading.Thread:
        thread = threading.Thread(
            target=self.run_forever, name="cowork-ticker", daemon=True
        )
        self._thread = thread
        thread.start()
        return thread

    def stop(self, timeout: float | None = 5.0) -> None:
        self._stop.set()
        thread = self._thread
        # Never join yourself: an action may stop the ticker it runs on.
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout)
            self._thread = None


def utc(year: int, month: int, day: int, hour: int = 0, minute: int = 0) -> datetime:
    """Small helper for building tz-aware UTC instants in callers and tests."""
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc)
