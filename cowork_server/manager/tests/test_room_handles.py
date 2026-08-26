"""assign_room_handles (§16.1): cross-machine @name-device disambiguation."""

from __future__ import annotations

from cowork_manager import AgentIdentity, GroupRoom, assign_room_handles


def _id(agent_id, name, device="laptop"):
    return AgentIdentity(agent_id=agent_id, name=name, device=device)


def test_unique_names_keep_their_plain_handle():
    members = assign_room_handles([_id("1", "amber"), _id("2", "cobalt")])
    assert [m.handle for m in members] == ["amber", "cobalt"]
    assert [m.agent_id for m in members] == ["1", "2"]


def test_a_shared_name_disambiguates_by_device():
    members = assign_room_handles([
        _id("1", "amber", "laptop"),
        _id("2", "amber", "server"),
        _id("3", "cobalt", "laptop"),
    ])
    assert [m.handle for m in members] == ["amber-laptop", "amber-server", "cobalt"]


def test_order_is_preserved():
    members = assign_room_handles([_id("3", "jade"), _id("1", "amber")])
    assert [m.agent_id for m in members] == ["3", "1"]


def test_names_are_slugged_to_mentionable_handles():
    members = assign_room_handles([_id("1", "Amber Otter!"), _id("2", "cobalt")])
    # Slugged: lowercased, non-handle chars to '-', trimmed.
    assert members[0].handle == "amber-otter"


def test_same_name_same_device_still_gets_a_unique_handle():
    # A same-account squat: two coworkers, same name AND device. name-device
    # would collide, so a numeric suffix breaks the tie rather than producing a
    # room GroupRoom would reject.
    members = assign_room_handles([
        _id("1", "amber", "laptop"),
        _id("2", "amber", "laptop"),
    ])
    handles = [m.handle for m in members]
    assert len(set(handles)) == 2
    assert handles[0] == "amber-laptop"
    assert handles[1] == "amber-laptop-2"


def test_the_result_builds_a_valid_room():
    # The whole point: the handles are unique, so a room accepts them.
    members = assign_room_handles([
        _id("1", "amber", "laptop"),
        _id("2", "amber", "server"),
    ])
    room = GroupRoom(room_id="r", name="n", members=tuple(members))
    assert room.handles == ("amber-laptop", "amber-server")


def test_an_empty_name_falls_back_to_a_handle():
    members = assign_room_handles([_id("1", "   "), _id("2", "cobalt")])
    assert members[0].handle == "agent"
