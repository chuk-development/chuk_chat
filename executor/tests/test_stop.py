"""The Stop button, end to end over the sealed channel (§7.1 × §14 × §16).

The app's Stop was a frame the executor threw away: unknown types were ignored,
so the run kept going and the UI sat on "Stopping…" forever. These tests pin the
wiring that replaced that silence.

Every wait here is a barrier on something observable — a model turn that has
started, a file the command created, an ack that came back. Nothing sleeps hoping
the race went the right way.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass

import pytest
from cowork_crypto import CoworkFrameSealer, DeviceIdentity
from cowork_manager import encode_frame, make_request
from cowork_sandbox import LocalEnvironment

from cowork_agent import MockModelClient, ModelResponse
from cowork_executor import (
    METHOD_STOP,
    ControllerSession,
    Executor,
    encode_payload,
    frame_to_b64,
    loopback_pair,
    stop_payload,
)

from wiring import KEY_VERSION, paired_channel


class GatedModel:
    """A model that blocks in the middle of a turn, so a run is provably in
    flight when the stop is sent.

    It mirrors the real :class:`~cowork_agent.BackendModelClient` on the one point
    that matters here: ``cancel()`` unblocks the wait and the turn then **fails**
    instead of returning an answer, exactly as a socket closed under a blocking
    ``recv`` does. The executor finds that ``cancel`` by name and hangs it on the
    task's kill switch, so this double exercises the production seam.
    """

    def __init__(self) -> None:
        self.started = threading.Event()
        self.cancelled = False
        self._gate = threading.Event()

    def complete(self, messages: list[dict]) -> ModelResponse:
        self.started.set()
        if not self._gate.wait(15.0):  # a wedged test must fail, not hang
            raise AssertionError("the model gate never opened")
        if self.cancelled:
            raise RuntimeError("model call cancelled")
        return ModelResponse(text="done")

    def cancel(self) -> None:
        self.cancelled = True
        self._gate.set()

    def release(self) -> None:
        """Let the turn finish normally (the 'the stop did nothing' path)."""
        self._gate.set()


def _executor(tmp_path, channel, executor_ep, model_factory, **kwargs) -> Executor:
    return Executor(
        name="worker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        **kwargs,
    )


def _controller(channel, controller_ep) -> ControllerSession:
    return ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )


@dataclass
class Rig:
    channel: object
    controller: ControllerSession
    controller_ep: object
    executor: Executor
    model: GatedModel


@pytest.fixture
def gated(tmp_path):
    """A started executor whose one task blocks until stopped or released."""
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    model = GatedModel()
    executor = _executor(tmp_path, channel, executor_ep, lambda: model)
    controller = _controller(channel, controller_ep)
    executor.start()
    try:
        yield Rig(channel, controller, controller_ep, executor, model)
    finally:
        model.release()  # never leave the worker parked on the gate
        executor.stop()


def test_a_stop_ends_the_running_task_with_reason_interrupted(gated):
    controller, model = gated.controller, gated.model

    request_id = controller.send_task("work forever", session_key="thread-1")
    assert model.started.wait(10.0), "the task never reached the model"

    stop_id = controller.send_stop(session_key="thread-1")
    ack = controller.collect(stop_id, timeout=10.0)[-1]
    assert ack["type"] == "stop_ack"
    assert ack["stopping"] == [request_id]

    events = controller.collect(request_id, timeout=10.0)
    done = events[-1]
    assert done["type"] == "done", f"stream did not close: {events}"
    # The exact terminal the app already renders as "stopped".
    assert done["reason"] == "interrupted"
    assert done["final_answer"] is None
    # The model was cancelled where it stood, not waited out.
    assert model.cancelled is True


def test_a_stop_naming_the_request_id_stops_that_run(gated):
    controller, model = gated.controller, gated.model

    request_id = controller.send_task("work forever", session_key="thread-1")
    assert model.started.wait(10.0)

    stop_id = controller.send_stop(request_id=request_id)
    assert controller.collect(stop_id, timeout=10.0)[-1]["stopping"] == [request_id]
    assert controller.collect(request_id, timeout=10.0)[-1]["reason"] == "interrupted"


def test_a_stop_with_the_wrong_request_id_does_nothing(gated):
    controller, model = gated.controller, gated.model

    request_id = controller.send_task("work", session_key="thread-1")
    assert model.started.wait(10.0)

    stop_id = controller.send_stop(request_id="task-does-not-exist")
    ack = controller.collect(stop_id, timeout=10.0)[-1]
    assert ack["type"] == "stop_ack"
    assert ack["stopping"] == []  # nothing matched, and it says so

    # The run is untouched: released, it finishes normally.
    model.release()
    done = controller.collect(request_id, timeout=10.0)[-1]
    assert done["reason"] == "finished"
    assert done["final_answer"] == "done"
    assert model.cancelled is False


def test_a_stop_for_another_session_does_nothing(gated):
    controller, model = gated.controller, gated.model

    request_id = controller.send_task("work", session_key="thread-1")
    assert model.started.wait(10.0)

    stop_id = controller.send_stop(session_key="some-other-thread")
    assert controller.collect(stop_id, timeout=10.0)[-1]["stopping"] == []

    model.release()
    assert controller.collect(request_id, timeout=10.0)[-1]["reason"] == "finished"


def test_a_stop_from_an_unapproved_device_is_rejected(gated):
    """Default deny is the whole authorisation story for Stop: a stop is a sealed
    frame, so a device the executor never approved cannot end a run — even though
    it knows the channel key and the wire format."""
    channel, controller, model = gated.channel, gated.controller, gated.model

    request_id = controller.send_task("work", session_key="thread-1")
    assert model.started.wait(10.0)

    # An intruder with the channel key but an UNAPPROVED signing identity.
    intruder = CoworkFrameSealer(
        channel_key=channel.channel_key,
        key_version=KEY_VERSION,
        device_id="intruder-phone",
        signing_identity=DeviceIdentity.generate(),
    )
    sealed = intruder.seal(encode_payload(stop_payload(session_key="thread-1")))
    envelope = make_request(
        METHOD_STOP, {"frame": frame_to_b64(sealed.to_bytes())}, "evil-1"
    )
    # Registered on the session only so ``collect`` can match the executor's
    # answer to it; the frame itself is signed by the intruder, not by the app.
    controller._corr.register(envelope)
    gated.controller_ep.send(encode_frame(envelope))

    rejected = controller.collect("evil-1", timeout=10.0)[-1]
    assert rejected["type"] == "error"
    assert rejected["message"].startswith("rejected:")

    # And the run it tried to kill is still running: released, it finishes.
    assert model.cancelled is False
    model.release()
    assert controller.collect(request_id, timeout=10.0)[-1]["reason"] == "finished"


def test_a_stop_after_done_is_a_harmless_no_op(tmp_path):
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(
        tmp_path, channel, executor_ep, lambda: MockModelClient(["done"])
    )
    controller = _controller(channel, controller_ep)
    executor.start()
    try:
        request_id = controller.send_task("say done", session_key="thread-1")
        assert controller.collect(request_id, timeout=10.0)[-1]["reason"] == "finished"

        # The user hits Stop one moment too late.
        stop_id = controller.send_stop(session_key="thread-1")
        ack = controller.collect(stop_id, timeout=10.0)[-1]
        assert ack["type"] == "stop_ack"
        assert ack["stopping"] == []
    finally:
        executor.stop()


def test_a_stop_kills_the_command_in_flight(tmp_path):
    """A stop during a long ``run_command`` must not wait for the command.

    The sandbox is real and the command sleeps for a minute; the barrier is the
    file the command creates before it blocks, so the stop is provably sent while
    the shell is running. The run has to end in seconds, not in a minute.
    """
    workspace = tmp_path / "ws"
    workspace.mkdir()
    marker = workspace / "running"
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    model = MockModelClient(
        [
            '<tool_call>{"name":"run_command","arguments":'
            '{"command":"touch running && sleep 60","timeout":120}}</tool_call>',
            "done",
        ]
    )
    executor = _executor(tmp_path, channel, executor_ep, lambda: model)
    controller = _controller(channel, controller_ep)
    executor.start()
    try:
        request_id = controller.send_task("run the thing", session_key="thread-1")
        deadline = time.monotonic() + 20.0
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert marker.exists(), "the command never started"

        started = time.monotonic()
        controller.send_stop(session_key="thread-1")
        events = controller.collect(request_id, timeout=25.0)
        elapsed = time.monotonic() - started
    finally:
        executor.stop()

    done = events[-1]
    assert done["type"] == "done"
    assert done["reason"] == "interrupted"
    # 60s command, killed. The bound is the point: it did not run to the end.
    assert elapsed < 20.0, f"the stop waited {elapsed:.1f}s for the command"

    tools = [e for e in events if e["type"] == "tool"]
    assert len(tools) == 1
    # The killed command comes back as a failed command, not as an exception.
    assert tools[0]["exit_code"] != 0
    assert tools[0]["timed_out"] is False


def test_a_stop_on_a_queued_task_stops_it_before_it_starts(gated):
    """A second task queues behind the running one. Stopping it must work even
    though it has not started: its kill switch exists from the moment the frame
    was accepted."""
    controller, model = gated.controller, gated.model

    first = controller.send_task("work forever", session_key="thread-1")
    assert model.started.wait(10.0)
    second = controller.send_task("the queued one", session_key="thread-2")

    stop_id = controller.send_stop(request_id=second)
    assert controller.collect(stop_id, timeout=10.0)[-1]["stopping"] == [second]

    # Let the first one go; the second must come back stopped without a turn.
    model.release()
    assert controller.collect(first, timeout=10.0)[-1]["reason"] == "finished"
    queued = controller.collect(second, timeout=10.0)[-1]
    assert queued["type"] == "done"
    assert queued["reason"] == "interrupted"
    assert queued["iterations"] == 0


def test_a_stop_must_name_a_target():
    """"Stop whatever is running" is not offered: the run the user meant can
    finish while the frame is in flight, and the stop would kill the next one."""
    with pytest.raises(ValueError):
        stop_payload()


def test_the_serve_loop_reads_while_a_task_runs(gated):
    """The regression that made Stop impossible: the task ran on the serve
    thread, so no frame could be read until the run was over."""
    controller, model = gated.controller, gated.model

    controller.send_task("work forever", session_key="thread-1")
    assert model.started.wait(10.0)

    # A frame sent mid-run is answered mid-run.
    stop_id = controller.send_stop(request_id="nobody")
    assert controller.collect(stop_id, timeout=5.0)[-1]["type"] == "stop_ack"


def test_stopping_the_executor_interrupts_the_run_in_flight(tmp_path):
    """Shutting the executor down must not wait for whatever the model and its
    commands feel like doing: the same kill switch is fired first."""
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    model = GatedModel()
    executor = _executor(tmp_path, channel, executor_ep, lambda: model)
    controller = _controller(channel, controller_ep)
    executor.start()
    request_id = controller.send_task("work forever", session_key="thread-1")
    assert model.started.wait(10.0)

    started = time.monotonic()
    executor.stop()
    assert time.monotonic() - started < 10.0, "stop() waited for the run"

    assert model.cancelled is True
    assert controller.collect(request_id, timeout=5.0)[-1]["reason"] == "interrupted"
