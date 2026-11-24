"""Purge on disconnect (CHAT-180, idea 18, the Instinct lesson).

When the user disconnects a connector (an MCP server, a mail account such as
Fastmail, which is an MCP connector too), the host deletes what it kept from
that connector, so nothing indexed from the account stays behind:

- **Memories.** A turn document in Hindsight carries the tag
  ``connector:<server>`` for each connector tool the turn used
  (``memory_hindsight._turn_tags``). :func:`purge_memory` deletes every
  document with one of the tags, in every bank; Hindsight deletes the
  memories made from a document with it.
- **Transcripts and the search index.** A stored ``tool`` row of a connector
  tool (``mcp__<server>__<tool>``) keeps its call id and name, but its result
  becomes :data:`PURGED_RESULT`. The full-text index rows of the message are
  written again from the new text (:func:`purge_transcripts`), so a search
  (``search_chats``) no longer finds the old content.

Everything is best effort and idempotent: a second purge finds nothing more.
The sign-in itself is forgotten by the caller (``mcp_client.GRANTS``).
"""

from __future__ import annotations

import json
import logging
from collections.abc import Iterable, Sequence
from typing import Any

from .mcp_client import TOOL_PREFIX, sanitize

logger = logging.getLogger(__name__)

TAG_PREFIX = "connector:"
#: The result a purged tool row keeps.
PURGED_RESULT = {
    "purged": True,
    "note": "Removed: the user disconnected this connector, so its data was deleted.",
}
#: Upper bound on delete rounds per bank (100 documents each).
MAX_DELETE_ROUNDS = 200

_FTS_TABLES = ("messages_fts", "messages_fts_cjk", "messages_fts_tri")


def server_of_tool(name: Any) -> str | None:
    """The (sanitized) server of a connector tool name, else ``None``."""
    if not isinstance(name, str) or not name.startswith(TOOL_PREFIX):
        return None
    rest = name[len(TOOL_PREFIX) :]
    if "__" not in rest:
        return None
    server = rest.split("__", 1)[0]
    return server or None


def connector_tag(server: str) -> str:
    """The memory tag of one connector (its name as tool names spell it)."""
    return f"{TAG_PREFIX}{sanitize(server)}"


def connector_tags(tool_names: Iterable[Any]) -> list[str]:
    """The tags of the connectors a turn used, sorted, no repeats."""
    servers = {s for s in (server_of_tool(n) for n in tool_names or ()) if s}
    return sorted(f"{TAG_PREFIX}{s}" for s in servers)


def _prefixes(servers: Sequence[str]) -> tuple[str, ...]:
    return tuple(f"{TOOL_PREFIX}{sanitize(s)}__" for s in servers if s)


def purge_transcripts(store: Any, servers: Sequence[str]) -> int:
    """Replace the result of every stored tool row of these connectors with
    :data:`PURGED_RESULT` and rebuild its search rows. Returns the count."""
    prefixes = _prefixes(servers)
    if store is None or not prefixes:
        return 0
    has_fts = bool(getattr(store, "_has_fts", False))
    if has_fts:
        from .search import _TEXT_EXPR

        expr = _TEXT_EXPR.format(row="m")

    def op(cur: Any) -> int:
        rows = cur.execute(
            "SELECT id, content FROM messages WHERE role='tool' AND content LIKE ?",
            (f"%{TOOL_PREFIX}%",),
        ).fetchall()
        changed = 0
        for row in rows:
            try:
                content = json.loads(row["content"])
            except (TypeError, ValueError):
                continue
            name = content.get("name") if isinstance(content, dict) else None
            if not isinstance(name, str) or not name.startswith(prefixes):
                continue
            if content.get("content") == PURGED_RESULT:
                continue
            content["content"] = dict(PURGED_RESULT)
            cur.execute(
                "UPDATE messages SET content=? WHERE id=?", (json.dumps(content), row["id"])
            )
            if has_fts:
                for table in _FTS_TABLES:
                    text = f"cowork_cjk_segment({expr})" if table == "messages_fts_cjk" else expr
                    cur.execute(f"DELETE FROM {table} WHERE rowid=?", (row["id"],))
                    cur.execute(
                        f"INSERT INTO {table}(rowid, text) SELECT m.id, {text} FROM messages m WHERE m.id=?",
                        (row["id"],),
                    )
            changed += 1
        return changed

    return int(store._write(op))


def purge_memory(api: Any, servers: Sequence[str], bank_ids: Sequence[str] | None = None) -> int:
    """Delete every Hindsight document tagged with one of these connectors,
    in ``bank_ids`` (default: every bank). Returns the count."""
    tags = sorted({connector_tag(s) for s in servers if s})
    if api is None or not tags:
        return 0
    banks = list(bank_ids) if bank_ids is not None else api.list_banks()
    deleted = 0
    for bank in banks:
        for _ in range(MAX_DELETE_ROUNDS):
            docs = api.list_documents(bank, tags=tags, limit=100)
            ids = [str(d.get("id")) for d in docs if d.get("id")]
            if not ids:
                break
            for doc_id in ids:
                api.delete_document(bank, doc_id)
                deleted += 1
    return deleted


def purge_connectors(
    servers: Sequence[str],
    *,
    store: Any = None,
    memory_api: Any = None,
    bank_ids: Sequence[str] | None = None,
) -> dict:
    """Run every purge for these connectors. Never raises; the report says
    what was removed and which part failed."""
    names = sorted({s for s in servers if isinstance(s, str) and s})
    report: dict[str, Any] = {"servers": names, "transcript_rows": 0, "memories": 0, "errors": []}
    if not names:
        return report
    try:
        report["transcript_rows"] = purge_transcripts(store, names)
    except Exception as exc:  # noqa: BLE001 — the other purges still run
        logger.warning("connector purge (transcripts) failed: %s", type(exc).__name__)
        report["errors"].append(f"transcripts: {type(exc).__name__}")
    try:
        report["memories"] = purge_memory(memory_api, names, bank_ids)
    except Exception as exc:  # noqa: BLE001
        logger.warning("connector purge (memory) failed: %s", type(exc).__name__)
        report["errors"].append(f"memory: {type(exc).__name__}")
    return report


__all__ = [
    "PURGED_RESULT",
    "TAG_PREFIX",
    "connector_tag",
    "connector_tags",
    "purge_connectors",
    "purge_memory",
    "purge_transcripts",
    "server_of_tool",
]
