"""Room transcript store — a room's conversation, kept (§16.1).

A group room is a persistent thread, not a throwaway exchange: reopen it and the
last conversation is still there, the way Bot Mode keeps a bot's canonical chat.
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

import sqlite3
from datetime import datetime, timezone

from cowork_manager.group_room import RoomTurn

_SCHEMA = """
CREATE TABLE IF NOT EXISTS room_transcript (
    room_id   TEXT NOT NULL,
    seq       INTEGER NOT NULL,
    round     INTEGER NOT NULL,
    agent_id  TEXT NOT NULL,
    handle    TEXT NOT NULL,
    text      TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (room_id, seq)
);
"""


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class RoomTranscriptStore:
    """Append-only per-room transcript, SQLite-backed.

    ``":memory:"`` for tests, a file path for the host's durable transcript.
    """

    def __init__(self, path: str = ":memory:") -> None:
        self._conn = sqlite3.connect(path)
        self._conn.row_factory = sqlite3.Row
        self._conn.executescript(_SCHEMA)
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
        row = self._conn.execute(
            "SELECT COALESCE(MAX(seq), 0) AS m FROM room_transcript WHERE room_id = ?",
            (room_id,),
        ).fetchone()
        seq = int(row["m"]) + 1
        self._conn.execute(
            "INSERT INTO room_transcript "
            "(room_id, seq, round, agent_id, handle, text, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (room_id, seq, turn.round, turn.agent_id, turn.handle, turn.text, _now_iso()),
        )
        self._conn.commit()
        return seq

    def history(self, room_id: str) -> list[RoomTurn]:
        """The room's turns, in the order they were spoken."""
        rows = self._conn.execute(
            "SELECT round, agent_id, handle, text FROM room_transcript "
            "WHERE room_id = ? ORDER BY seq",
            (room_id,),
        ).fetchall()
        return [
            RoomTurn(
                round=row["round"],
                agent_id=row["agent_id"],
                handle=row["handle"],
                text=row["text"],
            )
            for row in rows
        ]

    def clear(self, room_id: str) -> int:
        """Drop a room's history — the user starting it over. Returns how many
        turns were removed."""
        cur = self._conn.execute(
            "DELETE FROM room_transcript WHERE room_id = ?", (room_id,)
        )
        self._conn.commit()
        return cur.rowcount
