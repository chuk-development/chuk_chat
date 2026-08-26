"""Unattended runs, delivery and cost modes for scheduled jobs (§13).

A fired job runs with **no human present**. That changes three things compared
with an interactive turn:

- the agent is built fresh with ``skip_memory`` and ``skip_background_review``
  (nobody is there to answer a memory prompt or read a review);
- the run is bounded by an **inactivity** timeout, not a wall-clock one. A job
  may legitimately work for hours; what must be killed is a *hung* call that
  produces no event at all;
- the final answer is **delivered back to the origin chat by itself**, and the
  Manager pushes a notification — the app may well be closed while the sandbox
  keeps working. A ``[SILENT]`` marker suppresses the delivery so a monitor that
  found nothing worth saying costs no notification.

``attach_to_session`` makes a run continuable: the run is written under an
existing session key, so the user can simply reply into it.

The two cost levers of §13/§7.9 live here as job actions:

- :meth:`JobDispatcher.script_action` — ``no_agent`` mode. A bare callable on a
  schedule. No agent is built, so **zero tokens**.
- :meth:`JobDispatcher.monitor_action` — hash-diff mode. The scheduler hashes the
  source each tick and only calls this on a real change; the prompt then carries
  the unified diff instead of the whole source. N polling LLM calls become ~0.

Nothing here talks to a model directly. The runner takes an ``agent_factory``
that yields a :class:`RunHandle`, and a ``notifier`` callback for push. Both are
injected, so the whole autonomy path is exercised with fakes and no clock.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from queue import Empty, Queue
from typing import Any, Protocol

from cowork_manager.scheduler import Job, Scheduler

#: A final answer starting with this marker is not delivered anywhere.
SILENT_MARKER = "[SILENT]"

#: Default inactivity budget: 15 minutes without a single event is a hang.
DEFAULT_INACTIVITY_TIMEOUT = 900.0


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


# --------------------------------------------------------------------------
# Run protocol
# --------------------------------------------------------------------------


class RunEventKind(str, Enum):
    """What a running agent reports back to the runner."""

    ACTIVITY = "activity"    # any sign of life: a token, a tool call, a step
    APPROVAL = "approval"    # the run is blocked on a human decision
    FINAL = "final"          # the run produced its answer
    ERROR = "error"          # the run failed


@dataclass(frozen=True, slots=True)
class RunEvent:
    kind: RunEventKind
    text: str = ""


class RunHandle(Protocol):
    """A started, unattended agent run.

    ``next_event`` blocks up to ``timeout`` seconds and returns ``None`` when
    nothing happened in that window — that is the hang the inactivity watchdog
    kills. ``cancel`` tears the run down.
    """

    def next_event(self, timeout: float) -> RunEvent | None: ...

    def cancel(self, reason: str) -> None: ...


@dataclass(frozen=True, slots=True)
class RunSpec:
    """Everything the factory needs to build the agent for one fired job.

    ``session_key`` is ``attach_to_session``: set it and the run continues an
    existing chat (and is therefore replyable); leave it ``None`` for a fresh
    throwaway session.
    """

    job_id: str
    prompt: str
    agent_id: str | None = None
    session_key: str | None = None
    skip_memory: bool = True
    skip_background_review: bool = True

    @property
    def attach_to_session(self) -> bool:
        return self.session_key is not None


class RunStatus(str, Enum):
    COMPLETED = "completed"
    INACTIVITY_TIMEOUT = "inactivity_timeout"
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class RunOutcome:
    job_id: str
    status: RunStatus
    final_answer: str | None = None
    delivered: bool = False
    detail: str | None = None
    events: int = 0
    elapsed_seconds: float = 0.0


# --------------------------------------------------------------------------
# Notifications (push)
# --------------------------------------------------------------------------


class NotificationKind(str, Enum):
    COMPLETED = "completed"
    APPROVAL_NEEDED = "approval_needed"
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class Notification:
    """One push the Manager owes the app (§13 app-closed persistence).

    The transport is not wired yet. ``UnattendedRunner`` takes a ``notifier``
    callback and this is its payload, so the push service drops in without
    touching the run logic.
    """

    job_id: str
    kind: NotificationKind
    text: str
    agent_id: str | None = None
    session_key: str | None = None
    at: datetime | None = None


Notifier = Callable[[Notification], None]


def null_notifier(notification: Notification) -> None:
    """Default notifier: drop it. Keeps the runner usable without push wiring."""


# --------------------------------------------------------------------------
# Delivery
# --------------------------------------------------------------------------


def should_deliver(final_answer: str | None) -> bool:
    """False for an empty answer or one marked ``[SILENT]``.

    A recurring job that has nothing to report says so with the marker instead
    of pushing an empty message every hour.
    """
    if final_answer is None:
        return False
    text = final_answer.strip()
    if not text:
        return False
    return not text.startswith(SILENT_MARKER)


# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------


@dataclass
class UnattendedRunner:
    """Drives one fired job to completion and delivers its answer.

    ``agent_factory`` builds a *fresh* agent per run from the :class:`RunSpec`
    (which already carries ``skip_memory`` / ``skip_background_review``).
    ``heartbeat`` is the scheduler's, called on every event so a long run keeps
    its claim and is never dispatched a second time.
    """

    agent_factory: Callable[[RunSpec], RunHandle]
    notifier: Notifier = null_notifier
    now: Callable[[], datetime] = _utcnow
    inactivity_timeout: float = DEFAULT_INACTIVITY_TIMEOUT
    heartbeat: Callable[[str, datetime], Any] | None = None

    def run(self, spec: RunSpec) -> RunOutcome:
        started = self.now()
        handle = self.agent_factory(spec)
        events = 0

        def elapsed() -> float:
            return (self.now() - started).total_seconds()

        while True:
            event = handle.next_event(self.inactivity_timeout)
            if event is None:
                # No sign of life inside the window. The run may have been
                # working for hours before this — only the *gap* is fatal.
                handle.cancel("inactivity timeout")
                detail = (
                    f"no activity for {self.inactivity_timeout:g}s "
                    f"(ran {elapsed():g}s)"
                )
                self._notify(spec, NotificationKind.FAILED, detail)
                return RunOutcome(
                    job_id=spec.job_id,
                    status=RunStatus.INACTIVITY_TIMEOUT,
                    detail=detail,
                    events=events,
                    elapsed_seconds=elapsed(),
                )

            events += 1
            self._beat(spec.job_id)

            if event.kind is RunEventKind.ACTIVITY:
                continue
            if event.kind is RunEventKind.APPROVAL:
                # The app may be closed: push, then keep waiting for the answer.
                self._notify(spec, NotificationKind.APPROVAL_NEEDED, event.text)
                continue
            if event.kind is RunEventKind.ERROR:
                handle.cancel("run error")
                self._notify(spec, NotificationKind.FAILED, event.text)
                return RunOutcome(
                    job_id=spec.job_id,
                    status=RunStatus.FAILED,
                    detail=event.text,
                    events=events,
                    elapsed_seconds=elapsed(),
                )

            # FINAL
            answer = event.text
            deliver = should_deliver(answer)
            if deliver:
                self._notify(spec, NotificationKind.COMPLETED, answer)
            return RunOutcome(
                job_id=spec.job_id,
                status=RunStatus.COMPLETED,
                final_answer=answer,
                delivered=deliver,
                events=events,
                elapsed_seconds=elapsed(),
            )

    def _beat(self, job_id: str) -> None:
        if self.heartbeat is not None:
            self.heartbeat(job_id, self.now())

    def _notify(self, spec: RunSpec, kind: NotificationKind, text: str) -> None:
        self.notifier(
            Notification(
                job_id=spec.job_id,
                kind=kind,
                text=text,
                agent_id=spec.agent_id,
                session_key=spec.session_key,
                at=self.now(),
            )
        )


# --------------------------------------------------------------------------
# Threaded run handle (production side of the protocol)
# --------------------------------------------------------------------------


class ThreadedRunHandle:
    """Turn a blocking agent call into an event stream with a hang timeout.

    The agent runs on its own thread and pushes events into a queue; the runner
    polls that queue. A call that hangs simply stops producing events, which is
    exactly what ``next_event`` reports as ``None``. ``cancel`` sets a stop flag
    the agent body is expected to observe (the sandbox teardown is the hard
    backstop, §6).
    """

    def __init__(
        self,
        body: Callable[[ThreadedRunHandle], None],
        *,
        name: str = "cowork-unattended",
    ) -> None:
        self._queue: Queue[RunEvent] = Queue()
        self._cancelled = threading.Event()
        self._thread = threading.Thread(
            target=self._wrap, args=(body,), name=name, daemon=True
        )
        self._thread.start()

    def _wrap(self, body: Callable[[ThreadedRunHandle], None]) -> None:
        try:
            body(self)
        except BaseException as exc:  # surface, never swallow into a dead run
            self.emit(RunEvent(RunEventKind.ERROR, f"{type(exc).__name__}: {exc}"))

    def emit(self, event: RunEvent) -> None:
        self._queue.put(event)

    @property
    def cancelled(self) -> bool:
        return self._cancelled.is_set()

    def next_event(self, timeout: float) -> RunEvent | None:
        try:
            return self._queue.get(timeout=timeout)
        except Empty:
            return None

    def cancel(self, reason: str) -> None:
        self._cancelled.set()


# --------------------------------------------------------------------------
# Job actions — how a scheduled job reaches each mode
# --------------------------------------------------------------------------

#: Prompt for a woken hash-diff monitor. The diff replaces the whole source.
MONITOR_PROMPT = (
    "{brief}\n\n"
    "The watched source changed. Unified diff:\n\n"
    "```diff\n{diff}```\n"
)


@dataclass
class JobDispatcher:
    """Builds the ``action`` callables the scheduler fires, one per mode.

    Keeping the modes here (and not in the scheduler) is what makes the cost
    levers auditable: ``script_action`` never touches ``runner``, so a
    ``no_agent`` job provably cannot spend a token.
    """

    runner: UnattendedRunner
    outcomes: list[RunOutcome] = field(default_factory=list)

    # -- agent mode --------------------------------------------------------

    def agent_action(
        self,
        prompt: str,
        *,
        session_key: str | None = None,
        skip_memory: bool = True,
        skip_background_review: bool = True,
    ) -> Callable[[Job, datetime], RunOutcome]:
        """Wake a fresh agent with a fixed prompt on every fire."""

        def action(job: Job, now: datetime) -> RunOutcome:
            spec = RunSpec(
                job_id=job.id,
                prompt=prompt,
                agent_id=job.agent_id,
                session_key=session_key,
                skip_memory=skip_memory,
                skip_background_review=skip_background_review,
            )
            return self._run(spec)

        return action

    # -- monitor mode (hash-diff) -----------------------------------------

    def monitor_action(
        self,
        brief: str,
        *,
        session_key: str | None = None,
    ) -> Callable[[Job, datetime], RunOutcome]:
        """Wake an agent **only on a change**, handing it the unified diff.

        The scheduler calls this action solely when the source's hash moved, so
        an unchanged tick costs nothing beyond one hash.
        """

        def action(job: Job, now: datetime) -> RunOutcome:
            signal = job.last_signal
            diff = signal.diff if signal is not None else None
            spec = RunSpec(
                job_id=job.id,
                prompt=MONITOR_PROMPT.format(brief=brief, diff=diff or ""),
                agent_id=job.agent_id,
                session_key=session_key,
            )
            return self._run(spec)

        return action

    # -- no_agent mode -----------------------------------------------------

    @staticmethod
    def script_action(
        script: Callable[[], Any],
    ) -> Callable[[Job, datetime], Any]:
        """Run a bare callable on schedule. No agent, no model, zero tokens."""

        def action(job: Job, now: datetime) -> Any:
            return script()

        return action

    def _run(self, spec: RunSpec) -> RunOutcome:
        outcome = self.runner.run(spec)
        self.outcomes.append(outcome)
        return outcome


# --------------------------------------------------------------------------
# Roster wiring
# --------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class ScheduleError:
    """An agent whose stored schedule string does not parse."""

    agent_id: str
    agent_name: str
    schedule: str
    reason: str


def load_roster_schedules(
    roster: Any,
    scheduler: Scheduler,
    dispatcher: JobDispatcher,
    *,
    now: datetime,
    session_key_for: Callable[[Any], str | None] | None = None,
) -> tuple[list[Job], list[ScheduleError]]:
    """Register one recurring job per roster agent that carries a schedule.

    The roster already stores the model-emitted schedule string per agent; this
    is what turns those rows into live jobs at Manager start-up. A row whose
    string does not parse is reported, never raised — one bad agent must not
    stop the other agents from being scheduled. The agent's persona is the
    prompt, and jobs run with ``autorelease=False`` because an unattended run
    owns its claim until it finishes.
    """
    jobs: list[Job] = []
    errors: list[ScheduleError] = []
    for agent in roster.list():
        schedule = (agent.schedule or "").strip()
        if not schedule:
            continue
        session_key = session_key_for(agent) if session_key_for else None
        try:
            job = scheduler.schedule(
                agent.id,
                schedule,
                now=now,
                action=dispatcher.agent_action(
                    agent.persona, session_key=session_key
                ),
                agent_id=agent.id,
                autorelease=False,
            )
        except ValueError as exc:
            errors.append(
                ScheduleError(
                    agent_id=agent.id,
                    agent_name=agent.name,
                    schedule=schedule,
                    reason=str(exc),
                )
            )
            continue
        jobs.append(job)
    return jobs, errors
