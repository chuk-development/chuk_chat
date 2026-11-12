"""Agent housekeeping from the command line: ``agents-host agents list`` and
``agents-host agents delete`` (docs/WIRE_CONTRACT.md, "Agent names").

The list shows every agent the host knows, with what it takes to decide
whether it is still in use: created date, message count, last activity and
the automations that still run.

A delete goes through the same name store as an app ``agent_delete``: the
name goes, the id is written to the ``coworker_deleted`` table, and every
app drops the agent at its next ``agent_list`` (each pairing asks for one).
The agent's automations are set to ``done`` so nothing fires for it again.
``--purge`` also removes its workspace and its message history; make a
backup first, nothing can bring them back.

This runs next to a live host: every write is one short SQLite transaction
on the host's own files, the same files the host writes.
"""

from __future__ import annotations

import shutil
import sqlite3
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .coworker_names import CoworkerNameStore, host_agent_id
from .identity import HOST_DEVICE_ID

ROSTER_FILE = "roster.db"
STATE_FILE = "executor-state.db"


@dataclass(frozen=True, slots=True)
class AgentRow:
    agent_id: str
    name: str
    created_at: str  # when the name was last set (coworker_names.updated_at)
    messages: int
    last_activity: str
    active_automations: list[str]


def _iso(ts: float | None) -> str:
    if not ts:
        return ""
    return datetime.fromtimestamp(ts, UTC).isoformat(timespec="seconds")


def _state(state_dir: Path) -> sqlite3.Connection | None:
    path = state_dir / STATE_FILE
    if not path.exists():
        return None
    conn = sqlite3.connect(str(path), timeout=10.0)
    conn.row_factory = sqlite3.Row
    return conn


def list_agents(state_dir: str | Path, *, device_id: str = HOST_DEVICE_ID) -> list[AgentRow]:
    """Every agent the host keeps a name for, plus the host's own agent."""
    state_dir = Path(state_dir)
    names = CoworkerNameStore(str(state_dir / ROSTER_FILE), device_id=device_id)
    try:
        rows = {row["agent_id"]: row["name"] for row in names.list()}
        with names._lock:  # noqa: SLF001 — read-only peek at the timestamps
            created = {
                r["agent_id"]: r["updated_at"]
                for r in names._conn.execute(  # noqa: SLF001
                    "SELECT agent_id, updated_at FROM coworker_names"
                )
            }
    finally:
        names.close()
    rows.setdefault(host_agent_id(device_id), "")
    conn = _state(state_dir)
    out: list[AgentRow] = []
    for agent_id, name in rows.items():
        messages, last, automations = 0, None, []
        if conn is not None:
            stats = conn.execute(
                "SELECT COUNT(m.id) AS n, MAX(m.created_at) AS last FROM session_routes r "
                "LEFT JOIN messages m ON m.session_id = r.session_id WHERE r.session_key = ?",
                (agent_id,),
            ).fetchone()
            messages, last = int(stats["n"] or 0), stats["last"]
            automations = [
                f"{a['name']} ({a['state']})"
                for a in conn.execute(
                    "SELECT name, state FROM automations WHERE session_key = ? "
                    "AND state IN ('active', 'paused')",
                    (agent_id,),
                )
            ]
        out.append(
            AgentRow(
                agent_id=agent_id,
                name=name,
                created_at=created.get(agent_id, ""),
                messages=messages,
                last_activity=_iso(last),
                active_automations=automations,
            )
        )
    if conn is not None:
        conn.close()
    return out


def _workspace_dirs(state_dir: Path, agent_id: str) -> list[Path]:
    """The agent's workspace: ``agents/<dirname of its id>`` (host.py,
    ``_agent_dirname``). Looked up, not rebuilt, so an older naming scheme
    is found too."""
    from .host import _agent_dirname  # the one place the name is made

    agents_dir = state_dir / "agents"
    found = [agents_dir / _agent_dirname(agent_id)]
    return [path for path in found if path.is_dir()]


def delete_agent(
    state_dir: str | Path,
    agent_id: str,
    *,
    purge: bool = False,
    device_id: str = HOST_DEVICE_ID,
) -> dict:
    """Delete ``agent_id`` on this host. The host's own agent is refused."""
    state_dir = Path(state_dir)
    if not agent_id or agent_id == host_agent_id(device_id):
        return {"ok": False, "error": "the host's own agent cannot be deleted"}
    names = CoworkerNameStore(str(state_dir / ROSTER_FILE), device_id=device_id)
    try:
        changed = names.delete(agent_id)
    finally:
        names.close()
    result: dict = {"ok": True, "agent_id": agent_id, "name_removed": changed}
    conn = _state(state_dir)
    if conn is not None:
        with conn:
            cur = conn.execute(
                "UPDATE automations SET state = 'done', next_fire_at = NULL, "
                "last_error = 'agent deleted' WHERE session_key = ? "
                "AND state IN ('active', 'paused')",
                (agent_id,),
            )
            result["automations_stopped"] = cur.rowcount
            if purge:
                result["messages_removed"] = _purge_session(conn, agent_id)
        conn.close()
    if purge:
        removed = []
        for path in _workspace_dirs(state_dir, agent_id):
            shutil.rmtree(path)
            removed.append(str(path))
        result["workspaces_removed"] = removed
    result["at"] = time.time()
    return result


def _purge_session(conn: sqlite3.Connection, agent_id: str) -> int:
    """Remove the agent's thread: messages, their search rows and blobs."""
    row = conn.execute(
        "SELECT session_id FROM session_routes WHERE session_key = ?", (agent_id,)
    ).fetchone()
    if row is None:
        return 0
    sid = row["session_id"]
    ids = [r["id"] for r in conn.execute("SELECT id FROM messages WHERE session_id = ?", (sid,))]
    tables = {
        r["name"]
        for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    for start in range(0, len(ids), 500):
        chunk = ids[start : start + 500]
        marks = ",".join("?" * len(chunk))
        for fts in ("messages_fts", "messages_fts_cjk", "messages_fts_tri"):
            if fts in tables:
                conn.execute(f"DELETE FROM {fts} WHERE rowid IN ({marks})", chunk)
        if "event_blobs" in tables:
            conn.execute(f"DELETE FROM event_blobs WHERE message_id IN ({marks})", chunk)
        conn.execute(f"DELETE FROM messages WHERE id IN ({marks})", chunk)
    if "context_summaries" in tables:
        conn.execute("DELETE FROM context_summaries WHERE session_id = ?", (sid,))
    if "session_features" in tables:
        conn.execute("DELETE FROM session_features WHERE session_key = ?", (agent_id,))
    if "runs" in tables:
        conn.execute("DELETE FROM runs WHERE session_id = ?", (sid,))
    if "chat_documents" in tables:
        conn.execute("DELETE FROM chat_documents WHERE session_key = ?", (agent_id,))
    conn.execute("DELETE FROM session_routes WHERE session_key = ?", (agent_id,))
    return len(ids)
