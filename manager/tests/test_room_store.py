"""RoomStore (§16.1/4a): durable rooms + members, the six-member cap at the DB."""

from __future__ import annotations

import pytest

from cowork_manager import RoomCaps, RoomError, RoomStore


def test_create_and_get_round_trips():
    store = RoomStore()
    room = store.create_room(name="standup")
    assert room.name == "standup"
    assert room.members == ()
    same = store.get(room.room_id)
    assert same is not None
    assert same.room_id == room.room_id
    assert same.caps.max_members == 6


def test_add_members_keeps_room_order():
    store = RoomStore()
    room = store.create_room(name="r")
    store.add_member(room.room_id, "a1", "amber")
    store.add_member(room.room_id, "a2", "cobalt")
    room = store.add_member(room.room_id, "a3", "jade")
    assert room.handles == ("amber", "cobalt", "jade")
    # Order survives a reload.
    assert store.get(room.room_id).handles == ("amber", "cobalt", "jade")


def test_the_six_member_cap_is_enforced_at_the_store():
    store = RoomStore()
    room = store.create_room(name="r")
    for i in range(6):
        store.add_member(room.room_id, f"a{i}", f"h{i}")
    with pytest.raises(RoomError):
        store.add_member(room.room_id, "a6", "h6")
    assert len(store.get(room.room_id).members) == 6


def test_a_configurable_cap_is_persisted():
    store = RoomStore()
    room = store.create_room(name="r", caps=RoomCaps(max_members=2, max_rounds=1))
    store.add_member(room.room_id, "a1", "amber")
    store.add_member(room.room_id, "a2", "cobalt")
    with pytest.raises(RoomError):
        store.add_member(room.room_id, "a3", "jade")
    reloaded = store.get(room.room_id)
    assert reloaded.caps.max_members == 2
    assert reloaded.caps.max_rounds == 1


def test_duplicate_agent_or_handle_is_refused():
    store = RoomStore()
    room = store.create_room(name="r")
    store.add_member(room.room_id, "a1", "amber")
    with pytest.raises(RoomError):
        store.add_member(room.room_id, "a1", "other")  # same agent
    with pytest.raises(RoomError):
        store.add_member(room.room_id, "a2", "amber")  # same handle


def test_remove_member():
    store = RoomStore()
    room = store.create_room(name="r")
    store.add_member(room.room_id, "a1", "amber")
    store.add_member(room.room_id, "a2", "cobalt")
    room = store.remove_member(room.room_id, "a1")
    assert room.handles == ("cobalt",)
    with pytest.raises(RoomError):
        store.remove_member(room.room_id, "a1")  # already gone


def test_delete_room_cascades_to_members():
    store = RoomStore()
    room = store.create_room(name="r")
    store.add_member(room.room_id, "a1", "amber")
    assert store.delete(room.room_id) is True
    assert store.get(room.room_id) is None
    # The members went with it (no orphan rows), so a re-created id is clean.
    assert store.delete(room.room_id) is False


def test_add_to_missing_room_raises():
    store = RoomStore()
    with pytest.raises(RoomError):
        store.add_member("nope", "a1", "amber")


def test_list_is_creation_ordered():
    store = RoomStore()
    a = store.create_room(name="first")
    b = store.create_room(name="second")
    ids = [r.room_id for r in store.list()]
    assert ids == [a.room_id, b.room_id]


def test_persists_across_reopen(tmp_path):
    path = str(tmp_path / "rooms.db")
    store = RoomStore(path)
    room = store.create_room(name="keep")
    store.add_member(room.room_id, "a1", "amber")
    store.close()

    reopened = RoomStore(path)
    got = reopened.get(room.room_id)
    assert got is not None
    assert got.name == "keep"
    assert got.handles == ("amber",)
    reopened.close()


def test_create_room_with_an_explicit_id():
    store = RoomStore()
    room = store.create_room(name="x", room_id="room:abc")
    assert room.room_id == "room:abc"
    assert store.get("room:abc") is not None


def test_create_room_with_a_clashing_id_is_refused():
    store = RoomStore()
    store.create_room(name="x", room_id="room:abc")
    with pytest.raises(RoomError):
        store.create_room(name="y", room_id="room:abc")


def test_rename_room():
    store = RoomStore()
    room = store.create_room(name="old")
    renamed = store.rename_room(room.room_id, "new")
    assert renamed.name == "new"
    assert store.get(room.room_id).name == "new"


def test_rename_unknown_room_raises():
    store = RoomStore()
    with pytest.raises(RoomError):
        store.rename_room("ghost", "x")
