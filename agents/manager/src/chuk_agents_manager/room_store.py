"""Room store — the group rooms the Manager owns (§16.1, §5).

A room groups a handful of agents into one turn-based conversation. The
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

import functools
import sqlite3
import threading
import uuid
from datetime import datetime, timezone

from chuk_agents_manager.group_room import (
    DEFAULT_RESPONDER,
    MAX_BULLETIN_CHARS,
    GroupRoom,
    RoomCaps,
    RoomError,
    RoomMember,
    clean_responder,
)

#: The group settings columns added after the first schema, with their DDL.
_SETTINGS_COLUMNS = {
    "responder": f"TEXT NOT NULL DEFAULT '{DEFAULT_RESPONDER}'",
    "lead_agent_id": "TEXT",
    "fallback_agent_id": "TEXT",
    "bulletin": "TEXT NOT NULL DEFAULT ''",
    "workdir": "TEXT NOT NULL DEFAULT ''",
}

#: The longest shared folder path a group keeps.
MAX_WORKDIR_CHARS = 1_000

#: Marks "leave this setting as it is" in :meth:`RoomStore.set_settings`.
UNCHANGED = object()


def _locked(method):
    """Run a store method under the store's lock: a group runs on its own
    thread while the frame thread edits rooms, and one SQLite connection must
    not be used by two threads at once."""

    @functools.wraps(method)
    def wrapper(self, *args, **kwargs):
        with self._lock:
            return method(self, *args, **kwargs)

    return wrapper

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
    agent_to_agent INTEGER NOT NULL DEFAULT 1,
    responder     TEXT NOT NULL DEFAULT 'everyone',
    lead_agent_id TEXT,
    fallback_agent_id TEXT,
    bulletin      TEXT NOT NULL DEFAULT '',
    workdir       TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS room_members (
    room_id   TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    agent_id  TEXT NOT NULL,
    handle    TEXT NOT NULL,
    position  INTEGER NOT NULL,
    -- The computer the member lives on (relay device id, CHAT-177). NULL is
    -- this host.
    host_id   TEXT,
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
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(path, check_same_thread=False)
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
        # Group settings (who answers, the lead, instructions, the folder).
        present = {
            row["name"]
            for row in self._conn.execute("PRAGMA table_info(rooms)").fetchall()
        }
        for name, ddl in _SETTINGS_COLUMNS.items():
            if name not in present:
                self._conn.execute(f"ALTER TABLE rooms ADD COLUMN {name} {ddl}")
        # Members on another host (CHAT-177): a nullable host id. NULL is
        # this host, so every member of an older file stays local.
        member_columns = {
            row["name"]
            for row in self._conn.execute("PRAGMA table_info(room_members)").fetchall()
        }
        if "host_id" not in member_columns:
            self._conn.execute("ALTER TABLE room_members ADD COLUMN host_id TEXT")

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

    @_locked
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

    @_locked
    def add_member(
        self, room_id: str, agent_id: str, handle: str, host_id: str | None = None
    ) -> GroupRoom:
        """Add one agent to the room, or raise :class:`RoomError`.

        ``host_id`` is the peer host the agent lives on; ``None`` (or empty)
        is this host.

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
                "INSERT INTO room_members (room_id, agent_id, handle, position, host_id) "
                "VALUES (?, ?, ?, ?, ?)",
                (room_id, agent_id, handle, position, host_id or None),
            )
        except sqlite3.IntegrityError as exc:
            raise RoomError(
                f"agent {agent_id!r} or handle {handle!r} already in the room"
            ) from exc
        self._conn.commit()
        return self.get(room_id)  # type: ignore[return-value]

    @_locked
    def set_member_host(
        self, room_id: str, agent_id: str, host_id: str | None
    ) -> GroupRoom:
        """Move a member to another host (or back to this one with ``None``).
        A non-member is a :class:`RoomError`."""
        cur = self._conn.execute(
            "UPDATE room_members SET host_id = ? WHERE room_id = ? AND agent_id = ?",
            (host_id or None, room_id, agent_id),
        )
        self._conn.commit()
        if cur.rowcount == 0:
            raise RoomError(f"not a member of {room_id}: {agent_id}")
        return self.get(room_id)  # type: ignore[return-value]

    @_locked
    def remove_member(self, room_id: str, agent_id: str) -> GroupRoom:
        cur = self._conn.execute(
            "DELETE FROM room_members WHERE room_id = ? AND agent_id = ?",
            (room_id, agent_id),
        )
        self._conn.commit()
        if cur.rowcount == 0:
            raise RoomError(f"not a member of {room_id}: {agent_id}")
        return self.get(room_id)  # type: ignore[return-value]

    @_locked
    def get(self, room_id: str) -> GroupRoom | None:
        row = self._conn.execute(
            "SELECT * FROM rooms WHERE id = ?", (room_id,)
        ).fetchone()
        if row is None:
            return None
        members = tuple(
            RoomMember(
                agent_id=m["agent_id"], handle=m["handle"], host_id=m["host_id"] or None
            )
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
            responder=clean_responder(row["responder"]) or DEFAULT_RESPONDER,
            lead_agent_id=row["lead_agent_id"],
            fallback_agent_id=row["fallback_agent_id"],
            bulletin=row["bulletin"] or "",
            workdir=row["workdir"] or "",
        )

    @_locked
    def set_settings(
        self,
        room_id: str,
        *,
        responder=UNCHANGED,
        lead_agent_id=UNCHANGED,
        fallback_agent_id=UNCHANGED,
        bulletin=UNCHANGED,
        workdir=UNCHANGED,
    ) -> GroupRoom:
        """Change the group settings that are given; the others stay. A bad
        value is a :class:`RoomError` and changes nothing: an unknown responder
        mode, or instructions over :data:`MAX_BULLETIN_CHARS`. An empty lead or
        fallback id means "the first member"."""
        updates: dict[str, object] = {}
        if responder is not UNCHANGED:
            mode = clean_responder(responder)
            if mode is None:
                raise RoomError(f"unknown responder mode: {responder!r}")
            updates["responder"] = mode
        for key, value in (("lead_agent_id", lead_agent_id), ("fallback_agent_id", fallback_agent_id)):
            if value is UNCHANGED:
                continue
            if value is not None and not isinstance(value, str):
                raise RoomError(f"{key} must be text")
            updates[key] = value or None
        if bulletin is not UNCHANGED:
            if not isinstance(bulletin, str):
                raise RoomError("bulletin must be text")
            if len(bulletin) > MAX_BULLETIN_CHARS:
                raise RoomError(f"bulletin is over {MAX_BULLETIN_CHARS} characters")
            updates["bulletin"] = bulletin
        if workdir is not UNCHANGED:
            if not isinstance(workdir, str) or len(workdir) > MAX_WORKDIR_CHARS:
                raise RoomError("workdir must be a short path")
            updates["workdir"] = workdir.strip()
        if self.get(room_id) is None:
            raise RoomError(f"no such room: {room_id}")
        if updates:
            assignments = ", ".join(f"{key} = ?" for key in updates)
            self._conn.execute(
                f"UPDATE rooms SET {assignments} WHERE id = ?",
                (*updates.values(), room_id),
            )
            self._conn.commit()
        return self.get(room_id)  # type: ignore[return-value]

    @_locked
    def list(self) -> list[GroupRoom]:
        rows = self._conn.execute(
            "SELECT id FROM rooms ORDER BY created_at, id"
        ).fetchall()
        return [self.get(row["id"]) for row in rows]  # type: ignore[misc]

    @_locked
    def rename_room(self, room_id: str, name: str) -> GroupRoom:
        """Rename a room, returning it. A no-such-room is a :class:`RoomError`."""
        cur = self._conn.execute(
            "UPDATE rooms SET name = ? WHERE id = ?", (name, room_id)
        )
        self._conn.commit()
        if cur.rowcount == 0:
            raise RoomError(f"no such room: {room_id}")
        return self.get(room_id)  # type: ignore[return-value]

    @_locked
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

    @_locked
    def delete(self, room_id: str) -> bool:
        cur = self._conn.execute("DELETE FROM rooms WHERE id = ?", (room_id,))
        self._conn.commit()
        return cur.rowcount > 0

    # -- helpers ---------------------------------------------------------

    def _members_of(self, room_id: str) -> list[sqlite3.Row]:
        return self._conn.execute(
            "SELECT agent_id, handle, position, host_id FROM room_members "
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
