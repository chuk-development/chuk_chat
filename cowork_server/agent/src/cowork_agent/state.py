"""State persistence (§7.5).

Single SQLite file, append-only ``messages`` rows. A killed process loses at
most the last uncommitted turn.

Hard rules from the plan:
- Resume by ``WHERE session_id=? ORDER BY id`` — the autoincrement id, NEVER a
  wall-clock timestamp. Mobile clocks jump on sleep/NTP and would reorder a
  tool-call/response pair.
- A ``session_key -> session_id`` routing table, so an app relaunch finds the
  right run with no server state.
- ``BEGIN IMMEDIATE`` + jittered retry on "database is locked".
- JSON in columns, never pickle.
- An **FTS5 mirror kept in sync by triggers** (§12 B), so full-text recall never
  needs a second store or a model call. See :mod:`cowork_agent.search`.
"""

from __future__ import annotations

import json
import random
import sqlite3
import threading
import time
from dataclasses import dataclass
from typing import Any

from .search import ensure_fts_schema, register_functions, search_messages

_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    session_id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at REAL NOT NULL,
    meta TEXT NOT NULL DEFAULT '{}'
);

-- session_key -> session_id routing. A relaunch resolves the key to the run
-- with no server-side state.
CREATE TABLE IF NOT EXISTS session_routes (
    session_key TEXT PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES sessions(session_id)
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES sessions(session_id),
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, id);

-- Subagent handles (§7.6). One row per child, the whole handle as JSON: the app
-- lists subagents from here, and a relaunch reconstructs every handle with no
-- in-process state. Keyed by the parent's session key so one store can hold the
-- children of many runs.
CREATE TABLE IF NOT EXISTS subagents (
    subagent_id TEXT PRIMARY KEY,
    parent_key TEXT NOT NULL,
    data TEXT NOT NULL,
    updated_at REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_subagents_parent ON subagents(parent_key);
"""


@dataclass
class Message:
    id: int
    session_id: int
    role: str
    content: dict
    created_at: float


class StateStore:
    """Append-only SQLite state.

    Each thread gets its own connection (SQLite connections are not safe to share
    across threads, and one shared connection cannot hold concurrent
    transactions). Connections open in autocommit mode (``isolation_level=None``)
    so this store — not the sqlite3 driver — controls ``BEGIN IMMEDIATE``.
    """

    def __init__(self, path: str, *, max_retries: int = 12) -> None:
        self._path = path
        self._max_retries = max_retries
        self._local = threading.local()
        # Create the schema once up front on the constructing thread.
        self._has_fts = self._init_schema(self._conn())

    def _conn(self) -> sqlite3.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(
                self._path, isolation_level=None, timeout=5.0
            )
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL;")
            conn.execute("PRAGMA foreign_keys=ON;")
            conn.execute("PRAGMA busy_timeout=5000;")
            # The FTS sync trigger calls cowork_cjk_segment, so every connection
            # that inserts a message must carry the function.
            register_functions(conn)
            self._local.conn = conn
        return conn

    @property
    def has_fts(self) -> bool:
        """False on a SQLite build without FTS5 — the store still works, only
        :meth:`search_messages` is unavailable."""
        return self._has_fts

    @staticmethod
    def _init_schema(conn: sqlite3.Connection) -> bool:
        conn.executescript(_SCHEMA)
        return ensure_fts_schema(conn)

    def close(self) -> None:
        conn = getattr(self._local, "conn", None)
        if conn is not None:
            conn.close()
            self._local.conn = None

    # -- write helper -----------------------------------------------------

    def _write(self, fn):
        """Run ``fn(cursor)`` inside a ``BEGIN IMMEDIATE`` transaction, with a
        jittered retry on a locked database."""
        conn = self._conn()
        delay = 0.02
        last: sqlite3.OperationalError | None = None
        for _ in range(self._max_retries):
            try:
                conn.execute("BEGIN IMMEDIATE;")
            except sqlite3.OperationalError as exc:
                if "locked" not in str(exc).lower() and "busy" not in str(exc).lower():
                    raise
                last = exc
                time.sleep(delay + random.uniform(0, delay))
                delay = min(delay * 2, 1.0)
                continue
            try:
                cur = conn.cursor()
                result = fn(cur)
                conn.execute("COMMIT;")
                return result
            except sqlite3.OperationalError as exc:
                conn.execute("ROLLBACK;")
                if "locked" not in str(exc).lower() and "busy" not in str(exc).lower():
                    raise
                last = exc
                time.sleep(delay + random.uniform(0, delay))
                delay = min(delay * 2, 1.0)
            except Exception:
                conn.execute("ROLLBACK;")
                raise
        raise last if last else sqlite3.OperationalError("write failed")

    # -- sessions & routing ----------------------------------------------

    def create_session(self, meta: dict | None = None) -> int:
        def op(cur: sqlite3.Cursor) -> int:
            cur.execute(
                "INSERT INTO sessions(created_at, meta) VALUES (?, ?)",
                (time.time(), json.dumps(meta or {})),
            )
            return int(cur.lastrowid)

        return self._write(op)

    def resolve_session(self, session_key: str) -> int | None:
        row = self._conn().execute(
            "SELECT session_id FROM session_routes WHERE session_key=?",
            (session_key,),
        ).fetchone()
        return int(row["session_id"]) if row else None

    def route(self, session_key: str, meta: dict | None = None) -> int:
        """Resolve ``session_key`` to its ``session_id``, creating the session
        and the route on first use. This is the relaunch entry point."""
        existing = self.resolve_session(session_key)
        if existing is not None:
            return existing

        def op(cur: sqlite3.Cursor) -> int:
            cur.execute(
                "INSERT INTO sessions(created_at, meta) VALUES (?, ?)",
                (time.time(), json.dumps(meta or {})),
            )
            session_id = int(cur.lastrowid)
            cur.execute(
                "INSERT INTO session_routes(session_key, session_id) VALUES (?, ?)",
                (session_key, session_id),
            )
            return session_id

        return self._write(op)

    # -- messages ---------------------------------------------------------

    def append_message(self, session_id: int, role: str, content: dict) -> int:
        def op(cur: sqlite3.Cursor) -> int:
            cur.execute(
                "INSERT INTO messages(session_id, role, content, created_at) "
                "VALUES (?, ?, ?, ?)",
                (session_id, role, json.dumps(content), time.time()),
            )
            return int(cur.lastrowid)

        return self._write(op)

    def get_conversation(self, session_id: int) -> list[Message]:
        """All messages for a session, ordered by autoincrement id — never by a
        timestamp."""
        rows = self._conn().execute(
            "SELECT id, session_id, role, content, created_at "
            "FROM messages WHERE session_id=? ORDER BY id",
            (session_id,),
        ).fetchall()
        return [
            Message(
                id=int(r["id"]),
                session_id=int(r["session_id"]),
                role=r["role"],
                content=json.loads(r["content"]),
                created_at=float(r["created_at"]),
            )
            for r in rows
        ]

    # -- subagent handles (§7.6) ------------------------------------------

    def save_subagent(self, subagent_id: str, parent_key: str, data: dict) -> None:
        """Insert or update one subagent handle. The caller owns the shape of
        ``data``; this store only keeps it addressable and durable."""

        def op(cur: sqlite3.Cursor) -> None:
            cur.execute(
                "INSERT INTO subagents(subagent_id, parent_key, data, updated_at) "
                "VALUES (?, ?, ?, ?) ON CONFLICT(subagent_id) DO UPDATE SET "
                "parent_key=excluded.parent_key, data=excluded.data, "
                "updated_at=excluded.updated_at",
                (subagent_id, parent_key, json.dumps(data), time.time()),
            )

        self._write(op)

    def load_subagent(self, subagent_id: str) -> dict | None:
        row = self._conn().execute(
            "SELECT data FROM subagents WHERE subagent_id=?", (subagent_id,)
        ).fetchone()
        if row is None:
            return None
        try:
            data = json.loads(row["data"])
        except ValueError:
            return None
        return data if isinstance(data, dict) else None

    def list_subagents(
        self, *, parent_key: str | None = None, limit: int = 200
    ) -> list[dict]:
        """Oldest first, by rowid — insertion order, never a wall clock."""
        sql = "SELECT data FROM subagents"
        params: list[Any] = []
        if parent_key is not None:
            sql += " WHERE parent_key=?"
            params.append(parent_key)
        sql += " ORDER BY rowid LIMIT ?"
        params.append(max(1, int(limit)))
        rows = self._conn().execute(sql, tuple(params)).fetchall()
        out: list[dict] = []
        for row in rows:
            try:
                data = json.loads(row["data"])
            except ValueError:
                continue
            if isinstance(data, dict):
                out.append(data)
        return out

    # -- full-text search (§12 B) -----------------------------------------

    def search_messages(
        self,
        query: str,
        *,
        limit: int = 5,
        window: int = 5,
        session_id: int | None = None,
    ) -> dict:
        """Keyword search over every stored message. No model call: BM25 over
        the FTS5 mirror, returning anchored windows (see
        :func:`cowork_agent.search.search_messages`)."""
        if not self._has_fts:
            return {"ok": False, "error": "this SQLite build has no FTS5", "hits": []}
        return search_messages(
            self._conn(),
            query,
            limit=limit,
            window=window,
            session_id=session_id,
        )
