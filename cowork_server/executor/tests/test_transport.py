"""Task 3: the loopback transport carries relay frames both ways."""

from __future__ import annotations

from cowork_manager import Transport, decode_frames, encode_frame, make_request

from cowork_executor import LoopbackEndpoint, loopback_pair


def test_endpoints_are_transports():
    controller, executor = loopback_pair()
    assert isinstance(controller, Transport)
    assert isinstance(executor, Transport)


def test_bytes_flow_both_directions():
    controller, executor = loopback_pair()

    controller.send(encode_frame(make_request("ping", {"n": 1}, "r1")))
    got = executor.recv(timeout=1.0)
    frames, remainder = decode_frames(got)
    assert remainder == b""
    assert frames[0]["method"] == "ping"
    assert frames[0]["requestId"] == "r1"

    executor.send(encode_frame(make_request("pong", {}, "r2")))
    back, _ = decode_frames(controller.recv(timeout=1.0))
    assert back[0]["method"] == "pong"


def test_recv_times_out_to_none():
    controller, _ = loopback_pair()
    assert controller.recv(timeout=0.05) is None


def test_isinstance_endpoint():
    controller, _ = loopback_pair()
    assert isinstance(controller, LoopbackEndpoint)


def test_done_payload_carries_token_spend():
    """The done frame reports the run's token spend so the app can show a cost
    (§7.6). Default 0 for a run that reported no usage; the field is always
    present so an old client's `?? 0` is never needed on a fresh host."""
    from cowork_executor.protocol import done_payload

    p = done_payload(
        final_answer="ok", reason="finished", iterations=2, tokens_spent=1234
    )
    assert p["type"] == "done"
    assert p["tokens_spent"] == 1234

    default = done_payload(final_answer=None, reason="finished", iterations=1)
    assert default["tokens_spent"] == 0


def test_room_turn_and_done_payloads():
    """The room-relay frame contract (§16.1/4b): a member's turn and the end of
    the exchange, so the app can render a room live and name why it stopped."""
    from cowork_executor.protocol import room_done_payload, room_turn_payload

    turn = room_turn_payload(
        room_id="r1", round=2, agent_id="id-amber", handle="amber", text="hi"
    )
    assert turn == {
        "type": "room_turn",
        "room_id": "r1",
        "round": 2,
        "agent_id": "id-amber",
        "handle": "amber",
        "text": "hi",
    }

    done = room_done_payload(
        room_id="r1", reason="rounds_exhausted", messages_sent=3, rounds=3
    )
    assert done == {
        "type": "room_done",
        "room_id": "r1",
        "reason": "rounds_exhausted",
        "messages_sent": 3,
        "rounds": 3,
    }


def test_room_task_payload():
    """The app -> host frame that starts a room (§16.1)."""
    from cowork_executor.protocol import room_task_payload

    p = room_task_payload(room_id="r1", message="what's the plan?")
    assert p == {"type": "room_task", "room_id": "r1", "message": "what's the plan?"}


def test_room_history_payloads():
    from cowork_executor.protocol import (
        room_history_payload,
        room_history_request_payload,
    )

    req = room_history_request_payload(room_id="r1")
    assert req == {"type": "room_history_request", "room_id": "r1"}

    turns = [{"round": 1, "agent_id": "a", "handle": "amber", "text": "hi"}]
    hist = room_history_payload(room_id="r1", turns=turns)
    assert hist == {"type": "room_history", "room_id": "r1", "turns": turns}


def test_room_create_payload():
    from cowork_executor.protocol import room_create_payload

    p = room_create_payload(
        room_id="r1",
        name="launch",
        members=[{"agent_id": "a", "handle": "amber"}],
    )
    assert p == {
        "type": "room_create",
        "room_id": "r1",
        "name": "launch",
        "members": [{"agent_id": "a", "handle": "amber"}],
    }


def test_room_delete_payload():
    from cowork_executor.protocol import room_delete_payload

    assert room_delete_payload(room_id="r1") == {"type": "room_delete", "room_id": "r1"}


def test_room_rename_payload():
    from cowork_executor.protocol import room_rename_payload

    assert room_rename_payload(room_id="r1", name="launch v2") == {
        "type": "room_rename",
        "room_id": "r1",
        "name": "launch v2",
    }


def test_room_member_payloads():
    from cowork_executor.protocol import (
        room_add_member_payload,
        room_remove_member_payload,
    )

    assert room_add_member_payload(room_id="r1", agent_id="a", handle="amber") == {
        "type": "room_add_member",
        "room_id": "r1",
        "agent_id": "a",
        "handle": "amber",
    }
    assert room_remove_member_payload(room_id="r1", agent_id="a") == {
        "type": "room_remove_member",
        "room_id": "r1",
        "agent_id": "a",
    }
