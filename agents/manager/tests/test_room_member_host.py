"""Group members on another host (CHAT-177): ``room_members.host_id``."""

from __future__ import annotations

import sqlite3

import pytest

from chuk_agents_manager import RoomError, RoomStore


def test_a_member_keeps_its_host_and_null_is_this_host(tmp_path):
    store = RoomStore(str(tmp_path / "rooms.db"))
    store.create_room(name="Team", room_id="g1")
    store.add_member("g1", "local:ada", "ada")
    room = store.add_member("g1", "local:bob", "bob", host_id="0b6c2c7e-6f0a-4a43-9d8f-3c2b1a0e9f11")
    assert [m.host_id for m in room.members] == [None, "0b6c2c7e-6f0a-4a43-9d8f-3c2b1a0e9f11"]
    moved = store.set_member_host("g1", "local:bob", None)
    assert moved.member_by_id("local:bob").host_id is None
    with pytest.raises(RoomError):
        store.set_member_host("g1", "local:nobody", None)
    store.close()
    # The value is on disk.
    again = RoomStore(str(tmp_path / "rooms.db"))
    assert again.get("g1").member_by_id("local:ada").host_id is None


def test_an_older_file_gets_the_column_and_its_members_stay_local(tmp_path):
    path = tmp_path / "old.db"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE rooms (id TEXT PRIMARY KEY, name TEXT NOT NULL,
            max_members INTEGER, max_rounds INTEGER NOT NULL,
            max_messages INTEGER, created_at TEXT NOT NULL,
            agent_to_agent INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE room_members (room_id TEXT NOT NULL REFERENCES rooms(id)
            ON DELETE CASCADE, agent_id TEXT NOT NULL, handle TEXT NOT NULL,
            position INTEGER NOT NULL, PRIMARY KEY (room_id, agent_id),
            UNIQUE (room_id, handle));
        INSERT INTO rooms VALUES ('g1', 'Old', NULL, 3, NULL, '2026-01-01', 1);
        INSERT INTO room_members VALUES ('g1', 'local:ada', 'ada', 1);
        """
    )
    conn.commit()
    conn.close()
    store = RoomStore(str(path))
    room = store.get("g1")
    assert room.members[0].host_id is None
    room = store.add_member("g1", "local:bob", "bob", host_id="peer")
    assert room.member_by_id("local:bob").host_id == "peer"
