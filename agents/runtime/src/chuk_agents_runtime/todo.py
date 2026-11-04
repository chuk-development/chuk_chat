"""``todo_write`` (DeepSeek harness idea 51, docs/WIRE_CONTRACT.md "Todo list").

The agent keeps a short task list for multi-step work. Every call replaces
the WHOLE list (no partial edits, so what the app shows is exactly what the
model believes it wrote). While work remains exactly one item is
``in_progress``; items are unique and non-empty. The latest list is stored
per session (``session_features``, kind ``todo``) and sent to the app as a
``todo`` frame for the sticky card above the composer.
"""

from __future__ import annotations

import time
from typing import Any, Callable

from .registry import ToolRegistry
from .state import StateStore

FEATURE_KIND = "todo"
TODO_WRITE = "todo_write"

STATUSES = ("pending", "in_progress", "completed")
MAX_ITEMS = 50
MAX_ITEM_CHARS = 300

TODO_WRITE_SCHEMA = {
    "type": "object",
    "description": (
        "Record and update a task list for multi-step work; skip it for trivial tasks. "
        "Each call replaces the whole list. While work remains keep exactly one item "
        "in_progress; mark each item completed as soon as it is done."
    ),
    "properties": {
        "todos": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "content": {"type": "string"},
                    "status": {"type": "string", "enum": list(STATUSES)},
                },
                "required": ["content", "status"],
            },
        }
    },
    "required": ["todos"],
}


class TodoError(ValueError):
    pass


def validate_todos(raw: Any) -> list[dict]:
    """The canonical list, or :class:`TodoError` with a text for the model."""
    if isinstance(raw, str):
        import json

        try:
            raw = json.loads(raw)
        except ValueError:
            raise TodoError("todos must be a list of {content, status} items") from None
    if not isinstance(raw, list):
        raise TodoError("todos must be a list of {content, status} items")
    if len(raw) > MAX_ITEMS:
        raise TodoError(f"at most {MAX_ITEMS} items")
    out: list[dict] = []
    seen: set[str] = set()
    for item in raw:
        if not isinstance(item, dict):
            raise TodoError("each todo must be an object with content and status")
        extra = set(item) - {"content", "status"}
        if extra:
            raise TodoError(f"unknown todo field(s): {', '.join(sorted(extra))}")
        content = item.get("content")
        content = " ".join(content.split()) if isinstance(content, str) else ""
        if not content:
            raise TodoError("invalid todo: content must be a non-empty string")
        if len(content) > MAX_ITEM_CHARS:
            raise TodoError(f"invalid todo: content is longer than {MAX_ITEM_CHARS} characters")
        if content in seen:
            raise TodoError(f"invalid todos: duplicate content {content!r}")
        seen.add(content)
        status = item.get("status")
        if status not in STATUSES:
            raise TodoError(f"invalid todo status {status!r}: use {', '.join(STATUSES)}")
        out.append({"content": content, "status": status})
    active = sum(1 for t in out if t["status"] == "in_progress")
    open_items = sum(1 for t in out if t["status"] != "completed")
    if active > 1:
        raise TodoError(f"invalid todos: exactly one item may be in_progress (got {active})")
    if open_items and active == 0:
        raise TodoError(
            "invalid todos: while work remains exactly one item must be in_progress (got 0)"
        )
    return out


def counts(todos: list[dict]) -> dict[str, int]:
    return {status: sum(1 for t in todos if t["status"] == status) for status in STATUSES}


def summary(todos: list[dict]) -> str:
    c = counts(todos)
    return (
        f"Updated todo list: {c['pending']} pending, {c['in_progress']} in progress, "
        f"{c['completed']} completed"
    )


def load_todos(store: StateStore, session_key: str) -> list[dict] | None:
    doc = store.load_feature(session_key, FEATURE_KIND)
    todos = doc.get("todos") if doc else None
    return todos if isinstance(todos, list) else None


def register_todo_tool(
    registry: ToolRegistry,
    store: StateStore | None,
    session_key: str | None,
    sink: Callable[[list[dict]], None] | None = None,
) -> None:
    """``todo_write`` for one session. ``sink`` gets the new list (the
    executor sends the ``todo`` frame). Deferred (prompt budget)."""
    if store is None or not session_key:
        return

    def todo_write(todos: Any = None) -> Any:
        try:
            clean = validate_todos(todos)
        except TodoError as exc:
            return {"ok": False, "error": str(exc)}
        store.save_feature(session_key, FEATURE_KIND, {"todos": clean, "updated_at": time.time()})
        if sink is not None:
            try:
                sink(clean)
            except Exception:  # noqa: BLE001 — a UI sink never fails the call
                pass
        return summary(clean)

    registry.register(TODO_WRITE, TODO_WRITE_SCHEMA, todo_write, deferrable=True)
