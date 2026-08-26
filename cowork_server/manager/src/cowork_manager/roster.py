"""Roster store — the agent registry the Manager owns (§5).

A single-user SQLite table of agents. Each row is a coworker: an auto-assigned
random name, a workspace directory, the persona/job brief, an optional schedule
string (parsed by :mod:`cowork_manager.scheduler`), and its target platform.

CRUD + list. The store owns name assignment so uniqueness is enforced in one
place under the same connection that writes the row.
"""

from __future__ import annotations

import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from cowork_manager.names import random_name

_SCHEMA = """
CREATE TABLE IF NOT EXISTS agents (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    workspace_dir TEXT NOT NULL,
    persona       TEXT NOT NULL DEFAULT '',
    schedule      TEXT NOT NULL DEFAULT '',
    platform      TEXT NOT NULL DEFAULT '',
    created_at    TEXT NOT NULL
);
"""


@dataclass(frozen=True, slots=True)
class Agent:
    """One coworker row in the roster."""

    id: str
    name: str
    workspace_dir: str
    persona: str
    schedule: str
    platform: str
    created_at: str


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class RosterStore:
    """SQLite-backed agent roster.

    Pass ``":memory:"`` for an ephemeral store (tests) or a file path for the
    Manager's persistent roster. The connection is opened once and reused.
    """

    def __init__(self, path: str = ":memory:") -> None:
        self._conn = sqlite3.connect(path)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.executescript(_SCHEMA)
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "RosterStore":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- helpers ---------------------------------------------------------

    def _existing_names(self) -> set[str]:
        rows = self._conn.execute("SELECT name FROM agents").fetchall()
        return {row["name"] for row in rows}

    @staticmethod
    def _row_to_agent(row: sqlite3.Row) -> Agent:
        return Agent(
            id=row["id"],
            name=row["name"],
            workspace_dir=row["workspace_dir"],
            persona=row["persona"],
            schedule=row["schedule"],
            platform=row["platform"],
            created_at=row["created_at"],
        )

    # -- CRUD ------------------------------------------------------------

    def create(
        self,
        *,
        workspace_dir: str,
        persona: str = "",
        schedule: str = "",
        platform: str = "",
        name: str | None = None,
        rng: object | None = None,
    ) -> Agent:
        """Insert a new agent, auto-assigning a unique name if none is given.

        Uniqueness is enforced twice: name generation avoids the names already
        present, and the ``UNIQUE`` constraint is the final authority — a losing
        race raises :class:`sqlite3.IntegrityError`.
        """
        assigned = name or random_name(taken=self._existing_names(), rng=rng)  # type: ignore[arg-type]
        agent = Agent(
            id=uuid.uuid4().hex,
            name=assigned,
            workspace_dir=workspace_dir,
            persona=persona,
            schedule=schedule,
            platform=platform,
            created_at=_now_iso(),
        )
        self._conn.execute(
            "INSERT INTO agents "
            "(id, name, workspace_dir, persona, schedule, platform, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                agent.id,
                agent.name,
                agent.workspace_dir,
                agent.persona,
                agent.schedule,
                agent.platform,
                agent.created_at,
            ),
        )
        self._conn.commit()
        return agent

    def get(self, agent_id: str) -> Agent | None:
        row = self._conn.execute(
            "SELECT * FROM agents WHERE id = ?", (agent_id,)
        ).fetchone()
        return self._row_to_agent(row) if row else None

    def get_by_name(self, name: str) -> Agent | None:
        row = self._conn.execute(
            "SELECT * FROM agents WHERE name = ?", (name,)
        ).fetchone()
        return self._row_to_agent(row) if row else None

    def list(self) -> list[Agent]:
        rows = self._conn.execute(
            "SELECT * FROM agents ORDER BY created_at, id"
        ).fetchall()
        return [self._row_to_agent(row) for row in rows]

    def update(
        self,
        agent_id: str,
        *,
        workspace_dir: str | None = None,
        persona: str | None = None,
        schedule: str | None = None,
        platform: str | None = None,
    ) -> Agent | None:
        """Patch mutable fields. Name and id are immutable identity."""
        current = self.get(agent_id)
        if current is None:
            return None

        updated = Agent(
            id=current.id,
            name=current.name,
            workspace_dir=(
                workspace_dir if workspace_dir is not None else current.workspace_dir
            ),
            persona=persona if persona is not None else current.persona,
            schedule=schedule if schedule is not None else current.schedule,
            platform=platform if platform is not None else current.platform,
            created_at=current.created_at,
        )
        self._conn.execute(
            "UPDATE agents SET workspace_dir = ?, persona = ?, schedule = ?, "
            "platform = ? WHERE id = ?",
            (
                updated.workspace_dir,
                updated.persona,
                updated.schedule,
                updated.platform,
                updated.id,
            ),
        )
        self._conn.commit()
        return updated

    def delete(self, agent_id: str) -> bool:
        cur = self._conn.execute("DELETE FROM agents WHERE id = ?", (agent_id,))
        self._conn.commit()
        return cur.rowcount > 0
