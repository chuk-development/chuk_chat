"""Room transcript store — a room's conversation, kept (§16.1).

A group room is a persistent thread, not a throwaway exchange: reopen it and the
whole conversation (the user's messages too, ``kind = 'user'``) is still there, the way Bot Mode keeps a bot's canonical chat.
This is where the turns live. The host appends each turn as it happens; a
reconnecting app asks for the history and rebuilds the thread.

One append-only table, ordered by a per-room sequence so the turns replay in the
exact order they were spoken — round numbers repeat across a room's exchanges, so
they cannot order the table on their own. ``clear`` drops a room's history (the
user starting the room over), and deleting a room takes its transcript with it
via the caller — this store does not know about rooms, only their ids, so it
stays independent of :class:`RoomStore`.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone

from chuk_agents_manager.group_room import TURN_AGENT, RoomTurn

#: The newest entries a room keeps. Older ones are dropped on append, so a long
#: lived group never grows without bound.
MAX_ENTRIES_PER_ROOM = 200

_SCHEMA = """
CREATE TABLE IF NOT EXISTS room_transcript (
    room_id   TEXT NOT NULL,
    seq       INTEGER NOT NULL,
    round     INTEGER NOT NULL,
    agent_id  TEXT NOT NULL,
    handle    TEXT NOT NULL,
    text      TEXT NOT NULL,
    created_at TEXT NOT NULL,
    kind      TEXT NOT NULL DEFAULT 'agent',
    meta      TEXT,
    PRIMARY KEY (room_id, seq)
);
"""


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class RoomTranscriptStore:
    """Append-only per-room transcript, SQLite-backed.

    ``":memory:"`` for tests, a file path for the host's durable transcript.
    Safe to share between threads: a group runs on its own thread while the
    frame thread answers a history request, so every call holds one lock.
    """

    def __init__(self, path: str = ":memory:", *, max_entries: int = MAX_ENTRIES_PER_ROOM) -> None:
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        self._max_entries = max_entries
        self._conn.executescript(_SCHEMA)
        columns = {
            row["name"]
            for row in self._conn.execute("PRAGMA table_info(room_transcript)").fetchall()
        }
        # A file made before entry kinds: every old row is an agent reply.
        if "kind" not in columns:
            self._conn.execute(
                "ALTER TABLE room_transcript ADD COLUMN kind TEXT NOT NULL DEFAULT 'agent'"
            )
        if "meta" not in columns:
            self._conn.execute("ALTER TABLE room_transcript ADD COLUMN meta TEXT")
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "RoomTranscriptStore":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def append(self, room_id: str, turn: RoomTurn) -> int:
        """Record one turn, returning its sequence number. The sequence is
        assigned here (max + 1 for the room), so a caller never has to track it
        and two rooms never share a counter."""
        meta: dict = {}
        if turn.routed_by:
            meta["routed_by"] = turn.routed_by
        if turn.to_agent_id is not None:
            meta["to_agent_id"] = turn.to_agent_id
        if turn.to_handle is not None:
            meta["to_handle"] = turn.to_handle
        with self._lock:
            row = self._conn.execute(
                "SELECT COALESCE(MAX(seq), 0) AS m FROM room_transcript WHERE room_id = ?",
                (room_id,),
            ).fetchone()
            seq = int(row["m"]) + 1
            self._conn.execute(
                "INSERT INTO room_transcript "
                "(room_id, seq, round, agent_id, handle, text, created_at, kind, meta) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    room_id,
                    seq,
                    turn.round,
                    turn.agent_id,
                    turn.handle,
                    turn.text,
                    _now_iso(),
                    turn.kind,
                    json.dumps(meta) if meta else None,
                ),
            )
            self._conn.execute(
                "DELETE FROM room_transcript WHERE room_id = ? AND seq <= ?",
                (room_id, seq - self._max_entries),
            )
            self._conn.commit()
            return seq

    def history(self, room_id: str) -> list[RoomTurn]:
        """The room's entries, in the order they were spoken."""
        with self._lock:
            rows = self._conn.execute(
                "SELECT round, agent_id, handle, text, kind, meta FROM room_transcript "
                "WHERE room_id = ? ORDER BY seq",
                (room_id,),
            ).fetchall()
        turns: list[RoomTurn] = []
        for row in rows:
            try:
                meta = json.loads(row["meta"]) if row["meta"] else {}
            except (json.JSONDecodeError, TypeError):
                meta = {}
            if not isinstance(meta, dict):
                meta = {}
            routed_by = meta.get("routed_by")
            turns.append(
                RoomTurn(
                    round=row["round"],
                    agent_id=row["agent_id"],
                    handle=row["handle"],
                    text=row["text"],
                    kind=row["kind"] or TURN_AGENT,
                    routed_by=routed_by if isinstance(routed_by, dict) else None,
                    to_agent_id=meta.get("to_agent_id"),
                    to_handle=meta.get("to_handle"),
                )
            )
        return turns

    def clear(self, room_id: str) -> int:
        """Drop a room's history — the user starting it over. Returns how many
        turns were removed."""
        with self._lock:
            cur = self._conn.execute(
                "DELETE FROM room_transcript WHERE room_id = ?", (room_id,)
            )
            self._conn.commit()
            return cur.rowcount
