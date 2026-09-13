"""Group rooms (§16.1): membership caps, @mention routing, round/message caps.

The orchestration is pure, so these drive it directly — no executor, no model.
A "run" is scripted: the test plays each speaker's output back through
``submit``.
"""

from __future__ import annotations

import pytest

from chuk_agents_manager import (
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


def test_a_room_takes_as_many_members_as_the_user_adds():
    room = _room([f"a{i}" for i in range(25)])
    assert len(room.members) == 25
    assert len(room.with_member(RoomMember(agent_id="id-x", handle="x")).members) == 26


def test_a_configured_member_cap_is_still_enforced():
    caps = RoomCaps(max_members=6)
    room = _room([f"a{i}" for i in range(6)], caps=caps)
    with pytest.raises(RoomError):
        room.with_member(RoomMember(agent_id="id-x", handle="x"))
    with pytest.raises(RoomError):
        _room([f"a{i}" for i in range(7)], caps=caps)


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
    room = _room(handles, caps=RoomCaps(max_messages_per_send=10))
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
    from chuk_agents_manager import has_broadcast_mention

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


# -- the agent-to-agent policy (cowork-zurf) -------------------------------


def _user_driven_room(handles, caps=None):
    """A room where a coworker's reply may not pull another coworker in."""
    members = tuple(RoomMember(agent_id=f"id-{h}", handle=h) for h in handles)
    return GroupRoom(
        room_id="r1",
        name="room",
        members=members,
        caps=caps or RoomCaps(),
        agent_to_agent=False,
    )


def test_the_policy_defaults_to_today_s_behaviour():
    assert _room(["amber"]).agent_to_agent is True


def test_the_policy_survives_add_and_remove_member():
    room = _user_driven_room(["amber"])
    grown = room.with_member(RoomMember(agent_id="id-cobalt", handle="cobalt"))
    assert grown.agent_to_agent is False
    assert grown.without_member("id-cobalt").agent_to_agent is False


def test_policy_off_drops_every_mention_an_agent_makes():
    room = _user_driven_room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "@amber kick it off")
    order = _run(session, {"amber": "@cobalt @jade @all thoughts? cc @cobalt"})
    assert order == [(1, "amber")]
    assert len(session.transcript) == 1
    assert session.stop_reason == "agent_to_agent_off"


def test_policy_off_ends_after_round_one_however_wide_it_was():
    room = _user_driven_room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "what does everyone think?")
    order = _run(
        session,
        {
            "amber": "ask @cobalt",
            "cobalt": "ask @jade",
            "jade": "@amber again",
        },
    )
    # Exactly one round: the transcript is as long as round one's speakers.
    assert order == [(1, "amber"), (1, "cobalt"), (1, "jade")]
    assert len(session.transcript) == 3
    assert session.stop_reason == "agent_to_agent_off"


def test_policy_off_without_any_mention_keeps_the_old_stop_reason():
    room = _user_driven_room(["amber", "cobalt"])
    session = RoomSession(room, "go")
    order = _run(session, {"amber": "nothing to add", "cobalt": "same"})
    assert order == [(1, "amber"), (1, "cobalt")]
    assert session.stop_reason == "no_more_mentions"


def test_policy_off_ignores_a_self_mention_for_the_stop_reason():
    # Naming yourself never seeded a round anyway, so nothing was suppressed.
    room = _user_driven_room(["amber", "cobalt"])
    session = RoomSession(room, "@amber go")
    _run(session, {"amber": "as @amber i say no"})
    assert session.stop_reason == "no_more_mentions"


def test_policy_off_keeps_the_user_s_own_round_one_mentions():
    room = _user_driven_room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "@jade then @amber please")
    order = _run(session, {})
    assert order == [(1, "jade"), (1, "amber")]


def test_policy_off_still_lets_the_user_address_the_whole_room():
    room = _user_driven_room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "@all please weigh in")
    order = _run(session, {})
    assert order == [(1, "amber"), (1, "cobalt"), (1, "jade")]


def test_policy_off_still_reports_an_exhausted_cap_first():
    room = _user_driven_room(["amber", "cobalt", "jade"])
    session = RoomSession(room, "everyone", caps=RoomCaps(max_messages_per_send=2))
    order = _run(session, {"amber": "@cobalt", "cobalt": "@jade"})
    assert order == [(1, "amber"), (1, "cobalt")]
    assert session.stop_reason == "messages_exhausted"


def test_policy_on_is_unchanged_by_the_switch():
    room = _room(["amber", "cobalt", "jade"])
    assert room.agent_to_agent is True
    session = RoomSession(room, "@amber kick it off")
    order = _run(
        session, {"amber": "over to @cobalt", "cobalt": "and @jade", "jade": "done"}
    )
    assert order == [(1, "amber"), (2, "cobalt"), (3, "jade")]
    assert session.stop_reason == "no_more_mentions"


def test_an_explicit_override_beats_the_room_s_policy():
    room = _room(["amber", "cobalt"])  # policy on
    session = RoomSession(room, "@amber go", agent_to_agent=False)
    order = _run(session, {"amber": "your turn @cobalt"})
    assert order == [(1, "amber")]
    assert session.stop_reason == "agent_to_agent_off"


# -- unlimited membership and the derived message ceiling ------------------


def test_a_wide_room_lets_every_member_speak_in_round_one():
    handles = [f"a{i}" for i in range(25)]
    room = _room(handles)
    session = RoomSession(room, "what does everyone think?")
    order = _run(session, {})
    assert [h for _, h in order] == handles  # nobody dropped
    assert len(session.transcript) == 25
    assert session.stop_reason == "no_more_mentions"


def test_the_derived_message_ceiling_is_members_times_rounds():
    room = _room([f"a{i}" for i in range(25)])
    session = RoomSession(room, "go")
    assert session.max_messages_per_send == 75


def test_an_explicit_message_ceiling_still_truncates_a_wide_room():
    handles = [f"a{i}" for i in range(25)]
    room = _room(handles, caps=RoomCaps(max_messages_per_send=10))
    session = RoomSession(room, "what does everyone think?")
    order = _run(session, {})
    assert len(order) == 10
    assert session.stop_reason == "messages_exhausted"


def test_the_round_cap_is_the_brake_in_a_wide_room():
    handles = [f"a{i}" for i in range(8)]
    room = _room(handles)
    # Every speaker re-engages the whole room, so each round refills to 8. The
    # round cap (3) stops it, not a message ceiling.
    session = RoomSession(room, "everyone go")
    order = _run(session, {h: "@all again" for h in handles})
    assert len(order) == 8 * 3
    assert session.stop_reason == "rounds_exhausted"


def test_an_unset_member_cap_is_the_default():
    assert RoomCaps().max_members is None
    assert RoomCaps().max_messages_per_send is None
    assert RoomCaps(max_members=6).max_members == 6
