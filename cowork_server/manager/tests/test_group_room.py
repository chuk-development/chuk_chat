"""Group rooms (§16.1): membership caps, @mention routing, round/message caps.

The orchestration is pure, so these drive it directly — no executor, no model.
A "run" is scripted: the test plays each speaker's output back through
``submit``.
"""

from __future__ import annotations

import pytest

from cowork_manager import (
    GroupRoom,
    RoomCaps,
    RoomError,
    RoomMember,
    RoomSession,
    parse_mentions,
)


def _room(handles, caps=None):
    members = tuple(
        RoomMember(agent_id=f"id-{h}", handle=h) for h in handles
    )
    return GroupRoom(
        room_id="r1", name="room", members=members, caps=caps or RoomCaps()
    )


# -- membership caps -------------------------------------------------------


def test_a_room_holds_at_most_six_members():
    handles = [f"a{i}" for i in range(6)]
    room = _room(handles)
    assert len(room.members) == 6
    with pytest.raises(RoomError):
        room.with_member(RoomMember(agent_id="id-x", handle="x"))


def test_construction_over_the_cap_is_refused():
    with pytest.raises(RoomError):
        _room([f"a{i}" for i in range(7)])


def test_duplicate_handle_or_agent_is_refused():
    with pytest.raises(RoomError):
        GroupRoom(
            room_id="r",
            name="n",
            members=(
                RoomMember("id1", "amber"),
                RoomMember("id2", "amber"),
            ),
        )
    room = _room(["amber"])
    with pytest.raises(RoomError):
        room.with_member(RoomMember(agent_id="id-amber", handle="other"))


def test_with_and_without_member_are_immutable():
    room = _room(["amber"])
    bigger = room.with_member(RoomMember("id-cobalt", "cobalt"))
    assert room.handles == ("amber",)  # original untouched
    assert bigger.handles == ("amber", "cobalt")
    smaller = bigger.without_member("id-amber")
    assert smaller.handles == ("cobalt",)
    with pytest.raises(RoomError):
        room.without_member("id-nope")


# -- @mention parsing ------------------------------------------------------


def test_parse_mentions_only_matches_known_handles_in_order():
    known = {"amber-otter", "cobalt-lynx"}
    text = "hey @amber-otter and @cobalt-lynx, not @stranger or foo@bar.com"
    assert parse_mentions(text, known) == ["amber-otter", "cobalt-lynx"]


def test_parse_mentions_dedupes_and_ignores_empty():
    known = {"amber"}
    assert parse_mentions("@amber @amber @amber", known) == ["amber"]
    assert parse_mentions("", known) == []
    assert parse_mentions("no mentions here", known) == []


def test_cross_machine_handle_matches_only_when_it_is_a_member():
    # @name-device is a mention only when that exact handle is known.
    assert parse_mentions("@amber-laptop", {"amber-laptop"}) == ["amber-laptop"]
    assert parse_mentions("@amber-laptop", {"amber"}) == []


# -- round 1 seeding -------------------------------------------------------


def _run(session, scripts):
    """Drive a session to completion. ``scripts`` maps handle -> reply text (or a
    callable(handle)->text). Returns the ordered list of (round, handle)."""
    order = []
    while (member := session.next_speaker()) is not None:
        order.append((session.round, member.handle))
        reply = scripts.get(member.handle, "")
        session.submit(reply(member.handle) if callable(reply) else reply)
    return order


def test_no_mentions_everyone_speaks_once_in_room_order():
    room = _room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "what does everyone think?")
    order = _run(session, {})
    assert order == [(1, "amber"), (1, "cobalt"), (1, "jade")]
    assert session.stop_reason == "no_more_mentions"


def test_a_user_mention_limits_round_one_to_those_named_in_order():
    room = _room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "@jade then @amber please")
    order = _run(session, {})
    assert order == [(1, "jade"), (1, "amber")]


# -- rounds via mentions in outputs ---------------------------------------


def test_a_member_pulls_in_another_for_the_next_round():
    room = _room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "@amber kick it off")
    # amber names cobalt; cobalt names nobody -> two rounds, then stop.
    order = _run(session, {"amber": "good point @cobalt", "cobalt": "agreed"})
    assert order == [(1, "amber"), (2, "cobalt")]
    assert session.stop_reason == "no_more_mentions"


def test_a_member_never_retriggers_itself():
    room = _room(["amber", "cobalt"])
    session = RoomSession(room, "@amber go")
    order = _run(session, {"amber": "I still think @amber is right"})
    assert order == [(1, "amber")]
    assert session.stop_reason == "no_more_mentions"


def test_the_round_cap_stops_a_mention_chain_at_three():
    room = _room(["amber", "cobalt", "jade", "onyx"])
    session = RoomSession(room, "@amber start")
    # A chain: amber->cobalt->jade->onyx. The 4th round is refused.
    order = _run(
        session,
        {
            "amber": "over to @cobalt",
            "cobalt": "over to @jade",
            "jade": "over to @onyx",
            "onyx": "done",
        },
    )
    assert order == [(1, "amber"), (2, "cobalt"), (3, "jade")]
    assert session.stop_reason == "rounds_exhausted"


def test_the_message_cap_stops_a_wide_room():
    # 5 members, everyone re-mentions everyone -> the 10-message cap bites first.
    handles = ["a", "b", "c", "d", "e"]
    room = _room(handles)
    session = RoomSession(room, "everyone go")
    # Each speaker names all others, so every round would refill to 5. With
    # max_messages_per_send=10 the session stops after 10 agent messages.
    all_mentions = " ".join(f"@{h}" for h in handles)
    order = _run(session, {h: all_mentions for h in handles})
    assert len(order) == 10
    assert session.stop_reason == "messages_exhausted"


def test_caps_are_configurable():
    room = _room(["amber", "cobalt"], caps=RoomCaps(max_rounds=1))
    session = RoomSession(room, "@amber go")
    order = _run(session, {"amber": "over to @cobalt"})
    assert order == [(1, "amber")]
    assert session.stop_reason == "rounds_exhausted"


# -- API misuse guards -----------------------------------------------------


def test_next_speaker_without_submit_is_an_error():
    room = _room(["amber", "cobalt"])
    session = RoomSession(room, "everyone")
    session.next_speaker()
    with pytest.raises(RoomError):
        session.next_speaker()  # did not submit the first speaker's output


def test_submit_without_a_speaker_is_an_error():
    room = _room(["amber"])
    session = RoomSession(room, "go")
    with pytest.raises(RoomError):
        session.submit("nobody asked me")


def test_an_empty_room_stops_immediately():
    room = GroupRoom(room_id="r", name="n", members=())
    session = RoomSession(room, "hello?")
    assert session.next_speaker() is None
    assert session.stop_reason == "no_members"


def test_transcript_records_round_speaker_and_text():
    room = _room(["amber", "cobalt"])
    session = RoomSession(room, "@amber go")
    _run(session, {"amber": "hi @cobalt", "cobalt": "hello"})
    turns = session.transcript
    assert [(t.round, t.handle, t.text) for t in turns] == [
        (1, "amber", "hi @cobalt"),
        (2, "cobalt", "hello"),
    ]
    assert session.messages_sent == 2


def test_bad_caps_are_refused():
    with pytest.raises(ValueError):
        RoomCaps(max_members=0)
    with pytest.raises(ValueError):
        RoomCaps(max_rounds=0)


# -- @all / broadcast mentions (§16.1) ------------------------------------


def test_has_broadcast_mention_detects_the_keywords():
    from cowork_manager import has_broadcast_mention

    assert has_broadcast_mention("hey @all thoughts?")
    assert has_broadcast_mention("@everyone")
    assert has_broadcast_mention("what does the @room think")
    assert has_broadcast_mention("@ALL uppercase too")
    assert not has_broadcast_mention("@amber only")
    assert not has_broadcast_mention("no mention")
    assert not has_broadcast_mention("")


def test_user_at_all_seeds_everyone_in_round_one():
    room = _room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "@all please weigh in")
    order = _run(session, {})
    assert order == [(1, "amber"), (1, "cobalt"), (1, "jade")]


def test_a_reply_at_all_re_engages_the_whole_room_next_round():
    room = _room(["amber", "cobalt", "jade"])
    # amber addresses only jade in round 1... no: amber broadcasts.
    session = RoomSession(room, "@amber kick off")
    order = _run(
        session,
        {"amber": "let's hear from @all", "cobalt": "ok", "jade": "ok"},
    )
    # Round 1: amber. Round 2: everyone except amber, in room order.
    assert order == [(1, "amber"), (2, "cobalt"), (2, "jade")]
    assert session.stop_reason == "no_more_mentions"


def test_at_all_never_re_triggers_the_speaker():
    room = _room(["amber", "cobalt"])
    session = RoomSession(room, "@amber go")
    order = _run(session, {"amber": "@all what do you think", "cobalt": "done"})
    assert order == [(1, "amber"), (2, "cobalt")]  # amber not requeued


def test_at_all_still_obeys_the_round_cap():
    room = _room(["amber", "cobalt"])
    session = RoomSession(
        room, "@amber go", caps=RoomCaps(max_rounds=1)
    )
    order = _run(session, {"amber": "@all thoughts?"})
    assert order == [(1, "amber")]
    assert session.stop_reason == "rounds_exhausted"
