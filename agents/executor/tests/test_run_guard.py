"""The wall-clock guard for runs (Bead cowork-qxa).

A run that keeps going after the app detached had no upper bound on the host.
Now ``RUN_MAX_SECONDS`` (``COWORK_RUN_MAX_SECONDS``, default 7200) arms a
timer per run; on expiry the executor fires the run's kill switch exactly as a
user's stop does, and the run closes with ``reason == "timeout"`` — persisted
on the ``runs`` row, on the ``done`` frame and in the host's ``on_run_finished``
summary. A run that ends in time never sees the guard.
"""

from __future__ import annotations

import threading

from cowork_agent import MockModelClient, ModelResponse, StateStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor.executor import RUN_TIMEOUT_REASON

from wiring import paired_channel


class _GatedModel:
    """Blocks inside the turn until cancelled (the guard) or released."""

    def __init__(self) -> None:
        self.started = threading.Event()
        self.cancelled = False
        self._gate = threading.Event()

    def complete(self, messages: list[dict]) -> ModelResponse:
        self.started.set()
        if not self._gate.wait(15.0):
            raise AssertionError("the model gate never opened")
        if self.cancelled:
            raise RuntimeError("model call cancelled")
        return ModelResponse(text="done")

    def cancel(self) -> None:
        self.cancelled = True
        self._gate.set()

    def release(self) -> None:
        self._gate.set()


def _rig(tmp_path, model_factory, **kwargs):
    (tmp_path / "ws").mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="guarded",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        **kwargs,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def test_a_run_over_the_wall_clock_is_stopped_with_reason_timeout(tmp_path):
    model = _GatedModel()
    summaries: list[dict] = []
    executor, controller = _rig(
        tmp_path, lambda: model, run_max_seconds=0.5, on_run_finished=summaries.append
    )
    executor.start()
    try:
        request_id = controller.send_task("work forever", session_key="thread-1")
        assert model.started.wait(10.0), "the task never reached the model"
        events = controller.collect(request_id, timeout=15.0)
    finally:
        model.release()
        executor.stop()

    done = events[-1]
    assert done["type"] == "done", f"stream did not close: {events}"
    assert done["reason"] == RUN_TIMEOUT_REASON == "timeout"
    assert done["final_answer"] is None
    # Stopped where it stood, like a user's stop: the model call was cancelled.
    assert model.cancelled is True
    # The host's hook and the durable row carry the same reason.
    assert [s["reason"] for s in summaries] == ["timeout"]
    store = StateStore(str(tmp_path / "state.db"))
    try:
        row = store.get_run(done["run_id"])
    finally:
        store.close()
    assert row is not None and row["reason"] == "timeout"


def test_a_run_that_ends_in_time_never_meets_the_guard(tmp_path):
    executor, controller = _rig(
        tmp_path, lambda: MockModelClient(["quick answer"]), run_max_seconds=30.0
    )
    executor.start()
    try:
        request_id = controller.send_task("hi", session_key="thread-1")
        done = controller.collect(request_id, timeout=15.0)[-1]
    finally:
        executor.stop()
    assert done["type"] == "done" and done["reason"] == "finished"
    assert done["final_answer"] == "quick answer"


def test_zero_disables_the_guard(tmp_path):
    executor, _ = _rig(tmp_path, lambda: MockModelClient(["x"]), run_max_seconds=0)
    assert executor._arm_run_guard(None) is None  # type: ignore[arg-type]


def test_the_default_comes_from_the_module_constant(tmp_path, monkeypatch):
    import cowork_executor.executor as executor_module

    monkeypatch.setattr(executor_module, "RUN_MAX_SECONDS", 1234.0)
    executor, _ = _rig(tmp_path, lambda: MockModelClient(["x"]))
    assert executor._run_max_seconds == 1234.0
    executor2, _ = _rig(tmp_path, lambda: MockModelClient(["x"]), run_max_seconds=5)
    assert executor2._run_max_seconds == 5.0
