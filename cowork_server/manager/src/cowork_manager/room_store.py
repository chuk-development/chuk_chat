"""Room store — the group rooms the Manager owns (§16.1, §5).

A room groups a handful of coworkers into one turn-based conversation. The
orchestration and the caps live in :mod:`cowork_manager.group_room`; this module
is only their durable home: a `rooms` table and a `room_members` table, CRUD, and
rehydration into the immutable :class:`~cowork_manager.group_room.GroupRoom` the
orchestrator drives.

The six-member cap is enforced **at the database edge** — a count under the
room's own ``max_members`` before every insert — and again by ``GroupRoom`` on
rehydration, so a hand-edited database that smuggled in a seventh member surfaces
as an error on read rather than an over-full room in a running exchange. Each
member's ``position`` fixes the "everyone speaks in room order" sequence, so the
order the user built the room in is the order it plays back.
"""

from __future__ import annotations

import sqlite3
import uuid
from datetime import datetime, timezone

from cowork_manager.group_room import GroupRoom, RoomCaps, RoomError, RoomMember

_SCHEMA = """
CREATE TABLE IF NOT EXISTS rooms (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    max_members   INTEGER NOT NULL,
    max_rounds    INTEGER NOT NULL,
    max_messages  INTEGER NOT NULL,
    created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS room_members (
    room_id   TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    agent_id  TEXT NOT NULL,
    handle    TEXT NOT NULL,
    position  INTEGER NOT NULL,
    PRIMARY KEY (room_id, agent_id),
    UNIQUE (room_id, handle)
);
"""


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class RoomStore:
    """SQLite-backed group-room registry.

    Pass ``":memory:"`` for an ephemeral store (tests) or a file path for the
    Manager's persistent rooms. Foreign keys are on, so deleting a room drops its
    members with it.
    """

    def __init__(self, path: str = ":memory:") -> None:
        self._conn = sqlite3.connect(path)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.executescript(_SCHEMA)
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "RoomStore":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- CRUD ------------------------------------------------------------

    def create_room(
        self, *, name: str, caps: RoomCaps | None = None, room_id: str | None = None
    ) -> GroupRoom:
        """Insert an empty room and return it.

        ``room_id`` lets the caller supply the id — the app owns room identity, so
        the host stores the room under the same id the app created it with. A
        clashing id is a :class:`RoomError`, not a silent overwrite."""
        caps = caps or RoomCaps()
        if room_id is None:
            room_id = uuid.uuid4().hex
        elif self.get(room_id) is not None:
            raise RoomError(f"room already exists: {room_id}")
        self._conn.execute(
            "INSERT INTO rooms "
            "(id, name, max_members, max_rounds, max_messages, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                room_id,
                name,
                caps.max_members,
                caps.max_rounds,
                caps.max_messages_per_send,
                _now_iso(),
            ),
        )
        self._conn.commit()
        return GroupRoom(room_id=room_id, name=name, members=(), caps=caps)

    def add_member(self, room_id: str, agent_id: str, handle: str) -> GroupRoom:
        """Add one coworker to the room, or raise :class:`RoomError`.

        The cap is checked here against the room's own ``max_members`` before the
        insert; the ``UNIQUE``/``PRIMARY KEY`` constraints are the final
        authority against a duplicate handle or a repeated agent.
        """
        caps = self._caps_of(room_id)  # also asserts the room exists
        members = self._members_of(room_id)
        if len(members) >= caps.max_members:
            raise RoomError(f"the room is full ({caps.max_members} members)")
        position = 1 + (max((m["position"] for m in members), default=0))
        try:
            self._conn.execute(
                "INSERT INTO room_members (room_id, agent_id, handle, position) "
                "VALUES (?, ?, ?, ?)",
                (room_id, agent_id, handle, position),
            )
        except sqlite3.IntegrityError as exc:
            raise RoomError(
                f"agent {agent_id!r} or handle {handle!r} already in the room"
            ) from exc
        self._conn.commit()
        return self.get(room_id)  # type: ignore[return-value]

    def remove_member(self, room_id: str, agent_id: str) -> GroupRoom:
        cur = self._conn.execute(
            "DELETE FROM room_members WHERE room_id = ? AND agent_id = ?",
            (room_id, agent_id),
        )
        self._conn.commit()
        if cur.rowcount == 0:
            raise RoomError(f"not a member of {room_id}: {agent_id}")
        return self.get(room_id)  # type: ignore[return-value]

    def get(self, room_id: str) -> GroupRoom | None:
        row = self._conn.execute(
            "SELECT * FROM rooms WHERE id = ?", (room_id,)
        ).fetchone()
        if row is None:
            return None
        members = tuple(
            RoomMember(agent_id=m["agent_id"], handle=m["handle"])
            for m in self._members_of(room_id)
        )
        # GroupRoom re-checks the cap and uniqueness on construction, so a
        # corrupted table surfaces as a RoomError here rather than downstream.
        return GroupRoom(
            room_id=row["id"],
            name=row["name"],
            members=members,
            caps=self._caps_from_row(row),
        )

    def list(self) -> list[GroupRoom]:
        rows = self._conn.execute(
            "SELECT id FROM rooms ORDER BY created_at, id"
        ).fetchall()
        return [self.get(row["id"]) for row in rows]  # type: ignore[misc]

    def rename_room(self, room_id: str, name: str) -> GroupRoom:
        """Rename a room, returning it. A no-such-room is a :class:`RoomError`."""
        cur = self._conn.execute(
            "UPDATE rooms SET name = ? WHERE id = ?", (name, room_id)
        )
        self._conn.commit()
        if cur.rowcount == 0:
            raise RoomError(f"no such room: {room_id}")
        return self.get(room_id)  # type: ignore[return-value]

    def delete(self, room_id: str) -> bool:
        cur = self._conn.execute("DELETE FROM rooms WHERE id = ?", (room_id,))
        self._conn.commit()
        return cur.rowcount > 0

    # -- helpers ---------------------------------------------------------

    def _members_of(self, room_id: str) -> list[sqlite3.Row]:
        return self._conn.execute(
            "SELECT agent_id, handle, position FROM room_members "
            "WHERE room_id = ? ORDER BY position",
            (room_id,),
        ).fetchall()

    def _caps_of(self, room_id: str) -> RoomCaps:
        row = self._conn.execute(
            "SELECT max_members, max_rounds, max_messages FROM rooms WHERE id = ?",
            (room_id,),
        ).fetchone()
        if row is None:
            raise RoomError(f"no such room: {room_id}")
        return self._caps_from_row(row)

    @staticmethod
    def _caps_from_row(row: sqlite3.Row) -> RoomCaps:
        return RoomCaps(
            max_members=row["max_members"],
            max_rounds=row["max_rounds"],
            max_messages_per_send=row["max_messages"],
        )
