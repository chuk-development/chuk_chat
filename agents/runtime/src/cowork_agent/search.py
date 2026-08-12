"""Full-text session search, no LLM (§12 B).

SQLite **FTS5** over the append-only message store, kept in sync by triggers.
Three virtual tables, because one tokenizer cannot serve every script:

- ``messages_fts`` — ``unicode61``. Word tokens for space-separated scripts.
  This is the table BM25 ranks best on.
- ``messages_fts_cjk`` — ``unicode61`` over text where every CJK character is
  space-separated, so a one- or two-character Chinese/Japanese query still
  matches. Non-CJK rows index to nothing, so the table stays small.
- ``messages_fts_tri`` — ``trigram``. Substring and typo tolerance for queries
  of three characters or more; also the fallback when a word never appears as a
  whole token.

Hits merge on BM25 with a per-table weight, and each one comes back as an
**anchored window**: ±5 neighbouring messages plus the session's bookends (its
first and last message). A raw window beats a summarizer here — no second model
call, no cost, and the same input always gives the same output.

Two hard rules:

- **User text never reaches MATCH unescaped.** Every token is wrapped as an
  FTS5 phrase with its quotes doubled, so ``"``, ``*``, ``OR`` and ``NEAR`` are
  searched for, not executed. A model that echoes a user's search string cannot
  turn it into a syntax error or a different query.
- **Every result is bounded.** Hit count, window size and per-message length all
  have caps: a search result travels back into the prompt.

The CJK column is filled by ``cowork_cjk_segment``, a deterministic function
registered on every connection :class:`~cowork_agent.state.StateStore` opens.
The store is the only writer to ``messages``; a foreign process that inserts
without registering the function will see the trigger fail.
"""

from __future__ import annotations

import json
import re
import sqlite3

from .registry import ToolRegistry

# -- caps ------------------------------------------------------------------

MAX_HITS = 20
DEFAULT_HITS = 5
MAX_WINDOW = 10
DEFAULT_WINDOW = 5
SNIPPET_CHARS = 240

# BM25 is better calibrated on whole words than on trigrams, so the tables are
# weighted rather than merged flat.
_TABLE_WEIGHTS = {
    "messages_fts": 1.0,
    "messages_fts_cjk": 0.9,
    "messages_fts_tri": 0.6,
}

# -- CJK segmentation -----------------------------------------------------

_CJK_BLOCKS = (
    (0x2E80, 0x2FFF),  # radicals, Kangxi
    (0x3040, 0x30FF),  # kana
    (0x3400, 0x4DBF),  # CJK ext A
    (0x4E00, 0x9FFF),  # CJK unified
    (0xA000, 0xA4CF),  # Yi
    (0xAC00, 0xD7AF),  # Hangul syllables
    (0xF900, 0xFAFF),  # compatibility ideographs
    (0x20000, 0x2FA1F),  # ext B..F
)


def _is_cjk(char: str) -> bool:
    code = ord(char)
    return any(low <= code <= high for low, high in _CJK_BLOCKS)


def segment_cjk(text: str | None) -> str:
    """Space-separate every CJK character. Returns ``""`` when the text has
    none, so the CJK table only ever holds rows it can serve."""
    if not text:
        return ""
    out: list[str] = []
    found = False
    for char in text:
        if _is_cjk(char):
            found = True
            out.append(" ")
            out.append(char)
            out.append(" ")
        else:
            out.append(char)
    return "".join(out) if found else ""


def register_functions(conn: sqlite3.Connection) -> None:
    """Register the SQL helpers the triggers call. Must run on every connection
    that writes ``messages``."""
    conn.create_function("cowork_cjk_segment", 1, segment_cjk, deterministic=True)


# -- schema ----------------------------------------------------------------

# json_extract pulls the human text out of the stored message; a message with no
# `content` key (an assistant turn that only carries tool calls) falls back to
# the whole JSON, so tool names and arguments stay searchable.
_TEXT_EXPR = "COALESCE(json_extract({row}.content, '$.content'), {row}.content)"

_FTS_SCHEMA = f"""
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
    USING fts5(text, tokenize='unicode61 remove_diacritics 2');

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_cjk
    USING fts5(text, tokenize='unicode61 remove_diacritics 2');

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_tri
    USING fts5(text, tokenize='trigram');

CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, text)
        VALUES (new.id, {_TEXT_EXPR.format(row="new")});
    INSERT INTO messages_fts_cjk(rowid, text)
        VALUES (new.id, cowork_cjk_segment({_TEXT_EXPR.format(row="new")}));
    INSERT INTO messages_fts_tri(rowid, text)
        VALUES (new.id, {_TEXT_EXPR.format(row="new")});
END;
"""

_BACKFILL = """
INSERT INTO {table}(rowid, text)
SELECT m.id, {expr} FROM messages m
WHERE m.id NOT IN (SELECT rowid FROM {table});
"""


def fts_available(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS temp.cowork_fts_probe USING fts5(x)"
        )
        conn.execute("DROP TABLE IF EXISTS temp.cowork_fts_probe")
        return True
    except sqlite3.Error:
        return False


def ensure_fts_schema(conn: sqlite3.Connection) -> bool:
    """Create the three tables and the sync trigger, then backfill any message
    written before the index existed. Returns False when this SQLite build has
    no FTS5 — search degrades, the store keeps working."""
    if not fts_available(conn):
        return False
    conn.executescript(_FTS_SCHEMA)
    expr = _TEXT_EXPR.format(row="m")
    conn.execute(_BACKFILL.format(table="messages_fts", expr=expr))
    conn.execute(
        _BACKFILL.format(table="messages_fts_cjk", expr=f"cowork_cjk_segment({expr})")
    )
    conn.execute(_BACKFILL.format(table="messages_fts_tri", expr=expr))
    return True


# -- query sanitizing ------------------------------------------------------

# Everything FTS5 treats as syntax. Stripped before a token is quoted, so a
# token can never collapse to an operator.
_SYNTAX_CHARS = re.compile(r'[\"\'()*^:{}\[\]+\-~]')


def sanitize_match(query: str) -> str:
    """Turn free user text into a safe FTS5 MATCH expression.

    Every token becomes a quoted phrase, which makes ``OR``, ``NEAR``, ``*``,
    ``-`` and ``"`` literal search terms instead of operators. Returns ``""``
    when nothing searchable is left.
    """
    tokens: list[str] = []
    for raw in (query or "").split():
        token = _SYNTAX_CHARS.sub(" ", raw).strip()
        if not token:
            continue
        for part in token.split():
            if not any(char.isalnum() for char in part):
                continue
            tokens.append('"' + part.replace('"', '""') + '"')
    return " ".join(tokens)


def _longest_token(match_expr: str) -> int:
    return max((len(part) - 2 for part in match_expr.split()), default=0)


# -- search ----------------------------------------------------------------


def _message_text(content: dict | str) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, dict):
        return str(content)
    body = content.get("content")
    if isinstance(body, str):
        text = body
    elif body is not None:
        text = json.dumps(body, ensure_ascii=False)
    else:
        text = ""
    calls = content.get("tool_calls")
    if calls:
        names = ", ".join(
            str((call.get("function") or {}).get("name", "?")) for call in calls
        )
        text = f"{text} [tool calls: {names}]".strip()
    name = content.get("name")
    if name:
        text = f"{name}: {text}" if text else str(name)
    return text


def _clip(text: str, limit: int = SNIPPET_CHARS) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 1] + "…"


def _row_to_message(row: sqlite3.Row) -> dict:
    try:
        content = json.loads(row["content"])
    except (json.JSONDecodeError, TypeError):
        content = row["content"]
    return {
        "id": int(row["id"]),
        "role": row["role"],
        "text": _clip(_message_text(content)),
    }


def _fetch(conn: sqlite3.Connection, sql: str, params: tuple) -> list[sqlite3.Row]:
    return conn.execute(sql, params).fetchall()


def _ranked_ids(
    conn: sqlite3.Connection, match_expr: str, limit: int, session_id: int | None
) -> list[tuple[int, float]]:
    """Best message ids across the three tables, merged on weighted BM25."""
    scores: dict[int, float] = {}
    for table, weight in _TABLE_WEIGHTS.items():
        expr = match_expr
        if table == "messages_fts_cjk":
            expr = sanitize_match(segment_cjk(match_expr.replace('"', " ")))
            if not expr:
                continue
        if table == "messages_fts_tri" and _longest_token(match_expr) < 3:
            continue  # the trigram tokenizer cannot serve a 1-2 character token
        sql = (
            f"SELECT f.rowid AS id, bm25({table}) AS rank "
            f"FROM {table} f JOIN messages m ON m.id = f.rowid "
            f"WHERE {table} MATCH ?"
        )
        params: tuple = (expr,)
        if session_id is not None:
            sql += " AND m.session_id = ?"
            params = (expr, session_id)
        sql += " ORDER BY rank LIMIT ?"
        params = params + (limit * 4,)
        try:
            rows = _fetch(conn, sql, params)
        except sqlite3.OperationalError:
            # A malformed MATCH must never take the tool down. sanitize_match
            # should prevent this; the guard keeps a future tokenizer quirk from
            # becoming a crash.
            continue
        for row in rows:
            # bm25 is negative, better matches more negative.
            score = -float(row["rank"]) * weight
            key = int(row["id"])
            if score > scores.get(key, float("-inf")):
                scores[key] = score
    return sorted(scores.items(), key=lambda item: (-item[1], item[0]))[:limit]


def search_messages(
    conn: sqlite3.Connection,
    query: str,
    *,
    limit: int = DEFAULT_HITS,
    window: int = DEFAULT_WINDOW,
    session_id: int | None = None,
) -> dict:
    """Ranked hits, each with an anchored ±``window`` message window and the
    session's bookends."""
    limit = max(1, min(int(limit), MAX_HITS))
    window = max(0, min(int(window), MAX_WINDOW))
    match_expr = sanitize_match(query)
    if not match_expr:
        return {"ok": False, "error": "empty search query", "hits": []}
    if not fts_available(conn):
        return {"ok": False, "error": "this SQLite build has no FTS5", "hits": []}

    hits: list[dict] = []
    for message_id, score in _ranked_ids(conn, match_expr, limit, session_id):
        row = conn.execute(
            "SELECT id, session_id, role, content FROM messages WHERE id=?",
            (message_id,),
        ).fetchone()
        if row is None:
            continue
        sid = int(row["session_id"])
        before = _fetch(
            conn,
            "SELECT id, role, content FROM messages "
            "WHERE session_id=? AND id<? ORDER BY id DESC LIMIT ?",
            (sid, message_id, window),
        )
        after = _fetch(
            conn,
            "SELECT id, role, content FROM messages "
            "WHERE session_id=? AND id>? ORDER BY id LIMIT ?",
            (sid, message_id, window),
        )
        anchored = (
            [_row_to_message(r) for r in reversed(before)]
            + [_row_to_message(row)]
            + [_row_to_message(r) for r in after]
        )
        seen = {item["id"] for item in anchored}
        bookends: dict[str, dict] = {}
        for label, order in (("first", "ASC"), ("last", "DESC")):
            edge = conn.execute(
                "SELECT id, role, content FROM messages WHERE session_id=? "
                f"ORDER BY id {order} LIMIT 1",
                (sid,),
            ).fetchone()
            if edge is not None and int(edge["id"]) not in seen:
                bookends[label] = _row_to_message(edge)
        hits.append(
            {
                "session_id": sid,
                "message_id": message_id,
                "role": row["role"],
                "score": round(score, 4),
                "window": anchored,
                "bookends": bookends,
            }
        )
    return {"ok": True, "query": query, "count": len(hits), "hits": hits}


# -- the tool --------------------------------------------------------------

SEARCH_CHATS_SCHEMA = {
    "type": "object",
    "description": (
        "Search everything you and the user ever said, in every session, by "
        "keyword. Use it to recall an earlier decision, a path, or a name "
        "instead of asking again. Each hit comes back with the messages around "
        "it."
    ),
    "properties": {
        "query": {
            "type": "string",
            "description": "Words to look for. Plain text, no search operators.",
        },
        "limit": {
            "type": "integer",
            "description": "How many hits to return.",
            "default": DEFAULT_HITS,
        },
        "window": {
            "type": "integer",
            "description": "How many messages to show before and after a hit.",
            "default": DEFAULT_WINDOW,
        },
        "session_id": {
            "type": "integer",
            "description": "Search only this session. Omit to search all.",
        },
    },
    "required": ["query"],
}


def make_search_chats_handler(store):
    def search_chats(
        query: str,
        limit: int = DEFAULT_HITS,
        window: int = DEFAULT_WINDOW,
        session_id: int | None = None,
    ) -> dict:
        return store.search_messages(
            query, limit=limit, window=window, session_id=session_id
        )

    return search_chats


def register_search_tool(registry: ToolRegistry, store) -> None:
    registry.register(
        "search_chats", SEARCH_CHATS_SCHEMA, make_search_chats_handler(store)
    )
