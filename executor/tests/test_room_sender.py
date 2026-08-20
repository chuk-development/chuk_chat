"""make_room_task_sender (§16.1/4b): a member's turn over the loopback relay,
and the whole path RoomBinding -> RoomDriver -> encrypted executor turn."""

from __future__ import annotations

import pytest
from cowork_manager import GroupRoom, RoomBinding, RoomDriver, RoomMember

from cowork_executor import (
    ControllerSession,
    Executor,
    loopback_pair,
    make_room_task_sender,
)
from cowork_agent import MockModelClient

from wiring import paired_channel


def _executor(tmp_path, endpoint, channel, model_factory):
    from cowork_sandbox import LocalEnvironment

    return Executor(
        name="member",
        endpoint=endpoint,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        system_prompt="You are a coworker in a room.",
    )


def _controller(endpoint, channel):
    return ControllerSession(
        endpoint=endpoint,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )


def test_the_sender_returns_the_final_answer(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    # A model that just answers, no tool call.
    executor = _executor(
        tmp_path, executor_ep, channel, lambda: MockModelClient(["ship it"])
    )
    controller = _controller(controller_ep, channel)

    executor.start()
    try:
        send = make_room_task_sender(
            controller, session_key="room:r1", timeout=15.0
        )
        reply = send("You are @amber. Reply.")
        assert reply == "ship it"
    finally:
        executor.stop()


def test_an_empty_answer_is_none(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    # A bare-text turn with empty text -> done with no usable answer.
    executor = _executor(
        tmp_path, executor_ep, channel, lambda: MockModelClient([""])
    )
    controller = _controller(controller_ep, channel)

    executor.start()
    try:
        send = make_room_task_sender(controller, session_key="room:r1")
        assert send("hello?") is None
    finally:
        executor.stop()


def test_a_whole_room_runs_over_encrypted_executors(tmp_path):
    """RoomBinding -> RoomDriver -> two real executors, each answering its turn
    over the sealed loopback link. Proves the manager's seam and the executor's
    sender meet end to end."""
    binding = RoomBinding()
    executors = []
    controllers = []

    for handle in ["amber", "cobalt"]:
        channel = paired_channel()
        c_ep, e_ep = loopback_pair()
        (tmp_path / handle).mkdir(exist_ok=True)
        ex = _executor(
            (tmp_path / handle),
            e_ep,
            channel,
            (lambda h: (lambda: MockModelClient([f"{h} weighs in"])))(handle),
        )
        ex.start()
        executors.append(ex)
        ctrl = _controller(c_ep, channel)
        controllers.append(ctrl)
        binding.register(
            f"id-{handle}",
            make_room_task_sender(ctrl, session_key="room:r1", timeout=15.0),
        )

    room = GroupRoom(
        room_id="r1",
        name="launch",
        members=(
            RoomMember(agent_id="id-amber", handle="amber"),
            RoomMember(agent_id="id-cobalt", handle="cobalt"),
        ),
    )

    try:
        outcome = RoomDriver(binding.member_runner()).run(room, "everyone weigh in")
        texts = {t.handle: t.text for t in outcome.transcript}
        assert texts["amber"] == "amber weighs in"
        assert texts["cobalt"] == "cobalt weighs in"
        assert outcome.stop_reason == "no_more_mentions"
    finally:
        for ex in executors:
            ex.stop()
