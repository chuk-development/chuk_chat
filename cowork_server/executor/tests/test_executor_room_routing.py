"""The executor routes room_* frames to on_room_frame, not the agent loop (§16.1)."""

from __future__ import annotations

import threading
import time

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor.protocol import room_create_payload
from cowork_agent import MockModelClient

from wiring import paired_channel


def _run_executor(tmp_path, on_room_frame=None):
    from cowork_sandbox import LocalEnvironment

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    ex = Executor(
        name="member",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["done"]),
        on_room_frame=on_room_frame,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return ex, controller


def test_a_room_frame_reaches_on_room_frame_decoded(tmp_path):
    got = []
    event = threading.Event()

    def on_room_frame(payload):
        got.append(payload)
        event.set()

    ex, controller = _run_executor(tmp_path, on_room_frame=on_room_frame)
    ex.start()
    try:
        controller.send_payload(
            room_create_payload(
                room_id="r1",
                name="launch",
                members=[{"agent_id": "a", "handle": "amber"}],
            )
        )
        assert event.wait(timeout=5.0), "on_room_frame was not called"
    finally:
        ex.stop()

    assert got[0]["type"] == "room_create"
    assert got[0]["room_id"] == "r1"
    assert got[0]["name"] == "launch"


def test_a_room_frame_without_a_handler_is_rejected_not_run(tmp_path):
    ex, controller = _run_executor(tmp_path, on_room_frame=None)
    ex.start()
    try:
        rid = controller.send_payload(room_create_payload(room_id="r1", name="x", members=[]))
        events = controller.collect(rid, timeout=5.0)
    finally:
        ex.stop()
    # It errors ("rooms not enabled"), it does not try to run it as a task.
    assert events[-1]["type"] == "error"
    assert "not enabled" in events[-1]["message"]


def test_a_normal_task_still_runs_with_a_room_handler_present(tmp_path):
    # The room branch must not disturb ordinary task dispatch.
    ex, controller = _run_executor(tmp_path, on_room_frame=lambda p: None)
    ex.start()
    try:
        rid = controller.send_task("hello", session_key="t1")
        events = controller.collect(rid, timeout=10.0)
    finally:
        ex.stop()
    assert events[-1]["type"] == "done"
    assert events[-1]["final_answer"] == "done"
