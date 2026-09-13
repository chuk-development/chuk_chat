"""Room store — the group rooms the Manager owns (§16.1, §5).

A room groups a handful of coworkers into one turn-based conversation. The
orchestration and the caps live in :mod:`chuk_agents_manager.group_room`; this module
is only their durable home: a `rooms` table and a `room_members` table, CRUD, and
rehydration into the immutable :class:`~chuk_agents_manager.group_room.GroupRoom` the
orchestrator drives.

A room is unlimited in size by default (``max_members`` is ``NULL``). A room
that *does* carry a ceiling has it enforced **at the database edge** — a count
under the room's own ``max_members`` before every insert — and again by
``GroupRoom`` on rehydration, so a hand-edited database that smuggled in one
member too many surfaces as an error on read rather than as an over-full room in
a running exchange. Each
member's ``position`` fixes the "everyone speaks in room order" sequence, so the
order the user built the room in is the order it plays back.
"""

from __future__ import annotations

import sqlite3
import uuid
from datetime import datetime, timezone

from chuk_agents_manager.group_room import GroupRoom, RoomCaps, RoomError, RoomMember

_SCHEMA = """
CREATE TABLE IF NOT EXISTS rooms (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    -- NULL means "no ceiling": a room takes as many members as the user adds,
    -- and an unset message ceiling is derived per exchange from the room size.
    max_members   INTEGER,
    max_rounds    INTEGER NOT NULL,
    max_messages  INTEGER,
    created_at    TEXT NOT NULL,
    agent_to_agent INTEGER NOT NULL DEFAULT 1
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
        self._migrate()
        self._conn.commit()

    def _migrate(self) -> None:
        """Bring a database file made by an older schema up to date.

        ``CREATE TABLE IF NOT EXISTS`` leaves an existing table exactly as it
        was, so a store written before the agent-to-agent policy has no such
        column. Add it with the permissive default, which is also the policy
        default: an old room keeps behaving the way it always did.
        """
        info = self._conn.execute("PRAGMA table_info(rooms)").fetchall()
        columns = {row["name"]: row for row in info}
        if "agent_to_agent" not in columns:
            self._conn.execute(
                "ALTER TABLE rooms "
                "ADD COLUMN agent_to_agent INTEGER NOT NULL DEFAULT 1"
            )
        # The member and message ceilings became optional (NULL = no ceiling).
        # SQLite cannot relax NOT NULL in place, so an older file is rebuilt.
        # The values themselves are copied over: a room made under the old
        # six-member cap keeps that six, it is not silently widened.
        if any(
            columns[name]["notnull"]
            for name in ("max_members", "max_messages")
            if name in columns
        ):
            self._relax_cap_columns()

    def _relax_cap_columns(self) -> None:
        self._conn.commit()  # a PRAGMA cannot change inside a transaction
        self._conn.execute("PRAGMA foreign_keys = OFF")
        self._conn.execute(
            """
            CREATE TABLE rooms_rebuilt (
                id            TEXT PRIMARY KEY,
                name          TEXT NOT NULL,
                max_members   INTEGER,
                max_rounds    INTEGER NOT NULL,
                max_messages  INTEGER,
                created_at    TEXT NOT NULL,
                agent_to_agent INTEGER NOT NULL DEFAULT 1
            )
            """
        )
        self._conn.execute(
            "INSERT INTO rooms_rebuilt "
            "(id, name, max_members, max_rounds, max_messages, created_at, "
            "agent_to_agent) "
            "SELECT id, name, max_members, max_rounds, max_messages, created_at, "
            "agent_to_agent FROM rooms"
        )
        self._conn.execute("DROP TABLE rooms")
        self._conn.execute("ALTER TABLE rooms_rebuilt RENAME TO rooms")
        self._conn.commit()
        self._conn.execute("PRAGMA foreign_keys = ON")

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "RoomStore":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- CRUD ------------------------------------------------------------

    def create_room(
        self,
        *,
        name: str,
        caps: RoomCaps | None = None,
        room_id: str | None = None,
        agent_to_agent: bool = True,
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
            "(id, name, max_members, max_rounds, max_messages, created_at, "
            "agent_to_agent) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                room_id,
                name,
                caps.max_members,
                caps.max_rounds,
                caps.max_messages_per_send,
                _now_iso(),
                1 if agent_to_agent else 0,
            ),
        )
        self._conn.commit()
        return GroupRoom(
            room_id=room_id,
            name=name,
            members=(),
            caps=caps,
            agent_to_agent=agent_to_agent,
        )

    def add_member(self, room_id: str, agent_id: str, handle: str) -> GroupRoom:
        """Add one coworker to the room, or raise :class:`RoomError`.

        The cap — when the room has one; ``NULL``/``None`` means unlimited — is
        checked here against the room's own ``max_members`` before the insert;
        the ``UNIQUE``/``PRIMARY KEY`` constraints are the final authority
        against a duplicate handle or a repeated agent.
        """
        caps = self._caps_of(room_id)  # also asserts the room exists
        members = self._members_of(room_id)
        if caps.max_members is not None and len(members) >= caps.max_members:
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
            agent_to_agent=bool(row["agent_to_agent"]),
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

    def set_agent_to_agent(self, room_id: str, enabled: bool) -> GroupRoom:
        """Switch the room's agent-to-agent policy, returning the room.

        ``False`` makes the room user-driven: agents answer, they never summon
        one another. A no-such-room is a :class:`RoomError`, not a silent no-op,
        because the caller asked to change a room it believes exists."""
        cur = self._conn.execute(
            "UPDATE rooms SET agent_to_agent = ? WHERE id = ?",
            (1 if enabled else 0, room_id),
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
