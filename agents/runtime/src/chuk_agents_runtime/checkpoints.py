"""Checkpoints of a thread, rewind and fork (docs/WIRE_CONTRACT.md,
"Checkpoints, rewind and fork"; Hermes H30/H31, opencode O2).

A run's first workspace-changing tool call pins the workspace as it was
(:meth:`chuk_agents_runtime.workspace_git.GitWorkspace.create_checkpoint`, in
the agent's private git). This module keeps the list per thread, next to the
thread in the state store (a ``session_features`` document), and copies a
thread for a fork. Pure store logic: the executor serves the frames.
"""

from __future__ import annotations

import json
import time
from typing import Any

FEATURE_KIND = "checkpoints"
MAX_CHECKPOINTS = 50
PROMPT_PREVIEW_CHARS = 160


def _items(doc: dict | None) -> list[dict]:
    items = (doc or {}).get("items")
    return [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []


def last_user_mid(store: Any, session_key: str) -> int | None:
    """The id of the newest user row of the thread: the message a run that
    is working now answers."""
    session_id = store.resolve_session(session_key)
    if session_id is None:
        return None
    row = store._conn().execute(  # noqa: SLF001 — one read the store has no helper for
        "SELECT id, content FROM messages WHERE session_id=? AND role='user' ORDER BY id DESC LIMIT 1",
        (session_id,),
    ).fetchone()
    return int(row["id"]) if row else None


def _prompt_of(store: Any, mid: int | None) -> str:
    if mid is None:
        return ""
    row = store._conn().execute("SELECT content FROM messages WHERE id=?", (mid,)).fetchone()  # noqa: SLF001
    if row is None:
        return ""
    try:
        content = json.loads(row["content"]).get("content")
    except (ValueError, AttributeError):
        return ""
    if isinstance(content, list):
        content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    text = " ".join(str(content or "").split())
    return text[:PROMPT_PREVIEW_CHARS]


def record_checkpoint(
    store: Any,
    session_key: str,
    *,
    checkpoint_id: str,
    commit: str,
    run_id: str | None = None,
    user_mid: int | None = None,
) -> tuple[dict, list[str]]:
    """Store one checkpoint. Returns ``(item, dropped ids)``: the oldest are
    dropped beyond :data:`MAX_CHECKPOINTS` (the caller removes their refs)."""
    item = {
        "id": checkpoint_id,
        "commit": commit,
        "created_at": time.time(),
        "run_id": run_id,
        "user_mid": user_mid,
        "prompt": _prompt_of(store, user_mid),
    }

    def update(current: dict | None):
        items = _items(current) + [item]
        dropped = [i["id"] for i in items[:-MAX_CHECKPOINTS]]
        return {"items": items[-MAX_CHECKPOINTS:]}, dropped

    dropped = store.update_feature(session_key, FEATURE_KIND, update)
    return item, list(dropped or [])


def list_checkpoints(store: Any, session_key: str) -> list[dict]:
    """Newest first, as the app shows them."""
    return list(reversed(_items(store.load_feature(session_key, FEATURE_KIND))))


def find_checkpoint(store: Any, session_key: str, checkpoint_id: str) -> dict | None:
    for item in _items(store.load_feature(session_key, FEATURE_KIND)):
        if item.get("id") == checkpoint_id:
            return item
    return None


def checkpoint_after(store: Any, session_key: str, mid: int) -> dict | None:
    """The workspace "as of message ``mid``": the checkpoint of the first
    later run that changed files (taken before it wrote). ``None`` = no later
    run wrote anything, so the workspace is still as of ``mid``."""
    for item in _items(store.load_feature(session_key, FEATURE_KIND)):
        user_mid = item.get("user_mid")
        if isinstance(user_mid, int) and user_mid > mid:
            return item
    return None


class ForkError(ValueError):
    """The fork cannot be made; nothing was written."""


def fork_session(store: Any, source_key: str, mid: int, new_key: str) -> int:
    """Copy the rows of ``source_key`` up to and including ``mid`` into a new
    thread ``new_key`` (events and their file bytes included, in order).
    Returns the number of rows copied. The new thread must not exist yet."""
    source_id = store.resolve_session(source_key)
    if source_id is None:
        raise ForkError("no such thread")
    if store.resolve_session(new_key) is not None:
        raise ForkError("the new thread already exists")
    conn = store._conn()  # noqa: SLF001
    owner = conn.execute("SELECT session_id FROM messages WHERE id=?", (int(mid),)).fetchone()
    if owner is None or int(owner["session_id"]) != source_id:
        raise ForkError("the message is not in this thread")
    rows = conn.execute(
        "SELECT id, role, content, created_at FROM messages WHERE session_id=? AND id<=? ORDER BY id",
        (source_id, int(mid)),
    ).fetchall()
    meta = {"forked_from": source_key, "fork_mid": int(mid)}

    def op(cur) -> int:
        cur.execute("INSERT INTO sessions(created_at, meta) VALUES (?, ?)", (time.time(), json.dumps(meta)))
        new_id = int(cur.lastrowid)
        cur.execute("INSERT INTO session_routes(session_key, session_id) VALUES (?, ?)", (new_key, new_id))
        for row in rows:
            cur.execute(
                "INSERT INTO messages(session_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                (new_id, row["role"], row["content"], row["created_at"]),
            )
            new_mid = int(cur.lastrowid)
            if row["role"] == "event":
                blob = cur.execute(
                    "SELECT data FROM event_blobs WHERE message_id=?", (int(row["id"]),)
                ).fetchone()
                if blob is not None:
                    cur.execute(
                        "INSERT INTO event_blobs(message_id, data) VALUES (?, ?)",
                        (new_mid, blob["data"]),
                    )
        return len(rows)

    return int(store._write(op))  # noqa: SLF001


__all__ = [
    "FEATURE_KIND",
    "MAX_CHECKPOINTS",
    "ForkError",
    "checkpoint_after",
    "find_checkpoint",
    "fork_session",
    "last_user_mid",
    "list_checkpoints",
    "record_checkpoint",
]
