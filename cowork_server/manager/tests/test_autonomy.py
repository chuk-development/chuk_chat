"""Unattended runs (§13): fresh-agent flags, inactivity timeout, [SILENT]
delivery, the push notifier seam, and the two cost modes.

Every test drives an injected clock and a fake run handle — nothing sleeps, and
the fake "model" counts how often it was built so the cost claims are checked,
not asserted by hand.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

import pytest

from cowork_manager.autonomy import (
    JobDispatcher,
    Notification,
    NotificationKind,
    RunEvent,
    RunEventKind,
    RunOutcome,
    RunSpec,
    RunStatus,
    ThreadedRunHandle,
    UnattendedRunner,
    should_deliver,
)
from cowork_manager.scheduler import JobMode, Scheduler, utc

NOW = utc(2026, 2, 3, 12, 0)


# -- fakes ------------------------------------------------------------------


class FakeClock:
    """A clock the test advances by hand. ``HANG`` events push it forward."""

    def __init__(self, start: datetime = NOW) -> None:
        self.t = start

    def __call__(self) -> datetime:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += timedelta(seconds=seconds)


HANG = object()  # a scripted "nothing happened in the window" gap


class FakeRun:
    """Scripted run: a list of events, optionally with ``HANG`` gaps."""

    def __init__(self, script: list[Any], clock: FakeClock) -> None:
        self._script = list(script)
        self._clock = clock
        self.cancelled: str | None = None

    def next_event(self, timeout: float) -> RunEvent | None:
        if not self._script:
            return None
        item = self._script.pop(0)
        if item is HANG:
            # The window elapsed with no event — a hung call.
            self._clock.advance(timeout)
            return None
        # Real work takes time: every event costs a chunk of the timeout window.
        self._clock.advance(timeout / 2)
        return item

    def cancel(self, reason: str) -> None:
        self.cancelled = reason


class FakeModel:
    """Counts how often an agent was actually built. The cost oracle."""

    def __init__(self, clock: FakeClock, script: list[Any] | None = None) -> None:
        self.clock = clock
        self.calls = 0
        self.prompts: list[str] = []
        self.specs: list[RunSpec] = []
        self.script = script or [RunEvent(RunEventKind.FINAL, "done")]

    def __call__(self, spec: RunSpec) -> FakeRun:
        self.calls += 1
        self.prompts.append(spec.prompt)
        self.specs.append(spec)
        return FakeRun(list(self.script), self.clock)


def collector() -> tuple[list[Notification], Any]:
    seen: list[Notification] = []
    return seen, seen.append


# -- fresh unattended agent -------------------------------------------------


def test_fired_job_builds_a_fresh_agent_with_no_human_in_the_loop() -> None:
    clock = FakeClock()
    model = FakeModel(clock)
    notes, notifier = collector()
    runner = UnattendedRunner(agent_factory=model, notifier=notifier, now=clock)

    outcome = runner.run(RunSpec(job_id="j", prompt="check the build"))

    assert outcome.status is RunStatus.COMPLETED
    spec = model.specs[0]
    assert spec.skip_memory is True             # nobody to answer a memory prompt
    assert spec.skip_background_review is True  # nobody to read a review
    assert spec.attach_to_session is False
    assert [n.kind for n in notes] == [NotificationKind.COMPLETED]


def test_attach_to_session_makes_the_run_continuable() -> None:
    clock = FakeClock()
    model = FakeModel(clock)
    notes, notifier = collector()
    runner = UnattendedRunner(agent_factory=model, notifier=notifier, now=clock)

    runner.run(RunSpec(job_id="j", prompt="p", session_key="chat-7"))

    assert model.specs[0].attach_to_session is True
    assert notes[0].session_key == "chat-7"     # the push points at that chat


def test_run_heartbeats_the_scheduler_so_it_is_not_redispatched() -> None:
    clock = FakeClock()
    model = FakeModel(
        clock,
        script=[
            RunEvent(RunEventKind.ACTIVITY, "tool"),
            RunEvent(RunEventKind.ACTIVITY, "tool"),
            RunEvent(RunEventKind.FINAL, "done"),
        ],
    )
    beats: list[tuple[str, datetime]] = []
    runner = UnattendedRunner(
        agent_factory=model,
        now=clock,
        heartbeat=lambda job_id, now: beats.append((job_id, now)),
    )

    runner.run(RunSpec(job_id="j", prompt="p"))

    assert [b[0] for b in beats] == ["j", "j", "j"]
    assert beats == sorted(beats, key=lambda b: b[1])


# -- inactivity (not wall-clock) timeout ------------------------------------


def test_inactivity_timeout_kills_a_hang_even_after_hours_of_work() -> None:
    clock = FakeClock()
    # Six hours of real work (12 events x 30 min), then a hung API call.
    script: list[Any] = [RunEvent(RunEventKind.ACTIVITY, "step")] * 12 + [HANG]
    model = FakeModel(clock, script=script)
    notes, notifier = collector()
    runner = UnattendedRunner(
        agent_factory=model,
        notifier=notifier,
        now=clock,
        inactivity_timeout=3600.0,
    )

    outcome = runner.run(RunSpec(job_id="j", prompt="long job"))

    assert outcome.status is RunStatus.INACTIVITY_TIMEOUT
    # The job worked for hours — the wall clock is NOT what killed it.
    assert outcome.elapsed_seconds > 6 * 3600
    assert outcome.events == 12
    assert [n.kind for n in notes] == [NotificationKind.FAILED]
    assert "no activity" in notes[0].text


def test_inactivity_timeout_cancels_the_run() -> None:
    clock = FakeClock()
    runs: list[FakeRun] = []

    def factory(spec: RunSpec) -> FakeRun:
        run = FakeRun([HANG], clock)
        runs.append(run)
        return run

    runner = UnattendedRunner(agent_factory=factory, now=clock, inactivity_timeout=60)
    outcome = runner.run(RunSpec(job_id="j", prompt="p"))

    assert outcome.status is RunStatus.INACTIVITY_TIMEOUT
    assert runs[0].cancelled == "inactivity timeout"


def test_run_error_is_reported_and_not_delivered() -> None:
    clock = FakeClock()
    model = FakeModel(clock, script=[RunEvent(RunEventKind.ERROR, "provider 500")])
    notes, notifier = collector()
    runner = UnattendedRunner(agent_factory=model, notifier=notifier, now=clock)

    outcome = runner.run(RunSpec(job_id="j", prompt="p"))

    assert outcome.status is RunStatus.FAILED
    assert outcome.delivered is False
    assert notes[0].kind is NotificationKind.FAILED


# -- delivery & [SILENT] ----------------------------------------------------


def test_should_deliver_rules() -> None:
    assert should_deliver("here is the report") is True
    assert should_deliver("") is False
    assert should_deliver("   \n ") is False
    assert should_deliver(None) is False
    assert should_deliver("[SILENT]") is False
    assert should_deliver("  [SILENT] nothing changed ") is False


def test_final_answer_is_delivered_to_the_origin_chat() -> None:
    clock = FakeClock()
    model = FakeModel(clock, script=[RunEvent(RunEventKind.FINAL, "build is green")])
    notes, notifier = collector()
    runner = UnattendedRunner(agent_factory=model, notifier=notifier, now=clock)

    outcome = runner.run(RunSpec(job_id="j", prompt="p", session_key="chat-1"))

    assert outcome.delivered is True
    assert notes == [
        Notification(
            job_id="j",
            kind=NotificationKind.COMPLETED,
            text="build is green",
            agent_id=None,
            session_key="chat-1",
            at=clock.t,
        )
    ]


def test_silent_marker_suppresses_the_delivery() -> None:
    clock = FakeClock()
    model = FakeModel(
        clock, script=[RunEvent(RunEventKind.FINAL, "[SILENT] nothing to report")]
    )
    notes, notifier = collector()
    runner = UnattendedRunner(agent_factory=model, notifier=notifier, now=clock)

    outcome = runner.run(RunSpec(job_id="j", prompt="p", session_key="chat-1"))

    assert outcome.status is RunStatus.COMPLETED
    assert outcome.delivered is False
    assert notes == []           # no push for a job with nothing to say


def test_empty_answer_is_suppressed() -> None:
    clock = FakeClock()
    model = FakeModel(clock, script=[RunEvent(RunEventKind.FINAL, "  ")])
    notes, notifier = collector()
    runner = UnattendedRunner(agent_factory=model, notifier=notifier, now=clock)

    assert runner.run(RunSpec(job_id="j", prompt="p")).delivered is False
    assert notes == []


def test_approval_pushes_and_keeps_waiting() -> None:
    clock = FakeClock()
    model = FakeModel(
        clock,
        script=[
            RunEvent(RunEventKind.APPROVAL, "may I push to master?"),
            RunEvent(RunEventKind.FINAL, "pushed"),
        ],
    )
    notes, notifier = collector()
    runner = UnattendedRunner(agent_factory=model, notifier=notifier, now=clock)

    outcome = runner.run(RunSpec(job_id="j", prompt="p"))

    assert outcome.status is RunStatus.COMPLETED
    assert [n.kind for n in notes] == [
        NotificationKind.APPROVAL_NEEDED,
        NotificationKind.COMPLETED,
    ]


def test_runner_without_a_notifier_still_runs() -> None:
    clock = FakeClock()
    outcome = UnattendedRunner(agent_factory=FakeModel(clock), now=clock).run(
        RunSpec(job_id="j", prompt="p")
    )
    assert outcome.status is RunStatus.COMPLETED


# -- cost mode: no_agent (zero tokens) --------------------------------------


def test_no_agent_job_never_builds_an_agent() -> None:
    clock = FakeClock()
    model = FakeModel(clock)
    dispatcher = JobDispatcher(
        runner=UnattendedRunner(agent_factory=model, now=clock)
    )

    ran: list[str] = []
    sch = Scheduler()
    sch.schedule(
        "backup",
        "every 30m",
        now=NOW,
        mode=JobMode.NO_AGENT,
        action=dispatcher.script_action(lambda: ran.append("rsync")),
    )

    for i in range(1, 5):
        sch.tick(NOW + timedelta(minutes=30 * i))

    assert ran == ["rsync"] * 4
    assert model.calls == 0          # four runs, zero model calls, zero tokens


# -- cost mode: hash-diff monitor -------------------------------------------


def test_monitor_wakes_the_model_only_on_a_change_and_passes_the_diff() -> None:
    clock = FakeClock()
    model = FakeModel(clock)
    dispatcher = JobDispatcher(
        runner=UnattendedRunner(agent_factory=model, now=clock)
    )

    state = {"data": b"status: ok\nbuild: 41\n"}
    sch = Scheduler()
    sch.schedule(
        "watch",
        "every 30m",
        now=NOW,
        mode=JobMode.MONITOR,
        source=lambda: state["data"],
        action=dispatcher.monitor_action("Watch the CI status page."),
    )

    sch.tick(NOW + timedelta(minutes=30))            # baseline wake
    assert model.calls == 1
    baseline_prompt = model.prompts[0]

    # Ten unchanged ticks: the hash matches, so no agent is built at all.
    for i in range(2, 12):
        sch.tick(NOW + timedelta(minutes=30 * i))
    assert model.calls == 1

    # The bytes move: exactly one wake, and the prompt carries the diff — not
    # the whole page.
    state["data"] = b"status: FAILED\nbuild: 42\n"
    sch.tick(NOW + timedelta(minutes=30 * 12))

    assert model.calls == 2
    prompt = model.prompts[1]
    assert "Watch the CI status page." in prompt
    assert "-status: ok" in prompt
    assert "+status: FAILED" in prompt
    assert "```diff" in prompt
    assert baseline_prompt != prompt


def test_dispatcher_records_outcomes() -> None:
    clock = FakeClock()
    dispatcher = JobDispatcher(
        runner=UnattendedRunner(agent_factory=FakeModel(clock), now=clock)
    )
    sch = Scheduler()
    sch.schedule(
        "j", "every 30m", now=NOW, action=dispatcher.agent_action("do the thing")
    )

    sch.tick(NOW + timedelta(minutes=30))

    assert len(dispatcher.outcomes) == 1
    assert isinstance(dispatcher.outcomes[0], RunOutcome)
    assert dispatcher.outcomes[0].status is RunStatus.COMPLETED


# -- production run handle ---------------------------------------------------


def test_threaded_handle_streams_events_and_reports_a_crash() -> None:
    def body(handle: ThreadedRunHandle) -> None:
        handle.emit(RunEvent(RunEventKind.ACTIVITY, "step"))
        raise RuntimeError("agent blew up")

    handle = ThreadedRunHandle(body)
    first = handle.next_event(timeout=5)
    second = handle.next_event(timeout=5)

    assert first == RunEvent(RunEventKind.ACTIVITY, "step")
    assert second.kind is RunEventKind.ERROR
    assert "agent blew up" in second.text


def test_threaded_handle_reports_a_gap_as_none() -> None:
    handle = ThreadedRunHandle(lambda h: None)
    handle.next_event(timeout=0.05)          # drains nothing; the body is empty
    assert handle.next_event(timeout=0.01) is None
    handle.cancel("done")
    assert handle.cancelled is True


def test_threaded_handle_end_to_end_with_the_runner() -> None:
    def body(handle: ThreadedRunHandle) -> None:
        handle.emit(RunEvent(RunEventKind.ACTIVITY, "thinking"))
        handle.emit(RunEvent(RunEventKind.FINAL, "all good"))

    notes, notifier = collector()
    runner = UnattendedRunner(
        agent_factory=lambda spec: ThreadedRunHandle(body),
        notifier=notifier,
        inactivity_timeout=5.0,
    )

    outcome = runner.run(RunSpec(job_id="j", prompt="p"))

    assert outcome.status is RunStatus.COMPLETED
    assert outcome.final_answer == "all good"
    assert notes[0].kind is NotificationKind.COMPLETED


@pytest.mark.parametrize("kind", list(RunEventKind))
def test_run_event_kinds_are_all_handled(kind: RunEventKind) -> None:
    clock = FakeClock()
    script = [RunEvent(kind, "x")]
    if kind in (RunEventKind.ACTIVITY, RunEventKind.APPROVAL):
        script.append(RunEvent(RunEventKind.FINAL, "done"))
    runner = UnattendedRunner(agent_factory=FakeModel(clock, script), now=clock)

    outcome = runner.run(RunSpec(job_id="j", prompt="p"))

    expected = (
        RunStatus.FAILED if kind is RunEventKind.ERROR else RunStatus.COMPLETED
    )
    assert outcome.status is expected


# -- roster wiring -----------------------------------------------------------


def test_roster_schedules_become_jobs_and_bad_ones_are_reported() -> None:
    from cowork_manager.autonomy import load_roster_schedules
    from cowork_manager.roster import RosterStore

    clock = FakeClock()
    model = FakeModel(clock)
    dispatcher = JobDispatcher(
        runner=UnattendedRunner(agent_factory=model, now=clock)
    )
    sch = Scheduler()

    with RosterStore() as roster:
        good = roster.create(
            workspace_dir="/w/a", persona="Post the daily digest.",
            schedule="0 9 * * *", name="ada",
        )
        roster.create(workspace_dir="/w/b", persona="No schedule.", name="bob")
        bad = roster.create(
            workspace_dir="/w/c", persona="x", schedule="every banana", name="cid"
        )

        jobs, errors = load_roster_schedules(roster, sch, dispatcher, now=NOW)

    assert [j.id for j in jobs] == [good.id]
    assert jobs[0].agent_id == good.id
    assert jobs[0].autorelease is False       # the run owns its claim
    assert [e.agent_id for e in errors] == [bad.id]
    assert errors[0].agent_name == "cid"

    # The registered job really runs the agent with the persona as its prompt.
    sch.tick(NOW + timedelta(days=1))
    assert model.prompts == ["Post the daily digest."]


def test_zero_interval_is_rejected() -> None:
    from cowork_manager.scheduler import parse_schedule

    with pytest.raises(ValueError):
        parse_schedule("every 0m")
