"""RoomStore (§16.1/4a): durable rooms + members, the six-member cap at the DB."""

from __future__ import annotations

import pytest

from chuk_agents_manager import RoomCaps, RoomError, RoomStore


def test_create_and_get_round_trips():
    store = RoomStore()
    room = store.create_room(name="standup")
    assert room.name == "standup"
    assert room.members == ()
    same = store.get(room.room_id)
    assert same is not None
    assert same.room_id == room.room_id
    assert same.caps.max_members is None  # unlimited by default


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
    room = store.create_room(name="r", caps=RoomCaps(max_members=6))
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


# -- the agent-to-agent policy (cowork-zurf) -------------------------------


def test_a_room_allows_agent_to_agent_by_default():
    store = RoomStore()
    room = store.create_room(name="launch")
    assert room.agent_to_agent is True
    assert store.get(room.room_id).agent_to_agent is True


def test_the_policy_round_trips_when_it_is_off():
    store = RoomStore()
    room = store.create_room(name="launch", agent_to_agent=False)
    assert room.agent_to_agent is False
    assert store.get(room.room_id).agent_to_agent is False


def test_set_agent_to_agent_flips_the_policy():
    store = RoomStore()
    room = store.create_room(name="launch")
    off = store.set_agent_to_agent(room.room_id, False)
    assert off.agent_to_agent is False
    assert store.get(room.room_id).agent_to_agent is False
    on = store.set_agent_to_agent(room.room_id, True)
    assert on.agent_to_agent is True


def test_set_agent_to_agent_keeps_the_members():
    store = RoomStore()
    room = store.create_room(name="launch")
    store.add_member(room.room_id, "id-amber", "amber")
    store.add_member(room.room_id, "id-cobalt", "cobalt")
    flipped = store.set_agent_to_agent(room.room_id, False)
    assert flipped.handles == ("amber", "cobalt")


def test_set_agent_to_agent_on_an_unknown_room_raises():
    store = RoomStore()
    with pytest.raises(RoomError):
        store.set_agent_to_agent("nope", False)


def test_the_policy_persists_across_reopen(tmp_path):
    path = str(tmp_path / "rooms.db")
    store = RoomStore(path)
    room = store.create_room(name="launch", agent_to_agent=False)
    store.close()

    reopened = RoomStore(path)
    assert reopened.get(room.room_id).agent_to_agent is False
    reopened.close()


def test_a_database_from_the_old_schema_migrates_to_the_default(tmp_path):
    """A file written before the policy has no column; opening it adds one."""
    import sqlite3

    path = str(tmp_path / "old.db")
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE rooms (
            id            TEXT PRIMARY KEY,
            name          TEXT NOT NULL,
            max_members   INTEGER NOT NULL,
            max_rounds    INTEGER NOT NULL,
            max_messages  INTEGER NOT NULL,
            created_at    TEXT NOT NULL
        );
        CREATE TABLE room_members (
            room_id   TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            agent_id  TEXT NOT NULL,
            handle    TEXT NOT NULL,
            position  INTEGER NOT NULL,
            PRIMARY KEY (room_id, agent_id),
            UNIQUE (room_id, handle)
        );
        """
    )
    conn.execute(
        "INSERT INTO rooms "
        "(id, name, max_members, max_rounds, max_messages, created_at) "
        "VALUES ('old1', 'legacy', 6, 3, 10, '2026-01-01T00:00:00+00:00')"
    )
    conn.execute(
        "INSERT INTO room_members (room_id, agent_id, handle, position) "
        "VALUES ('old1', 'id-amber', 'amber', 1)"
    )
    conn.commit()
    conn.close()

    store = RoomStore(path)
    room = store.get("old1")
    assert room is not None
    assert room.agent_to_agent is True  # the old behaviour, kept
    assert room.handles == ("amber",)
    # And the migrated file takes the switch like any other.
    assert store.set_agent_to_agent("old1", False).agent_to_agent is False
    store.close()


# -- unlimited membership --------------------------------------------------


def test_an_unlimited_room_round_trips_as_none():
    store = RoomStore()
    room = store.create_room(name="all-hands")
    assert room.caps.max_members is None
    for i in range(25):
        store.add_member(room.room_id, f"a{i}", f"h{i}")
    reloaded = store.get(room.room_id)
    assert len(reloaded.members) == 25
    assert reloaded.caps.max_members is None
    assert reloaded.caps.max_messages_per_send is None


def test_a_stored_six_still_enforces_six():
    store = RoomStore()
    room = store.create_room(name="r", caps=RoomCaps(max_members=6))
    for i in range(6):
        store.add_member(room.room_id, f"a{i}", f"h{i}")
    with pytest.raises(RoomError):
        store.add_member(room.room_id, "a6", "h6")
    assert store.get(room.room_id).caps.max_members == 6


def test_an_old_row_keeps_its_numbers_through_the_migration(tmp_path):
    """The pre-unlimited schema had NOT NULL ceilings; the rebuild keeps them."""
    import sqlite3

    path = str(tmp_path / "capped.db")
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE rooms (
            id            TEXT PRIMARY KEY,
            name          TEXT NOT NULL,
            max_members   INTEGER NOT NULL,
            max_rounds    INTEGER NOT NULL,
            max_messages  INTEGER NOT NULL,
            created_at    TEXT NOT NULL
        );
        CREATE TABLE room_members (
            room_id   TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            agent_id  TEXT NOT NULL,
            handle    TEXT NOT NULL,
            position  INTEGER NOT NULL,
            PRIMARY KEY (room_id, agent_id),
            UNIQUE (room_id, handle)
        );
        """
    )
    conn.execute(
        "INSERT INTO rooms "
        "(id, name, max_members, max_rounds, max_messages, created_at) "
        "VALUES ('old2', 'legacy', 6, 3, 10, '2026-01-01T00:00:00+00:00')"
    )
    conn.execute(
        "INSERT INTO room_members (room_id, agent_id, handle, position) "
        "VALUES ('old2', 'id-amber', 'amber', 1)"
    )
    conn.commit()
    conn.close()

    store = RoomStore(path)
    room = store.get("old2")
    assert room.caps.max_members == 6  # not silently widened
    assert room.caps.max_messages_per_send == 10
    assert room.handles == ("amber",)
    # The rebuilt table still cascades and still takes new rooms with no cap.
    fresh = store.create_room(name="wide")
    assert fresh.caps.max_members is None
    store.add_member("old2", "id-cobalt", "cobalt")
    assert store.delete("old2") is True
    assert store._members_of("old2") == []
    store.close()
