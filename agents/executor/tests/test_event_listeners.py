"""In-process event listeners, stop and approval answers (CHAT-184 gateways).

A gateway in the host observes the events of the runs it started with
``add_event_listener``, stops a thread with ``stop_session`` and answers an
approval with ``resolve_approval``. These run a real executor on the mock
model over the sealed loopback.
"""

from __future__ import annotations

import threading
import time

from chuk_agents_runtime import MockModelClient
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import Executor, loopback_pair

from wiring import paired_channel


def _start(tmp_path, model_factory):
    ws = tmp_path / "ws"
    ws.mkdir()
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="gw",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        workspace=str(ws),
    )
    executor.start()
    return executor, ws


def test_listener_sees_delta_and_done_with_run_id(tmp_path):
    executor, _ws = _start(tmp_path, lambda: MockModelClient(["hello from the agent"]))
    seen: list[dict] = []
    done = threading.Event()

    def listener(payload: dict) -> None:
        seen.append(payload)
        if payload.get("type") == "done":
            done.set()

    try:
        executor.add_event_listener(listener)
        executor.add_event_listener(listener)  # twice is once
        run_id = executor.submit_task("host:x#auto-telegram-1", "hi", {"origin": "telegram"})
        assert done.wait(20), seen
    finally:
        executor.stop()
    mine = [p for p in seen if p.get("run_id") == run_id]
    assert any(p["type"] == "delta" and "hello" in p["text"] for p in mine)
    dones = [p for p in mine if p["type"] == "done"]
    assert len(dones) == 1
    assert dones[0]["final_answer"] == "hello from the agent"
    assert dones[0]["session_key"] == "host:x#auto-telegram-1"


def test_removed_listener_sees_nothing(tmp_path):
    executor, _ws = _start(tmp_path, lambda: MockModelClient(["ok"]))
    seen: list[dict] = []
    try:
        executor.add_event_listener(seen.append)
        executor.remove_event_listener(seen.append)
        executor.submit_task("s1", "hi", {})
        deadline = time.monotonic() + 10
        while executor.has_live_run("s1") and time.monotonic() < deadline:
            time.sleep(0.05)
    finally:
        executor.stop()
    assert seen == []


def test_a_failing_listener_does_not_break_the_run(tmp_path):
    executor, _ws = _start(tmp_path, lambda: MockModelClient(["fine"]))
    done = threading.Event()

    def bad(_payload: dict) -> None:
        raise RuntimeError("boom")

    def good(payload: dict) -> None:
        if payload.get("type") == "done":
            done.set()

    try:
        executor.add_event_listener(bad)
        executor.add_event_listener(good)
        executor.submit_task("s1", "hi", {})
        assert done.wait(20)
    finally:
        executor.stop()


def test_stop_session_and_resolve_approval_without_a_run(tmp_path):
    executor, ws = _start(tmp_path, lambda: MockModelClient(["x"]))
    try:
        assert executor.stop_session("nothing-runs-here") == 0
        executor.resolve_approval("no-such-approval", True, "once")  # a no-op
        assert executor.workspace_for("s1") == str(ws)
    finally:
        executor.stop()
