"""RoomDriver (§16.1/4b): per-member routing, offline handling, streaming."""

from __future__ import annotations

from cowork_manager import (
    OFFLINE_REPLY,
    GroupRoom,
    RoomCaps,
    RoomDriver,
    RoomMember,
)


def _room(handles, caps=None):
    members = tuple(RoomMember(agent_id=f"id-{h}", handle=h) for h in handles)
    return GroupRoom(room_id="r", name="n", members=members, caps=caps or RoomCaps())


def test_each_turn_is_routed_to_its_own_member_with_the_rendered_prompt():
    room = _room(["amber", "cobalt"])
    routed = []

    def member_runner(member, prompt):
        routed.append((member.agent_id, member.handle))
        # The prompt is the rendered room context, addressed to this member.
        assert f"Reply as @{member.handle}." in prompt
        return f"{member.handle} replies"

    outcome = RoomDriver(member_runner).run(room, "everyone weigh in")
    assert routed == [("id-amber", "amber"), ("id-cobalt", "cobalt")]
    assert [t.text for t in outcome.transcript] == ["amber replies", "cobalt replies"]
    assert outcome.stop_reason == "no_more_mentions"


def test_an_offline_member_gets_a_placeholder_and_the_room_continues():
    room = _room(["amber", "cobalt"])

    def member_runner(member, prompt):
        return None if member.handle == "amber" else "here"

    outcome = RoomDriver(member_runner).run(room, "everyone")
    texts = {t.handle: t.text for t in outcome.transcript}
    assert texts["amber"] == OFFLINE_REPLY
    assert texts["cobalt"] == "here"
    # Both members still spoke once; the offline one did not sink the room.
    assert outcome.messages_sent == 2


def test_an_offline_members_placeholder_pulls_no_one_into_a_new_round():
    # Even if the offline placeholder contained an @handle by coincidence, it is
    # a fixed string with none — so an offline member cannot trigger a round.
    room = _room(["amber", "cobalt", "jade"])

    def member_runner(member, prompt):
        return None  # everyone offline

    outcome = RoomDriver(member_runner).run(room, "@amber start")
    assert [t.handle for t in outcome.transcript] == ["amber"]
    assert outcome.stop_reason == "no_more_mentions"


def test_a_reply_mention_still_drives_the_next_round_through_the_driver():
    room = _room(["amber", "cobalt"])

    def member_runner(member, prompt):
        return "over to @cobalt" if member.handle == "amber" else "done"

    outcome = RoomDriver(member_runner).run(room, "@amber go")
    assert [t.handle for t in outcome.transcript] == ["amber", "cobalt"]
    assert outcome.rounds == 2


def test_on_turn_streams_live_through_the_driver():
    room = _room(["amber", "cobalt"])
    streamed = []
    RoomDriver(lambda m, p: f"{m.handle} hi").run(
        room, "everyone", on_turn=lambda t: streamed.append((t.round, t.handle))
    )
    assert streamed == [(1, "amber"), (1, "cobalt")]


def test_the_stop_seam_reaches_the_driver():
    room = _room(["amber", "cobalt", "jade"])
    calls = {"n": 0}

    def member_runner(member, prompt):
        calls["n"] += 1
        return "hi"

    outcome = RoomDriver(member_runner).run(
        room, "everyone", stop=lambda: calls["n"] >= 1
    )
    assert calls["n"] == 1
    assert outcome.stop_reason == "stopped"


def test_caps_override_reaches_the_driver():
    room = _room(["amber", "cobalt"])

    def member_runner(member, prompt):
        return "over to @cobalt" if member.handle == "amber" else "done"

    outcome = RoomDriver(member_runner, caps=RoomCaps(max_rounds=1)).run(
        room, "@amber go"
    )
    assert [t.handle for t in outcome.transcript] == ["amber"]
    assert outcome.stop_reason == "rounds_exhausted"
