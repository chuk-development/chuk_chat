"""The executor's reader thread is the only way in, so it must not be killable.

Found while diagnosing the 2026-09-13 lost message. ``Executor._serve`` ran
``decode_frames`` with no guard and is never restarted (``Executor.start``
spawns it once). One unparseable line on the loopback link therefore ended the
thread for good: from that moment every frame the user sent was ignored, in
perfect silence, for the whole life of the process — the same symptom as the
incident, with a different cause.

The fix is a guard per iteration plus a log line, and this pins it.
"""

from __future__ import annotations

import logging

import pytest
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_runtime import MockModelClient

from wiring import paired_channel


@pytest.fixture
def rig(tmp_path):
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="worker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["done"]),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        yield controller, executor, controller_ep
    finally:
        executor.stop()


def test_an_unparseable_line_does_not_deafen_the_executor(rig, caplog):
    """A line the decoder chokes on costs one log line, never the pipe."""
    controller, _, controller_ep = rig

    with caplog.at_level(logging.WARNING, logger="chuk_agents_executor.executor"):
        controller_ep.send(b"{not json at all\n")

        # The next ordinary task still runs, which is the whole point.
        request_id = controller.send_task("go", session_key="poisoned")
        events = controller.collect(request_id, timeout=20.0)

    assert events, "the reader thread died on a bad line"
    assert events[-1]["reason"] == "finished"


def test_a_rejected_frame_says_so(rig, caplog):
    """A frame that dies on the opener used to log nothing at any level.

    The rejection name is structure, not content, and it is the difference
    between a five-minute diagnosis and a blind one.
    """
    controller, executor, _ = rig
    channel = paired_channel()  # a stranger's keys: not this executor's

    with caplog.at_level(logging.WARNING, logger="chuk_agents_executor.executor"):
        stranger = ControllerSession(
            endpoint=controller._endpoint,
            sealer=channel.controller.sealer,
            opener=channel.controller.opener,
        )
        request_id = stranger.send_task("go", session_key="stranger")
        controller.collect(request_id, timeout=5.0)

    messages = [record.getMessage() for record in caplog.records]
    assert any(
        "frame rejected" in message for message in messages
    ), f"no rejection was logged: {messages}"
