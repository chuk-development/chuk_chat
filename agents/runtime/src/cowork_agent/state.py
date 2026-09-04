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

-- One row per accepted task (see docs/WIRE_CONTRACT.md). A run belongs to the
-- host process, not to a socket: it is recorded here when accepted, closed here
-- when it ends, and replayed from here to a client that was away. Kept in the
-- same file as the messages so one file stays the truth.
CREATE TABLE IF NOT EXISTS runs (
    run_id       TEXT PRIMARY KEY,
    session_id   INTEGER NOT NULL REFERENCES sessions(session_id),
    session_key  TEXT NOT NULL,
    prompt       TEXT NOT NULL,
    state        TEXT NOT NULL,
    reason       TEXT,
    final_answer TEXT,
    iterations   INTEGER NOT NULL DEFAULT 0,
    tokens_spent INTEGER NOT NULL DEFAULT 0,
    first_mid    INTEGER,
    last_mid     INTEGER,
    started_at   REAL NOT NULL,
    finished_at  REAL,
    notified_at  REAL,
    seen_at      REAL
);

CREATE INDEX IF NOT EXISTS idx_runs_session ON runs(session_key, started_at);
"""

#: Run states (the ``runs.state`` column).
RUN_RUNNING = "running"
RUN_FINISHED = "finished"
RUN_FAILED = "failed"


@dataclass
class Message:
    id: int
    session_id: int
    role: str
    content: dict
    created_at: float


def _as_text(content: Any) -> str:
    """Coerce a stored message ``content`` to text. A string passes through; a
    dict tool result is compact JSON; ``None`` is empty."""
    if isinstance(content, str):
        return content
    if content is None:
        return ""
    return json.dumps(content, separators=(",", ":"))


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

    def replay_events(self, session_id: int, *, after_id: int = 0) -> list[dict]:
        """Rebuild the stored transcript as stream events, in the SAME shapes the
        executor streams live (see ``cowork_executor.protocol``). Every event
        carries ``"replay": True`` so a client tells a replayed turn from a live
        one.

        The server is the source of truth. A fresh or reinstalled client
        reconnects, asks for this list, and rebuilds the whole thread from it. The
        order is the stored order — by autoincrement id, never a clock.

        One stored row maps to one event, or to none:

        - a ``system`` row is dropped. The system prompt is not part of the
          thread the user reads.
        - a ``user`` row becomes a ``user`` event. The live stream has no such
          event, because the live client wrote that turn itself; a reconnecting
          client did not, so replay must carry both sides of the thread.
        - an ``assistant`` row with text becomes a ``delta`` event — the shape a
          live assistant text chunk uses.
        - an ``assistant`` row with tool calls becomes one ``tool`` event per
          call — the shape a live tool event uses. The matching tool-result row
          fills ``stdout``, so the verbose view shows what the tool returned.
        - a ``tool`` row is folded into its call's event by ``tool_call_id``. It
          is not emitted on its own.
        """
        conversation = self.get_conversation(session_id)
        # First pass: index each tool result by the call id it answers, so an
        # assistant tool call can carry its own output in one event.
        results: dict[str, str] = {}
        for message in conversation:
            content = message.content
            if content.get("role") == "tool":
                call_id = str(content.get("tool_call_id", ""))
                results[call_id] = _as_text(content.get("content"))
        events: list[dict] = []
        for message in conversation:
            # The replay cursor (docs/WIRE_CONTRACT.md): a client that already
            # holds the thread up to ``after_id`` gets only what came later.
            if message.id <= after_id:
                continue
            content = message.content
            role = content.get("role")
            if role in ("system", "tool"):
                continue
            # ``mid`` is the row id, so the client can persist a cursor.
            mid = message.id
            if role == "user":
                events.append(
                    {
                        "type": "user",
                        "text": _as_text(content.get("content")),
                        "replay": True,
                        "mid": mid,
                    }
                )
                continue
            # assistant
            text = content.get("content")
            if isinstance(text, str) and text.strip():
                events.append({"type": "delta", "text": text, "replay": True, "mid": mid})
            for call in content.get("tool_calls") or []:
                if not isinstance(call, dict):
                    continue
                fn = call.get("function", {}) or {}
                args = fn.get("arguments", {})
                command = (
                    args if isinstance(args, str)
                    else json.dumps(args, separators=(",", ":"))
                )
                events.append(
                    {
                        "type": "tool",
                        "name": str(fn.get("name", "")),
                        "command": command,
                        "exit_code": 0,
                        "stdout": results.get(str(call.get("id", "")), ""),
                        "stderr": "",
                        "timed_out": False,
                        "replay": True,
                        "mid": mid,
                    }
                )
        return events

    # -- runs (docs/WIRE_CONTRACT.md) ------------------------------------

    def max_message_id(self, session_id: int) -> int:
        """The highest message row id in a session, or 0 for an empty one. Used
        as a run's first/last message cursor."""
        row = self._conn().execute(
            "SELECT COALESCE(MAX(id), 0) AS m FROM messages WHERE session_id=?",
            (session_id,),
        ).fetchone()
        return int(row["m"]) if row else 0

    def begin_run(
        self, run_id: str, session_id: int, session_key: str, prompt: str
    ) -> None:
        """Record an accepted task as ``running``. ``first_mid`` is the message
        cursor at that moment, so the run's own turns are the rows after it."""
        first_mid = self.max_message_id(session_id)

        def op(cur: sqlite3.Cursor) -> None:
            cur.execute(
                "INSERT INTO runs(run_id, session_id, session_key, prompt, state, "
                "first_mid, started_at) VALUES (?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(run_id) DO NOTHING",
                (run_id, session_id, session_key, prompt, RUN_RUNNING, first_mid, time.time()),
            )

        self._write(op)

    def finish_run(
        self,
        run_id: str,
        *,
        reason: str,
        final_answer: str | None,
        iterations: int,
        tokens_spent: int,
    ) -> None:
        """Close a run as ``finished``. ``last_mid`` is the message cursor at the
        end, so a replay can place the run's terminal after its last turn."""

        def op(cur: sqlite3.Cursor) -> None:
            row = cur.execute(
                "SELECT session_id FROM runs WHERE run_id=?", (run_id,)
            ).fetchone()
            if row is None:
                return
            last = cur.execute(
                "SELECT COALESCE(MAX(id), 0) AS m FROM messages WHERE session_id=?",
                (int(row["session_id"]),),
            ).fetchone()
            cur.execute(
                "UPDATE runs SET state=?, reason=?, final_answer=?, iterations=?, "
                "tokens_spent=?, last_mid=?, finished_at=? WHERE run_id=?",
                (
                    RUN_FINISHED,
                    reason,
                    final_answer,
                    int(iterations),
                    int(tokens_spent),
                    int(last["m"]) if last else 0,
                    time.time(),
                    run_id,
                ),
            )

        self._write(op)

    def fail_run(self, run_id: str, *, reason: str) -> None:
        """Close a run as ``failed`` (a crashed loop, a host restart)."""

        def op(cur: sqlite3.Cursor) -> None:
            row = cur.execute(
                "SELECT session_id FROM runs WHERE run_id=?", (run_id,)
            ).fetchone()
            if row is None:
                return
            last = cur.execute(
                "SELECT COALESCE(MAX(id), 0) AS m FROM messages WHERE session_id=?",
                (int(row["session_id"]),),
            ).fetchone()
            cur.execute(
                "UPDATE runs SET state=?, reason=?, last_mid=?, finished_at=? "
                "WHERE run_id=?",
                (RUN_FAILED, reason, int(last["m"]) if last else 0, time.time(), run_id),
            )

        self._write(op)

    def get_run(self, run_id: str) -> dict | None:
        row = self._conn().execute(
            "SELECT * FROM runs WHERE run_id=?", (run_id,)
        ).fetchone()
        return dict(row) if row else None

    def latest_run(self, session_key: str) -> dict | None:
        """The most recently started run for a session, or None."""
        row = self._conn().execute(
            "SELECT * FROM runs WHERE session_key=? ORDER BY started_at DESC, "
            "rowid DESC LIMIT 1",
            (session_key,),
        ).fetchone()
        return dict(row) if row else None

    def run_terminals(self, session_key: str, *, after_id: int = 0) -> list[dict]:
        """The closed runs of a session as replay ``done`` events, so a client
        that was away sees each run's end after its last turn. Only runs whose
        last message is past ``after_id`` — the client already has the rest."""
        rows = self._conn().execute(
            "SELECT * FROM runs WHERE session_key=? AND state IN (?, ?) "
            "AND COALESCE(last_mid, 0) > ? ORDER BY COALESCE(last_mid, 0), started_at",
            (session_key, RUN_FINISHED, RUN_FAILED, after_id),
        ).fetchall()
        events: list[dict] = []
        for r in rows:
            events.append(
                {
                    "type": "done",
                    "final_answer": r["final_answer"],
                    "reason": r["reason"] or ("finished" if r["state"] == RUN_FINISHED else "failed"),
                    "iterations": int(r["iterations"] or 0),
                    "tokens_spent": int(r["tokens_spent"] or 0),
                    "replay": True,
                    "run_id": r["run_id"],
                    # "Finished while the user was away": the app never
                    # acknowledged this run's live ``done`` (``run_ack``).
                    "while_away": r["seen_at"] is None,
                    "mid": int(r["last_mid"] or 0),
                }
            )
        return events

    def mark_run_notified(self, run_id: str) -> bool:
        """Set ``notified_at`` once. Returns True the first time only, so two
        notifiers cannot both fire for one run. This is the notification dedup
        key; it says nothing about whether the user opened the app."""

        def op(cur: sqlite3.Cursor) -> bool:
            cur.execute(
                "UPDATE runs SET notified_at=? WHERE run_id=? AND notified_at IS NULL",
                (time.time(), run_id),
            )
            return cur.rowcount > 0

        return bool(self._write(op))

    def mark_run_seen(self, run_id: str) -> bool:
        """Set ``seen_at`` once: the app rendered this run's live ``done``
        (``run_ack``), so a later replay no longer flags it ``while_away``."""

        def op(cur: sqlite3.Cursor) -> bool:
            cur.execute(
                "UPDATE runs SET seen_at=? WHERE run_id=? AND seen_at IS NULL",
                (time.time(), run_id),
            )
            return cur.rowcount > 0

        return bool(self._write(op))

    def sweep_orphan_runs(self, *, reason: str = "host_restarted") -> int:
        """On host start: a run still ``running`` was cut off by a crash or a
        restart. Close it as failed so it never shows as live. Returns the count."""

        def op(cur: sqlite3.Cursor) -> int:
            cur.execute(
                "UPDATE runs SET state=?, reason=?, finished_at=? WHERE state=?",
                (RUN_FAILED, reason, time.time(), RUN_RUNNING),
            )
            return int(cur.rowcount)

        return int(self._write(op))

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
