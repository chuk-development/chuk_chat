"""A finished background job wakes the model (docs/WIRE_CONTRACT.md,
"Interactive shell and background commands", "The wake-up").

Idle session -> a new task of that session (``origin: job``). Live run -> the
wake text is appended to the running turn before its next model round, on
the same stream as its deltas. Unconsumed -> flushed as a task when the run
ends. Host restart -> the start-up sweep wakes what ended meanwhile. Cancelled
or malformed -> nothing.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.shell import DATA_MARKER, JOBS_DIRNAME, wake_text

from wiring import paired_channel

SESSION = "thread-1"


class _Recorder(MockModelClient):
    """Records the messages of every round so a test can look at what the
    model was handed. ``script`` is picked by the LAST user message: a task
    that starts with ``[job `` (a wake task) answers with prose."""

    rounds: list[list[dict]] = []

    def __init__(self, live_script: list) -> None:
        super().__init__([])
        self._live_script = list(live_script)
        self._chosen = False

    def complete(self, messages):
        if not self._chosen:
            self._chosen = True
            last_user = next((m for m in reversed(messages) if m.get("role") == "user"), {})
            text = str(last_user.get("content") or "")
            self._responses = ["Noted the job result."] if text.startswith("[job ") else list(self._live_script)
        _Recorder.rounds.append([dict(m) for m in messages])
        return super().complete(messages)


def _boot(tmp_path, live_script, **kw):
    _Recorder.rounds = []
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    executor = Executor(
        name="jobs",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: _Recorder(live_script),
        workspace=str(workspace),
        **kw,
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    return executor, controller, workspace


def _job_files(workspace: Path, job_id: str, *, exit_code: int | None = None, log: str, cancelled: bool = False) -> None:
    """The files the sandbox wrapper leaves. ``exit_code`` writes ``.exit`` —
    only the sweep tests want that, because the executor's start-up sweep
    wakes every ``.exit`` it finds."""
    d = workspace / JOBS_DIRNAME
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{job_id}.json").write_text(json.dumps({"job_id": job_id, "command": "make all", "session_key": SESSION, "started_at": 1}))
    (d / f"{job_id}.log").write_text(log)
    if exit_code is not None:
        (d / f"{job_id}.exit").write_text(str(exit_code))
    if cancelled:
        (d / f"{job_id}.cancelled").write_text("")


def _record(job_id: str, exit_code: int = 0, **extra) -> dict:
    return {"kind": "job", "job_id": job_id, "session_key": SESSION, "exit_code": exit_code, "timed_out": False, "ts": 1.0, **extra}


def _wait_for_run(db_path: str, *, prefix: str, timeout: float = 15.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        store = StateStore(db_path)
        try:
            last = store.latest_run(SESSION)
        finally:
            store.close()
        if last and str(last.get("prompt", "")).startswith(prefix) and last.get("state") == "finished":
            return last
        time.sleep(0.05)
    raise AssertionError(f"no finished run with prompt {prefix!r}")


# -- the text -------------------------------------------------------------------------


def test_wake_text_marks_the_output_as_data():
    text = wake_text(job_id="j0000abcd", state="finished", exit_code=0, command="make", log_path="x.log", tail="ok\nbuilt")
    assert text.splitlines()[0] == f"[job j0000abcd finished: exit 0] — {DATA_MARKER}"
    assert "make" in text and text.endswith("ok\nbuilt")
    failed = wake_text(job_id="j0000abcd", state="timed_out", exit_code=124, command=None, log_path="x", tail="")
    assert failed.startswith("[job j0000abcd timed out after 24 h: exit 124]") and "(no output)" in failed
    assert "not readable" in wake_text(job_id="j0000abcd", state="failed", exit_code=1, command=None, log_path="x", tail=None)


# -- idle: a new task -------------------------------------------------------------------


def test_an_idle_session_gets_a_new_task_with_the_tail(tmp_path):
    sent: list[dict] = []
    executor, _controller, workspace = _boot(tmp_path, ["unused"], job_frame_sender=sent.append)
    _job_files(workspace, "j0000aaaa", log="\n".join(f"line {i}" for i in range(1, 301)))
    executor.start()
    try:
        outcome = executor.job_finished(_record("j0000aaaa"))
        assert outcome == "task"
        run = _wait_for_run(str(tmp_path / "state.db"), prefix="[job j0000aaaa finished: exit 0]")
    finally:
        executor.stop()
    prompt = run["prompt"]
    assert DATA_MARKER in prompt.splitlines()[0]
    assert "make all" in prompt
    assert "--- last 200 lines of .agents/jobs/j0000aaaa.log ---" in prompt
    assert "line 101" in prompt and "line 100" not in prompt and prompt.endswith("line 300")
    # No run was live, so the frame went through the host's sender...
    assert [p["type"] for p in sent] == ["job"]
    assert sent[0]["job_id"] == "j0000aaaa" and sent[0]["state"] == "finished" and sent[0]["exit_code"] == 0
    # ...and is persisted as an event row, replayed as itself.
    store = StateStore(str(tmp_path / "state.db"))
    try:
        events = [e for e in store.replay_events(store.route(SESSION)) if e["type"] == "job"]
    finally:
        store.close()
    assert len(events) == 1 and events[0]["replay"] is True and events[0]["tail"].endswith("line 300")
    assert (workspace / JOBS_DIRNAME / "j0000aaaa.woken").exists()
    assert executor.jobs.delivered_tasks == 1
    # Told once: the same job again (a sweep after the line) does nothing.
    assert executor.jobs.finished(_record("j0000aaaa")) == "ignored"


# -- live: into the running turn --------------------------------------------------------


def test_a_live_run_gets_the_wake_before_its_next_round(tmp_path):
    executor, controller, workspace = _boot(
        tmp_path,
        [tool_call_response(("run_command", {"command": "sleep 1.2"})), "done after the job"],
    )
    _job_files(workspace, "j0000bbbb", log="boom")
    executor.start()
    try:
        rid = controller.send_task("start something", session_key=SESSION)
        deadline = time.time() + 10
        while time.time() < deadline and not executor.live_request_id(SESSION):
            time.sleep(0.02)
        assert executor.live_request_id(SESSION) == rid
        outcome = executor.job_finished(_record("j0000bbbb", exit_code=3))
        events = controller.collect(rid, timeout=20.0)
    finally:
        executor.stop()
    assert outcome == "context"
    # The model's second round saw the wake as a user message, after the tool result.
    assert len(_Recorder.rounds) >= 2
    second = _Recorder.rounds[1]
    wake = [m for m in second if m.get("role") == "user" and str(m.get("content", "")).startswith("[job j0000bbbb finished: exit 3]")]
    assert wake, [m.get("role") for m in second]
    assert DATA_MARKER in wake[0]["content"] and wake[0]["content"].endswith("boom")
    assert second.index(wake[0]) > max(i for i, m in enumerate(second) if m.get("role") == "tool")
    # The frame rode the live stream, between the tool card and the done.
    kinds = [e["type"] for e in events]
    assert "job" in kinds and kinds[-1] == "done" and kinds.index("job") < kinds.index("done")
    job = next(e for e in events if e["type"] == "job")
    assert job["state"] == "failed" and job["exit_code"] == 3 and job["tail"] == "boom"
    # One run only: nothing was started for the job.
    store = StateStore(str(tmp_path / "state.db"))
    try:
        sid = store.route(SESSION)
        rows = store.get_conversation(sid)
        runs = store.run_terminals(SESSION)
    finally:
        store.close()
    assert len(runs) == 1
    assert [m.role for m in rows if m.role == "context"] == ["context"]
    assert executor.jobs.delivered_context == 1 and executor.jobs.delivered_tasks == 0


def test_an_unconsumed_wake_is_flushed_as_a_task_when_the_run_ends(tmp_path, monkeypatch):
    executor, _controller, workspace = _boot(tmp_path, ["unused"])
    _job_files(workspace, "j0000cccc", log="fine")
    executor.start()
    try:
        # Pretend a run of the session is queued but never reaches a tool round.
        monkeypatch.setattr(executor, "has_live_run", lambda key: key == SESSION)
        assert executor.job_finished(_record("j0000cccc")) == "pending"
        assert executor.jobs.has_pending(SESSION)
        assert executor.jobs.flush_after_run(SESSION) is None  # still "live": keep it
        monkeypatch.setattr(executor, "has_live_run", lambda key: False)
        run_id = executor.jobs.flush_after_run(SESSION)
        assert run_id
        run = _wait_for_run(str(tmp_path / "state.db"), prefix="[job j0000cccc finished: exit 0]")
        assert run["run_id"] == run_id
        assert not executor.jobs.has_pending(SESSION)
    finally:
        executor.stop()


# -- restart: the sweep -----------------------------------------------------------------


def test_the_startup_sweep_wakes_jobs_that_ended_while_the_host_was_down(tmp_path):
    executor, _controller, workspace = _boot(tmp_path, ["unused"])
    _job_files(workspace, "j0000dddd", exit_code=0, log="finished offline")
    _job_files(workspace, "j0000eeee", exit_code=1, log="also offline")
    (workspace / JOBS_DIRNAME / "j0000eeee.woken").write_text("1")  # already told
    _job_files(workspace, "j0000ffff", exit_code=143, log="", cancelled=True)
    executor.start()
    try:
        run = _wait_for_run(str(tmp_path / "state.db"), prefix="[job j0000dddd finished: exit 0]")
        assert "finished offline" in run["prompt"]
        # Nothing else woke: eeee was told before, ffff was cancelled by the model.
        time.sleep(0.3)
        store = StateStore(str(tmp_path / "state.db"))
        try:
            runs = store.run_terminals(SESSION)
        finally:
            store.close()
        assert len(runs) == 1
        assert (workspace / JOBS_DIRNAME / "j0000ffff.woken").exists()
        assert executor.jobs.sweep() == 0
    finally:
        executor.stop()


def test_malformed_and_cancelled_records_are_ignored(tmp_path):
    executor, _controller, workspace = _boot(tmp_path, ["unused"])
    _job_files(workspace, "j00001111", log="", cancelled=True)
    executor.start()
    try:
        assert executor.job_finished({"kind": "job", "job_id": "../x", "session_key": SESSION}) == "ignored"
        assert executor.job_finished({"kind": "job", "job_id": "j00002222"}) == "ignored"
        assert executor.job_finished(_record("j00001111", exit_code=143)) == "ignored"
        time.sleep(0.2)
        store = StateStore(str(tmp_path / "state.db"))
        try:
            assert store.latest_run(SESSION) is None
        finally:
            store.close()
    finally:
        executor.stop()
