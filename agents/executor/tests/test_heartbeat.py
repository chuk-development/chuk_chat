"""The run heartbeat (``protocol.heartbeat_payload``).

A run that reads a 290k-token prompt, or that waits on a shell command, sends no
token at all while it works. The app then cannot tell that silence from a host
that is gone, and it used to guess wrong: a working run was reported to the user
as "the server may be overloaded". The heartbeat is the frame that removes the
guess — it says "this run is alive", it repeats on a fixed interval, and it stops
with the run.

Every wait here is a barrier on something observable: the model turn that has
started, the beats that have landed, the terminal that closed the stream.
"""

from __future__ import annotations

import threading

from chuk_agents_runtime import MockModelClient, ModelResponse, StateStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, heartbeat_payload, loopback_pair

from wiring import paired_channel


class _GatedModel:
    """Blocks inside the turn: a run that is provably in flight and silent."""

    def __init__(self) -> None:
        self.started = threading.Event()
        self._gate = threading.Event()

    def complete(self, messages: list[dict]) -> ModelResponse:
        self.started.set()
        if not self._gate.wait(15.0):  # a wedged test must fail, not hang
            raise AssertionError("the model gate never opened")
        return ModelResponse(text="done")

    def cancel(self) -> None:
        self._gate.set()

    def release(self) -> None:
        self._gate.set()


def _rig(tmp_path, model_factory, **kwargs):
    (tmp_path / "ws").mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="beating",
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


# -- the payload -------------------------------------------------------------


def test_the_payload_round_trips_what_routes_it():
    beat = heartbeat_payload(
        run_id="run-7", session_key="thread-1", seq=3, elapsed=31.4159
    )
    assert beat == {
        "type": "heartbeat",
        "seq": 3,
        "run_id": "run-7",
        "session_key": "thread-1",
        "elapsed": 31.416,
    }


def test_the_payload_leaves_out_what_it_was_not_told():
    assert heartbeat_payload() == {"type": "heartbeat", "seq": 0}


# -- the emitter -------------------------------------------------------------


def test_a_silent_run_still_says_it_is_alive(tmp_path):
    """The bug, from the wire side: the model sends nothing for a long time and
    the only frames on the stream are heartbeats."""
    model = _GatedModel()
    executor, controller = _rig(tmp_path, lambda: model, heartbeat_seconds=0.05)
    executor.start()
    try:
        request_id = controller.send_task("read a huge prompt", session_key="thread-1")
        assert model.started.wait(10.0), "the task never reached the model"
        # Read the stream while the turn is still gated: nothing but beats.
        # ``collect`` drains what it returns, so the beats are accumulated here.
        beats: list[dict] = []
        for _ in range(200):
            for event in controller.collect(request_id, timeout=0.05):
                assert event["type"] == "heartbeat", f"unexpected frame: {event}"
                beats.append(event)
            if len(beats) >= 3:
                break
        assert len(beats) >= 3, f"no heartbeat while the run was silent: {beats}"
        # It is routed like every other frame of this run, and it counts up.
        assert [b["seq"] for b in beats[:3]] == [1, 2, 3]
        assert all(b["session_key"] == "thread-1" for b in beats)
        assert all(b["run_id"] for b in beats)
        assert all(b["elapsed"] >= 0 for b in beats)
    finally:
        model.release()
        executor.stop()


def test_the_beat_stops_with_the_run(tmp_path):
    executor, controller = _rig(
        tmp_path, lambda: MockModelClient(["quick answer"]), heartbeat_seconds=0.05
    )
    executor.start()
    try:
        request_id = controller.send_task("hi", session_key="thread-1")
        events = controller.collect(request_id, timeout=15.0)
        assert events[-1]["type"] == "done"
        # Nothing beats after the terminal: the run is over, so the emitter is.
        before = len([e for e in events if e["type"] == "heartbeat"])
        extra = controller.collect(request_id, timeout=0.5)
        after = before + len([e for e in extra if e["type"] == "heartbeat"])
        assert after == before, f"a beat outlived the run: {extra}"
        assert threading.active_count() >= 1
        assert not [
            t for t in threading.enumerate() if t.name.startswith("heartbeat-")
        ], "the heartbeat thread outlived the run"
    finally:
        executor.stop()


def test_a_heartbeat_is_never_part_of_the_transcript(tmp_path):
    """Proof of life, not content: a replay must not carry one."""
    executor, controller = _rig(
        tmp_path, lambda: MockModelClient(["answer"]), heartbeat_seconds=0.02
    )
    executor.start()
    try:
        request_id = controller.send_task("hi", session_key="thread-1")
        assert controller.collect(request_id, timeout=15.0)[-1]["type"] == "done"
    finally:
        executor.stop()
    store = StateStore(str(tmp_path / "state.db"))
    try:
        events = list(store.replay_events(store.route("thread-1")))
    finally:
        store.close()
    assert not [e for e in events if str(e).find('"heartbeat"') >= 0]


def test_zero_disables_the_emitter(tmp_path):
    executor, _ = _rig(
        tmp_path, lambda: MockModelClient(["x"]), heartbeat_seconds=0
    )
    assert executor._arm_heartbeat(None) is None  # type: ignore[arg-type]


def test_the_default_comes_from_the_module_constant(tmp_path, monkeypatch):
    import chuk_agents_executor.executor as executor_module

    monkeypatch.setattr(executor_module, "HEARTBEAT_SECONDS", 42.0)
    executor, _ = _rig(tmp_path, lambda: MockModelClient(["x"]))
    assert executor._heartbeat_seconds == 42.0
    executor2, _ = _rig(tmp_path, lambda: MockModelClient(["x"]), heartbeat_seconds=5)
    assert executor2._heartbeat_seconds == 5.0
