"""Journaling registry + the agent-facing undo tools (§7.7).

``dispatch`` is the one point every tool call passes through, so journaling
belongs there and nowhere else: a new tool is audited the day it is registered,
with no second place to remember. :class:`JournalingRegistry` is a drop-in
:class:`~cowork_agent.registry.ToolRegistry` that records each call — name,
redacted arguments, capped result — into the git-versioned workspace.

The same history is exposed to the agent as two tools, so it can inspect and
repair its own work instead of asking the user to. ``workspace_undo`` is
deliberately blunt (a whole commit, not a hand-picked file): a partial restore is
how you end up with a tree that never existed.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from .registry import ToolRegistry
from .workspace_git import GitWorkspace, timed_record

#: An observer of every dispatch: ``(name, args, result)``. One place, for the
#: same reason journaling lives here — a live feed that is wired per tool goes
#: stale the first time a tool is added.
ToolObserver = Callable[[str, "dict | None", Any], None]

WORKSPACE_HISTORY_SCHEMA = {
    "type": "object",
    "description": (
        "List the workspace history: one entry per action you took, newest "
        "first, with the commit id you can roll back to."
    ),
    "properties": {
        "limit": {
            "type": "integer",
            "description": "How many entries to return.",
            "default": 20,
        },
    },
    "required": [],
}

WORKSPACE_UNDO_SCHEMA = {
    "type": "object",
    "description": (
        "Undo your own work: restore the workspace files to how they were "
        "before the last N actions, or at a commit from workspace_history. "
        "The undo is recorded as a new commit and the action journal is kept, "
        "so nothing is erased. It restores FILES ONLY — a sent mail, an API "
        "call or a change on the host is not undone."
    ),
    "properties": {
        "actions": {
            "type": "integer",
            "description": "Number of recent actions to undo.",
            "default": 1,
        },
        "commit": {
            "type": "string",
            "description": "Commit id to restore instead (from workspace_history).",
        },
    },
    "required": [],
}


class JournalingRegistry(ToolRegistry):
    """A registry that writes every dispatch into the workspace journal.

    Without a workspace (or with one that could not be initialised) it behaves
    exactly like the plain registry — the audit trail is optional, the tool call
    is not.
    """

    def __init__(
        self,
        workspace: GitWorkspace | None = None,
        *,
        observer: ToolObserver | None = None,
    ) -> None:
        super().__init__()
        self._workspace = workspace
        self._observer = observer

    @property
    def workspace(self) -> GitWorkspace | None:
        return self._workspace

    def dispatch(self, name: str, args: dict | None = None) -> Any:
        started = time.perf_counter()
        result = super().dispatch(name, args)
        timed_record(self._workspace, name, args, result, started)
        if self._observer is not None:
            try:
                self._observer(name, args, result)
            except Exception:  # noqa: BLE001 — an observer never fails a call
                pass
        return result


def make_workspace_history_handler(workspace: GitWorkspace):
    def workspace_history(limit: int = 20) -> dict:
        entries = workspace.history(max(1, min(int(limit), 200)))
        return {"ok": True, "commits": [entry.as_dict() for entry in entries]}

    return workspace_history


def make_workspace_undo_handler(workspace: GitWorkspace):
    def workspace_undo(actions: int = 1, commit: str | None = None) -> dict:
        if commit:
            return workspace.rollback(commit=commit)
        return workspace.rollback(actions=max(1, int(actions)))

    return workspace_undo


def register_workspace_tools(
    registry: ToolRegistry, workspace: GitWorkspace | None
) -> None:
    """Register the undo/history pair.

    A disabled workspace registers nothing: a tool that is documented to the
    model but always fails is worse than an absent one.
    """
    if workspace is None or not workspace.enabled:
        return
    registry.register(
        "workspace_history",
        WORKSPACE_HISTORY_SCHEMA,
        make_workspace_history_handler(workspace),
    )
    registry.register(
        "workspace_undo",
        WORKSPACE_UNDO_SCHEMA,
        make_workspace_undo_handler(workspace),
    )
