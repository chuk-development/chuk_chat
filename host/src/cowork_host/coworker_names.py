"""Coworker names the host keeps for the app (docs/WIRE_CONTRACT.md,
"Coworker names", bead cowork-817).

The app's roster is in memory; a reinstall forgets every coworker the user
created and every name they chose. This store keeps ``(agent_id, name)`` keyed
by the APP's agent id, in the roster's SQLite file, in its own table. It never
touches the ``agents`` row of the running agent: that row's ``name`` is also
the workspace directory, and a rename must never move a workspace.
"""

from __future__ import annotations

import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any, Callable

from .identity import HOST_DEVICE_ID

MAX_NAME_LEN = 80

_SCHEMA = """
CREATE TABLE IF NOT EXISTS coworker_names (
    agent_id       TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    created_by_app INTEGER NOT NULL DEFAULT 0,
    updated_at     TEXT NOT NULL
);
"""


def host_agent_id(device_id: str = HOST_DEVICE_ID) -> str:
    """The app's id for the coworker that runs on this host: ``host:<device id>``
    (the ``peer_device_id`` the app sees on pairing)."""
    return f"host:{device_id}"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class CoworkerNameStore:
    """SQLite-backed ``coworker_names`` table. Safe to call from any thread:
    the executor's serve thread answers the frames, the host opens the store."""

    def __init__(self, path: str = ":memory:", *, device_id: str = HOST_DEVICE_ID) -> None:
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.executescript(_SCHEMA)
        self._conn.commit()
        self._lock = threading.Lock()
        self._host_id = host_agent_id(device_id)

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    @property
    def host_id(self) -> str:
        return self._host_id

    def upsert(self, agent_id: str, name: str, *, created_by_app: bool) -> bool:
        """Set ``name`` for ``agent_id``. Returns True when a row changed."""
        with self._lock:
            row = self._conn.execute(
                "SELECT name FROM coworker_names WHERE agent_id = ?", (agent_id,)
            ).fetchone()
            if row is not None and row["name"] == name:
                return False
            if row is None:
                self._conn.execute(
                    "INSERT INTO coworker_names (agent_id, name, created_by_app, updated_at)"
                    " VALUES (?, ?, ?, ?)",
                    (agent_id, name, 1 if created_by_app else 0, _now_iso()),
                )
            else:
                self._conn.execute(
                    "UPDATE coworker_names SET name = ?, updated_at = ? WHERE agent_id = ?",
                    (name, _now_iso(), agent_id),
                )
            self._conn.commit()
            return True

    def list(self) -> list[dict[str, Any]]:
        """The ``agent_list`` entries, ``updated_at`` ascending."""
        with self._lock:
            rows = self._conn.execute(
                "SELECT agent_id, name FROM coworker_names ORDER BY updated_at, agent_id"
            ).fetchall()
        return [
            {
                "agent_id": row["agent_id"],
                "name": row["name"],
                "host": row["agent_id"] == self._host_id,
            }
            for row in rows
        ]


def clean_name(value: object) -> str | None:
    """The name as the contract accepts it: a string, trimmed, 1..80 chars."""
    if not isinstance(value, str):
        return None
    name = value.strip()
    if not name or len(name) > MAX_NAME_LEN:
        return None
    return name


def handle_agent_frame(
    store: CoworkerNameStore,
    payload: dict,
    *,
    log: Callable[[str], None] | None = None,
) -> list[dict[str, Any]]:
    """Apply one ``agent_create`` / ``agent_rename`` / ``agent_list`` payload
    and return the current list (the executor sends it as ``agent_list``). A
    bad create/rename is dropped with a log line; the list is still answered."""
    kind = payload.get("type") if isinstance(payload, dict) else None
    if kind in ("agent_create", "agent_rename"):
        agent_id = payload.get("agent_id")
        name = clean_name(payload.get("name"))
        if not isinstance(agent_id, str) or not agent_id or name is None:
            if log is not None:
                log(f"[coworker-names] dropped {kind}: bad agent_id or name")
        elif store.upsert(agent_id, name, created_by_app=(kind == "agent_create")):
            if log is not None:
                log(f"[coworker-names] {agent_id} -> {name!r}")
    return store.list()
