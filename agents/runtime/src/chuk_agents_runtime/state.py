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
  needs a second store or a model call. See :mod:`chuk_agents_runtime.search`.
"""

from __future__ import annotations

import base64
import binascii
import json
import random
import sqlite3
import threading
import time
from dataclasses import dataclass
from typing import Any

from .cost import cost_block
from .search import ensure_fts_schema, register_functions, search_messages
from .sqlite_tuning import tune_connection
from .tool_events import tool_event_fields

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

-- The bytes of a persisted ``file`` event (docs/WIRE_CONTRACT.md, bead
-- cowork-266). Kept out of the message row's JSON so the row stays small for
-- every reader of ``messages`` (model context, search index); rejoined on
-- replay. One blob per event row, addressed by the row id.
CREATE TABLE IF NOT EXISTS event_blobs (
    message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    data BLOB NOT NULL
);

-- The context ladder's last compaction summary per session (§7.3, bead
-- chuk_chat-p5xm). A cache, never the truth: the ladder uses it only while
-- ``prefix_digest`` still matches the stored rows it summarized, so a new
-- run does not block on the aux model to fold the same middle again.
CREATE TABLE IF NOT EXISTS context_summaries (
    session_id      INTEGER PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
    summary         TEXT NOT NULL,
    summarized_upto INTEGER NOT NULL,
    prefix_digest   TEXT NOT NULL,
    updated_at      REAL NOT NULL
);

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
    seen_at      REAL,
    -- What the task asked for (WIRE_CONTRACT task fields); NULL = host default.
    -- Added additively; RUNS_MIGRATIONS backfills an existing database.
    model            TEXT,
    provider         TEXT,
    reasoning_effort TEXT,
    -- Where the run's wall clock went (chuk_agents_runtime.loop.RunTimings).
    -- ``iterations`` and ``tokens_spent`` say how much work a run did; these say
    -- how long each part of it waited, so a four-minute turn can be attributed
    -- after the fact instead of reconstructed from message timestamps by hand.
    -- ``retries``/``retry_ms`` are the model attempts that were thrown away —
    -- paid for twice at the provider and previously invisible.
    -- Added additively; RUNS_MIGRATIONS backfills an existing database.
    model_calls   INTEGER NOT NULL DEFAULT 0,
    model_wait_ms INTEGER NOT NULL DEFAULT 0,
    prepare_ms    INTEGER NOT NULL DEFAULT 0,
    tool_ms       INTEGER NOT NULL DEFAULT 0,
    recall_ms     INTEGER NOT NULL DEFAULT 0,
    retries       INTEGER NOT NULL DEFAULT 0,
    retry_ms      INTEGER NOT NULL DEFAULT 0,
    -- Prompt tokens the provider served from its cache, summed over the run's
    -- model calls (``prompt_tokens_details.cached_tokens``), and the provider's
    -- time to the first streamed token of the run's first call, the history
    -- rebuild (``prepare_ms``) left out. 0 = not reported / not measured.
    cached_tokens  INTEGER NOT NULL DEFAULT 0,
    first_token_ms INTEGER NOT NULL DEFAULT 0,
    -- The split of ``tokens_spent`` and what the run's own model calls cost in
    -- euro at the price the API bills (chuk_agents_runtime.cost, bead
    -- chuk_chat-qcbv). ``cost_eur`` NULL = not priced (no price list, or a
    -- model the list does not know). Housekeeping calls are not in it: they
    -- are rows of ``usage_lines``.
    prompt_tokens     INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    cost_eur          REAL
);

CREATE INDEX IF NOT EXISTS idx_runs_session ON runs(session_key, started_at);

-- One row per priced line of spend (docs/WIRE_CONTRACT.md, "Cost per run and
-- weekly budget"): ``run`` is a run's own model calls, ``aux`` the context
-- summary and memory extraction, ``browser`` the browser fallback. ``run_id``
-- is the run that caused it (a background summary made after the run still
-- names it). The weekly budget sums ``cost_eur`` by ``created_at``.
CREATE TABLE IF NOT EXISTS usage_lines (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id            TEXT,
    session_key       TEXT NOT NULL,
    kind              TEXT NOT NULL,
    model             TEXT,
    provider          TEXT,
    prompt_tokens     INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    cached_tokens     INTEGER NOT NULL DEFAULT 0,
    cost_eur          REAL,
    created_at        REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_usage_lines_run ON usage_lines(run_id);
CREATE INDEX IF NOT EXISTS idx_usage_lines_time ON usage_lines(created_at);
"""

#: Columns added to ``runs`` after the table first shipped, in order. Each is
#: ``ALTER TABLE ... ADD COLUMN``ed into an existing database on open when it is
#: missing (see ``StateStore._init_schema``). Append here; never rename or drop.
RUNS_MIGRATIONS: tuple[tuple[str, str], ...] = (
    ("model", "TEXT"),
    ("provider", "TEXT"),
    ("reasoning_effort", "TEXT"),
    # Timing attribution. ``NOT NULL DEFAULT 0`` is legal in an ALTER TABLE ADD
    # COLUMN because the default is a constant, so an existing 8 MB database
    # migrates in place on open and its old rows read as zero — "not measured",
    # which is exactly what they are.
    ("model_calls", "INTEGER NOT NULL DEFAULT 0"),
    ("model_wait_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("prepare_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("tool_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("recall_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("retries", "INTEGER NOT NULL DEFAULT 0"),
    ("retry_ms", "INTEGER NOT NULL DEFAULT 0"),
    # Cache hits and time to first token, for the speed harness.
    ("cached_tokens", "INTEGER NOT NULL DEFAULT 0"),
    ("first_token_ms", "INTEGER NOT NULL DEFAULT 0"),
    # Cost per run (bead chuk_chat-qcbv). Old rows read 0 / NULL: not priced.
    ("prompt_tokens", "INTEGER NOT NULL DEFAULT 0"),
    ("completion_tokens", "INTEGER NOT NULL DEFAULT 0"),
    ("cost_eur", "REAL"),
)

#: The timing columns, in the order :meth:`StateStore.finish_run` writes them.
RUN_TIMING_COLUMNS: tuple[str, ...] = (
    "model_calls",
    "model_wait_ms",
    "prepare_ms",
    "tool_ms",
    "recall_ms",
    "retries",
    "retry_ms",
    "cached_tokens",
    "first_token_ms",
    "prompt_tokens",
    "completion_tokens",
)

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


def run_stamp_fields(row: dict | None) -> dict[str, Any]:
    """``started_at`` / ``finished_at`` / ``first_mid`` / ``last_mid`` of a
    ``runs`` row, for a ``done`` frame (live and replayed alike). Only the
    fields the row has; an empty dict for no row."""
    if not row:
        return {}
    fields: dict[str, Any] = {}
    for key in ("started_at", "finished_at"):
        value = row.get(key)
        if value is not None:
            fields[key] = float(value)
    for key in ("first_mid", "last_mid"):
        value = row.get(key)
        if value is not None:
            fields[key] = int(value)
    return fields


def _close_open_approvals(
    cur: sqlite3.Cursor, session_id: int, reason: str, at: float | None
) -> int:
    """See :meth:`StateStore.close_open_approvals`; shares the caller's cursor
    so a run's close and its approvals' close are one transaction."""
    rows = cur.execute(
        "SELECT id, content FROM messages WHERE session_id=? AND role='event'",
        (session_id,),
    ).fetchall()
    count = 0
    for row in rows:
        content = json.loads(row["content"])
        if content.get("type") != "approval_request" or content.get("decision"):
            continue
        content["decision"] = "denied"
        content["decision_reason"] = reason
        content["decided_at"] = float(at if at is not None else time.time())
        cur.execute(
            "UPDATE messages SET content=? WHERE id=?",
            (json.dumps(content), int(row["id"])),
        )
        count += 1
    return count


def _tool_rows_after(conversation: list[Message], index: int) -> list[Message]:
    """The consecutive ``tool`` rows that directly follow row ``index``: the
    results of that assistant turn's calls, in call order."""
    rows: list[Message] = []
    for message in conversation[index + 1 :]:
        if message.content.get("role") != "tool":
            break
        rows.append(message)
    return rows


def _match_tool_row(
    answers: list[Message], call_id: str, position: int
) -> Message | None:
    """The result row for one call: by ``tool_call_id`` first, else the row at
    the call's position in the turn."""
    if call_id:
        for row in answers:
            if str(row.content.get("tool_call_id", "")) == call_id:
                return row
    if 0 <= position < len(answers):
        return answers[position]
    return None


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
            # See sqlite_tuning: no fsync per commit, no checkpoint per close.
            # Without it a fresh file's ~30 schema statements and every close
            # held the executor's serve thread for seconds on a busy disk.
            tune_connection(conn)
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
        # ``CREATE TABLE IF NOT EXISTS`` leaves an existing ``runs`` table as it
        # was, so columns added later must be backfilled by hand. Additive and
        # idempotent: nullable columns, added only when missing, never dropped.
        present = {
            row[1] for row in conn.execute("PRAGMA table_info(runs)").fetchall()
        }
        for column, sql_type in RUNS_MIGRATIONS:
            if column not in present:
                conn.execute(f"ALTER TABLE runs ADD COLUMN {column} {sql_type}")
        conn.commit()
        return ensure_fts_schema(conn)

    def close(self) -> None:
        """Close the calling thread's connection (see
        :meth:`close_thread_connection`)."""
        self.close_thread_connection()

    def close_thread_connection(self) -> None:
        """Close the connection that belongs to the calling thread, if any.

        Connections are per thread (``threading.local``). A short-lived worker
        thread (a background summary job) calls this before it ends, so its
        connection does not stay open until the garbage collector finds it.
        The next call on this thread opens a fresh connection."""
        conn = getattr(self._local, "conn", None)
        if conn is not None:
            self._local.conn = None
            conn.close()

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

    # -- persisted stream events (docs/WIRE_CONTRACT.md, bead cowork-266) --

    def append_event(self, session_id: int, payload: dict) -> int:
        """Persist one live ``subagent`` / ``file`` / ``approval_request`` frame
        as an ``event`` row, at the moment it is streamed, so it replays at its
        place in the thread. ``payload`` is the wire frame itself (its ``type``
        included). A ``file`` frame's base64 ``data`` goes to ``event_blobs``
        as bytes, not into the row's JSON. Returns the row id (the ``mid``)."""
        content = dict(payload)
        blob: bytes | None = None
        data = content.pop("data", None)
        if isinstance(data, str) and data:
            try:
                blob = base64.b64decode(data, validate=True)
            except (binascii.Error, ValueError):
                blob = None  # a frame without a usable body replays without one

        def op(cur: sqlite3.Cursor) -> int:
            cur.execute(
                "INSERT INTO messages(session_id, role, content, created_at) "
                "VALUES (?, 'event', ?, ?)",
                (session_id, json.dumps(content), time.time()),
            )
            mid = int(cur.lastrowid)
            if blob is not None:
                cur.execute(
                    "INSERT INTO event_blobs(message_id, data) VALUES (?, ?)",
                    (mid, blob),
                )
            return mid

        return int(self._write(op))

    def update_event(self, message_id: int, patch: dict) -> bool:
        """Merge ``patch`` into one ``event`` row's frame (the outcome of an
        ``approval_request``). False when there is no such event row."""

        def op(cur: sqlite3.Cursor) -> bool:
            row = cur.execute(
                "SELECT content FROM messages WHERE id=? AND role='event'",
                (message_id,),
            ).fetchone()
            if row is None:
                return False
            content = json.loads(row["content"])
            content.update(patch)
            cur.execute(
                "UPDATE messages SET content=? WHERE id=?",
                (json.dumps(content), message_id),
            )
            return True

        return bool(self._write(op))

    def close_open_approvals(
        self, session_id: int, *, reason: str, at: float | None = None
    ) -> int:
        """Patch every ``approval_request`` event row of the session that still
        has no ``decision`` to ``denied`` / ``reason``. The run that asked is
        over (or the host restarted), so nobody can answer it any more, and a
        replay must never prompt for it. Returns the count."""

        def op(cur: sqlite3.Cursor) -> int:
            return _close_open_approvals(cur, session_id, reason, at)

        return int(self._write(op))

    def event_blob(self, message_id: int) -> bytes | None:
        """The bytes stored with a ``file`` event row, or None."""
        row = self._conn().execute(
            "SELECT data FROM event_blobs WHERE message_id=?", (message_id,)
        ).fetchone()
        return bytes(row["data"]) if row is not None else None

    def drop_last_user_turn(self, session_id: int) -> int:
        """Remove the last user turn and everything the model said after it.

        This is what a "retry the answer" is on the server side. A retry sends
        the same prompt again, so without this the conversation grows a second
        identical user row, then a third — the transcript shows the question
        once per attempt on replay, and, worse, the model is handed a history in
        which the user asked the same thing four times and it answered four
        times. The user meant to REPLACE an answer, not to ask again.

        Returns the number of rows removed; ``0`` when the session has no user
        turn yet (a retry on an empty session is not a thing, but it must not
        raise). The system prompt is never touched — it is seeded once and sits
        before any user turn.
        """

        def op(cur: sqlite3.Cursor) -> int:
            row = cur.execute(
                "SELECT id FROM messages WHERE session_id=? AND role='user' "
                "ORDER BY id DESC LIMIT 1",
                (session_id,),
            ).fetchone()
            if row is None:
                return 0
            cur.execute(
                "DELETE FROM messages WHERE session_id=? AND id>=?",
                (session_id, int(row["id"])),
            )
            return int(cur.rowcount)

        return self._write(op)

    # -- context ladder summary (chuk_agents_runtime.context.SummaryStore) -------

    def load_context_summary(self, session_id: int) -> dict | None:
        """The session's last compaction summary, or ``None``. The ladder
        checks ``prefix_digest`` before it trusts the row."""
        row = self._conn().execute(
            "SELECT summary, summarized_upto, prefix_digest FROM context_summaries "
            "WHERE session_id=?",
            (session_id,),
        ).fetchone()
        if row is None:
            return None
        return {
            "summary": row["summary"],
            "summarized_upto": int(row["summarized_upto"]),
            "prefix_digest": row["prefix_digest"],
        }

    def save_context_summary(
        self,
        session_id: int,
        *,
        summary: str,
        summarized_upto: int,
        prefix_digest: str,
        only_if_covers_more: bool = False,
        replaces: dict | None = None,
    ) -> bool:
        """Store the session's summary. True when the row was written.

        With ``only_if_covers_more`` the write is a compare-and-set in one SQL
        statement: an existing row is replaced only when it covers fewer
        messages than this one, or when it is still exactly ``replaces`` (the
        row the caller read and judged stale). So a background job can never
        overwrite a newer summary that another writer stored after its read.
        """
        sql = (
            "INSERT INTO context_summaries"
            "(session_id, summary, summarized_upto, prefix_digest, updated_at) "
            "VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT(session_id) DO UPDATE SET summary=excluded.summary, "
            "summarized_upto=excluded.summarized_upto, "
            "prefix_digest=excluded.prefix_digest, updated_at=excluded.updated_at"
        )
        params: list = [session_id, summary, int(summarized_upto), prefix_digest, time.time()]
        if only_if_covers_more:
            sql += " WHERE context_summaries.summarized_upto < excluded.summarized_upto"
            if replaces is not None:
                sql += (
                    " OR (context_summaries.summarized_upto = ?"
                    " AND context_summaries.prefix_digest = ?)"
                )
                params += [int(replaces.get("summarized_upto") or 0), replaces.get("prefix_digest")]
        written = False

        def op(cur: sqlite3.Cursor) -> None:
            nonlocal written
            cur.execute(sql, params)
            written = cur.rowcount > 0

        self._write(op)
        return written

    def get_conversation(
        self, session_id: int, *, include_events: bool = False
    ) -> list[Message]:
        """All messages for a session, ordered by autoincrement id — never by a
        timestamp.

        ``event`` rows (a persisted ``subagent`` / ``file`` /
        ``approval_request`` frame, see :meth:`append_event`) are left out
        unless ``include_events`` is set: they are for the app's replay, never
        for the model's context."""
        rows = self._conn().execute(
            "SELECT id, session_id, role, content, created_at "
            "FROM messages WHERE session_id=?"
            + ("" if include_events else " AND role<>'event'")
            + " ORDER BY id",
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

    def replay_page_bounds(
        self, session_id: int, *, after_id: int = 0, before_id: int = 0, limit: int = 0
    ) -> tuple[int, bool]:
        """The lower bound of one replay page (docs/WIRE_CONTRACT.md, "Replay
        paging"): the newest ``limit`` turn rows (``user`` / ``assistant``) of the
        window ``after_id < id < before_id`` (``before_id`` 0 = open). Returns
        ``(page_after_id, has_more)``: replay ``mid > page_after_id`` to get the
        page, and whether turn rows exist at or below ``page_after_id`` (still
        above ``after_id``) — the next, older page. ``limit`` 0 = no paging:
        ``(after_id, False)``."""
        if limit <= 0:
            return after_id, False
        sql = (
            "SELECT id FROM messages WHERE session_id=? AND role IN ('user','assistant') "
            "AND id > ?" + (" AND id < ?" if before_id > 0 else "") + " ORDER BY id DESC LIMIT 1 OFFSET ?"
        )
        params: list = [session_id, after_id]
        if before_id > 0:
            params.append(before_id)
        params.append(limit - 1)
        row = self._conn().execute(sql, params).fetchone()
        if row is None:
            # Fewer turn rows than a page: everything from ``after_id`` on.
            return after_id, False
        page_after_id = int(row["id"]) - 1
        older = self._conn().execute(
            "SELECT 1 FROM messages WHERE session_id=? AND role IN ('user','assistant') "
            "AND id > ? AND id <= ? LIMIT 1",
            (session_id, after_id, page_after_id),
        ).fetchone()
        return page_after_id, older is not None

    def replay_events(
        self, session_id: int, *, after_id: int = 0, before_id: int = 0
    ) -> list[dict]:
        """Rebuild the stored transcript as stream events, in the SAME shapes the
        executor streams live (see ``chuk_agents_executor.protocol``). Every event
        carries ``"replay": True`` so a client tells a replayed turn from a live
        one. ``before_id`` (docs/WIRE_CONTRACT.md, "Replay paging") caps the
        window: only rows with ``mid < before_id`` (0 = no cap).

        The server is the source of truth. A fresh or reinstalled client
        reconnects, asks for this list, and rebuilds the whole thread from it. The
        order is the stored order — by autoincrement id, never a clock.

        One stored row maps to one event, or to none:

        - a ``system`` row is dropped. The system prompt is not part of the
          thread the user reads.
        - a ``user`` row becomes a ``user`` event. The live stream has no such
          event, because the live client wrote that turn itself; a reconnecting
          client did not, so replay must carry both sides of the thread.
        - an ``assistant`` row with ``reasoning`` becomes a ``reasoning`` event
          first — the shape a live thinking chunk uses — so the thinking block
          is rebuilt above the answer, where it was live.
        - an ``assistant`` row with text becomes a ``delta`` event — the shape a
          live assistant text chunk uses.
        - an ``assistant`` row with tool calls becomes one ``tool`` event per
          call — the shape a live tool event uses. The matching tool-result row
          fills ``stdout``, so the verbose view shows what the tool returned.
        - a ``tool`` row is folded into its call's event by ``tool_call_id``. It
          is not emitted on its own.
        """
        thread = self.get_conversation(session_id, include_events=True)
        # The turns the model saw; ``event`` rows are handled on their own below
        # so a file that landed mid-turn cannot split a call from its result.
        conversation = [m for m in thread if m.role != "event"]
        events: list[dict] = []
        # An ``event`` row (docs/WIRE_CONTRACT.md, "Persisted subagent / file /
        # approval events") IS the live frame: it replays as itself, marked,
        # with its row id; a ``file`` gets its bytes back from ``event_blobs``.
        for message in thread:
            if message.role != "event" or message.id <= after_id:
                continue
            event = dict(message.content)
            if event.get("type") == "file":
                blob = self.event_blob(message.id)
                if blob is not None:
                    event["data"] = base64.b64encode(blob).decode("ascii")
            event["replay"] = True
            event["mid"] = message.id
            events.append(event)
        for index, message in enumerate(conversation):
            # The replay cursor (docs/WIRE_CONTRACT.md): a client that already
            # holds the thread up to ``after_id`` gets only what came later.
            if message.id <= after_id:
                continue
            # Only what the user typed and what the model said is the thread.
            # A ``context`` row (a skill body), a ``memory`` row (the task-start
            # recall) or any other runtime row carries a wire role of ``user``
            # inside, but it was never the user's message and must not replay
            # as one. ``event`` rows were emitted above.
            if message.role not in ("user", "assistant"):
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
                        "created_at": message.created_at,
                    }
                )
                continue
            # assistant
            # The turn's thinking comes first, as it did live: the app renders
            # it as the thinking block above the answer text (and above the
            # tool calls of the same turn).
            reasoning = content.get("reasoning")
            if isinstance(reasoning, str) and reasoning.strip():
                events.append(
                    {"type": "reasoning", "text": reasoning, "replay": True, "mid": mid,
                     "created_at": message.created_at}
                )
            text = content.get("content")
            if isinstance(text, str) and text.strip():
                events.append({"type": "delta", "text": text, "replay": True, "mid": mid,
                               "created_at": message.created_at})
            # The result rows of this turn are the ``tool`` rows right after it
            # (the loop writes one per call, in call order). Matched by call id
            # within that group, else by position — a model (or the mock) that
            # reuses call ids across turns must not cross-wire results.
            answers = _tool_rows_after(conversation, index)
            for position, call in enumerate(content.get("tool_calls") or []):
                if not isinstance(call, dict):
                    continue
                fn = call.get("function", {}) or {}
                call_id = str(call.get("id", ""))
                answer = _match_tool_row(answers, call_id, position)
                # The same shape the loop streams live (``tool_event_fields``):
                # the native arguments, the result text, the projected shell
                # fields, the status — and the clocks: the call was made when
                # the assistant row landed, answered when its tool row did.
                events.append(
                    {
                        "type": "tool",
                        **tool_event_fields(
                            name=str(fn.get("name", "")),
                            arguments=fn.get("arguments", {}),
                            result=answer.content.get("content") if answer else None,
                            call_id=call_id or None,
                            started_at=message.created_at,
                            completed_at=answer.created_at if answer else None,
                        ),
                        "replay": True,
                        "mid": mid,
                    }
                )
        # Thread order is row order. The sort is stable, so a turn's reasoning /
        # delta / tool events (same ``mid``) keep the order they were built in.
        events.sort(key=lambda event: int(event.get("mid", 0)))
        if before_id > 0:
            # Replay paging: the window's upper edge. Every event carries its
            # row id, so the cap is one filter, not a second query per shape.
            events = [e for e in events if int(e.get("mid", 0)) < before_id]
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
        self,
        run_id: str,
        session_id: int,
        session_key: str,
        prompt: str,
        *,
        model: str | None = None,
        provider: str | None = None,
        reasoning_effort: str | None = None,
    ) -> None:
        """Record an accepted task as ``running``. ``first_mid`` is the message
        cursor at that moment, so the run's own turns are the rows after it.

        ``model`` / ``provider`` / ``reasoning_effort`` are what the task asked
        for (docs/WIRE_CONTRACT.md task fields), ``None`` meaning the host's
        default — recorded so a run can prove afterwards which model it ran on.
        """
        first_mid = self.max_message_id(session_id)

        def op(cur: sqlite3.Cursor) -> None:
            cur.execute(
                "INSERT INTO runs(run_id, session_id, session_key, prompt, state, "
                "first_mid, started_at, model, provider, reasoning_effort) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(run_id) DO NOTHING",
                (
                    run_id,
                    session_id,
                    session_key,
                    prompt,
                    RUN_RUNNING,
                    first_mid,
                    time.time(),
                    model,
                    provider,
                    reasoning_effort,
                ),
            )

        self._write(op)

    def update_run_reasoning_effort(self, run_id: str, effort: str | None) -> None:
        """Record the level a run actually ran on when the executor's selector
        clamped what the task asked for (an unsupported ``reasoning_effort``),
        so the row proves the effective level, not the request."""

        def op(cur: sqlite3.Cursor) -> None:
            cur.execute(
                "UPDATE runs SET reasoning_effort=? WHERE run_id=?", (effort, run_id)
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
        timings: dict[str, int] | None = None,
        cost_eur: float | None = None,
    ) -> None:
        """Close a run as ``finished``. ``last_mid`` is the message cursor at the
        end, so a replay can place the run's terminal after its last turn.

        ``timings`` is :meth:`chuk_agents_runtime.loop.RunTimings.as_row` — where the
        run's wall clock went. Unknown keys are ignored and missing ones stay
        zero, so an older caller that passes nothing still closes a valid row.
        ``cost_eur`` is what the run's own model calls cost (``None`` = not
        priced); the caller writes the matching ``run`` line with
        :meth:`add_usage_line`.
        """
        stamps = {k: int(v) for k, v in (timings or {}).items() if k in RUN_TIMING_COLUMNS}
        timing_sql = "".join(f", {column}=?" for column in RUN_TIMING_COLUMNS)
        timing_values = tuple(stamps.get(column, 0) for column in RUN_TIMING_COLUMNS)

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
                "tokens_spent=?, last_mid=?, finished_at=?, cost_eur=?" + timing_sql
                + " WHERE run_id=?",
                (
                    RUN_FINISHED,
                    reason,
                    final_answer,
                    int(iterations),
                    int(tokens_spent),
                    int(last["m"]) if last else 0,
                    time.time(),
                    float(cost_eur) if cost_eur is not None else None,
                    *timing_values,
                    run_id,
                ),
            )
            # A publish approval nobody answered cannot be answered any more
            # (docs/WIRE_CONTRACT.md, cowork-266): close it with the run.
            _close_open_approvals(cur, int(row["session_id"]), "stopped", None)

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
            _close_open_approvals(cur, int(row["session_id"]), "stopped", None)

        self._write(op)

    # -- cost lines (docs/WIRE_CONTRACT.md, "Cost per run and weekly budget")

    def add_usage_line(
        self,
        *,
        session_key: str,
        kind: str,
        run_id: str | None = None,
        model: str | None = None,
        provider: str | None = None,
        prompt_tokens: int = 0,
        completion_tokens: int = 0,
        cached_tokens: int = 0,
        cost_eur: float | None = None,
        at: float | None = None,
    ) -> int:
        """Record one priced line of spend. Returns the row id."""

        def op(cur: sqlite3.Cursor) -> int:
            cur.execute(
                "INSERT INTO usage_lines(run_id, session_key, kind, model, provider, "
                "prompt_tokens, completion_tokens, cached_tokens, cost_eur, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    run_id,
                    session_key,
                    kind,
                    model,
                    provider,
                    max(0, int(prompt_tokens or 0)),
                    max(0, int(completion_tokens or 0)),
                    max(0, int(cached_tokens or 0)),
                    float(cost_eur) if cost_eur is not None else None,
                    float(at if at is not None else time.time()),
                ),
            )
            return int(cur.lastrowid)

        return int(self._write(op))

    def usage_lines(self, run_id: str) -> list[dict]:
        """The lines one run caused, oldest first, summed per ``(kind, model,
        provider)``: one ``run`` line, one ``aux`` line per aux model, ...
        ``cost_eur`` is ``None`` when any summed row was not priced."""
        rows = self._conn().execute(
            "SELECT kind, model, provider, COUNT(*) AS calls, "
            "SUM(prompt_tokens) AS prompt_tokens, "
            "SUM(completion_tokens) AS completion_tokens, "
            "SUM(cached_tokens) AS cached_tokens, SUM(cost_eur) AS cost_eur, "
            "SUM(cost_eur IS NULL) AS unpriced, MIN(id) AS first "
            "FROM usage_lines WHERE run_id=? GROUP BY kind, model, provider "
            "ORDER BY first",
            (run_id,),
        ).fetchall()
        out: list[dict] = []
        for row in rows:
            out.append(
                {
                    "kind": row["kind"],
                    "model": row["model"],
                    "provider": row["provider"],
                    "calls": int(row["calls"] or 0),
                    "prompt_tokens": int(row["prompt_tokens"] or 0),
                    "completion_tokens": int(row["completion_tokens"] or 0),
                    "cached_tokens": int(row["cached_tokens"] or 0),
                    "cost_eur": (
                        None if int(row["unpriced"] or 0) else float(row["cost_eur"] or 0.0)
                    ),
                }
            )
        return out

    def spend_by_session(self, since: float, *, until: float | None = None) -> dict[str, float]:
        """Euro spent per ``session_key`` in ``[since, until)``, from every
        priced line (runs and housekeeping alike). Unpriced lines count 0."""
        sql = (
            "SELECT session_key, SUM(COALESCE(cost_eur, 0)) AS eur FROM usage_lines "
            "WHERE created_at >= ?" + (" AND created_at < ?" if until is not None else "")
            + " GROUP BY session_key"
        )
        params: tuple = (float(since),) + ((float(until),) if until is not None else ())
        rows = self._conn().execute(sql, params).fetchall()
        return {str(r["session_key"]): float(r["eur"] or 0.0) for r in rows}

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

    def run_terminals(
        self, session_key: str, *, after_id: int = 0, before_id: int = 0
    ) -> list[dict]:
        """The closed runs of a session as replay ``done`` events, so a client
        that was away sees each run's end after its last turn. Only runs whose
        last message is past ``after_id`` — the client already has the rest —
        and, with ``before_id`` (replay paging), below it."""
        rows = self._conn().execute(
            "SELECT * FROM runs WHERE session_key=? AND state IN (?, ?) "
            "AND COALESCE(last_mid, 0) > ? "
            + ("AND COALESCE(last_mid, 0) < ? " if before_id > 0 else "")
            + "ORDER BY COALESCE(last_mid, 0), started_at",
            (session_key, RUN_FINISHED, RUN_FAILED, after_id)
            + ((before_id,) if before_id > 0 else ()),
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
                    # The run's own clock and rows (docs/WIRE_CONTRACT.md, "Run
                    # timestamps on done"), the same four a live done carries.
                    **run_stamp_fields(dict(r)),
                }
            )
            # What the run cost (docs/WIRE_CONTRACT.md, "Cost per run and
            # weekly budget"): the same block a live done carries.
            cost = cost_block(self.usage_lines(r["run_id"]))
            if cost:
                events[-1]["cost"] = cost
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
            orphaned = cur.execute(
                "SELECT DISTINCT session_id FROM runs WHERE state=?", (RUN_RUNNING,)
            ).fetchall()
            cur.execute(
                "UPDATE runs SET state=?, reason=?, finished_at=? WHERE state=?",
                (RUN_FAILED, reason, time.time(), RUN_RUNNING),
            )
            count = int(cur.rowcount)
            # Their publish approvals died with them (docs/WIRE_CONTRACT.md,
            # cowork-266): never replay one as a prompt for a run that is over.
            for row in orphaned:
                _close_open_approvals(cur, int(row["session_id"]), "stopped", None)
            return count

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
        :func:`chuk_agents_runtime.search.search_messages`)."""
        if not self._has_fts:
            return {"ok": False, "error": "this SQLite build has no FTS5", "hits": []}
        return search_messages(
            self._conn(),
            query,
            limit=limit,
            window=window,
            session_id=session_id,
        )
