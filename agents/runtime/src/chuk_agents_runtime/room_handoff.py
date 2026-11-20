"""``hand_off_tasks``: the lead of a group gives tasks to members (§16.1).

A group in lead mode (``chuk_agents_manager.room_lead``) lets one member lead.
That member's run gets this tool. The executor binds it to the running
exchange; the host runs the tasks after the lead's turn ends and wakes the lead
once with the results. Only a lead's run in a group ever has it: ``None`` (a
one-to-one chat, a plain member, a child run) registers nothing.

The caps (tasks per user message, lead turns) live in the backend, which
refuses an over-cap task with a reason the model can act on.
"""

from __future__ import annotations

from typing import Protocol

from .registry import ToolRegistry

HAND_OFF_SCHEMA = {
    "type": "object",
    "description": (
        "Give tasks to members of your group. One self-contained task per "
        "member: say what to do and what to report back. Put all independent "
        "tasks in ONE call; they run at the same time when your turn ends. "
        "After the call, end your turn with one short line to the user. You "
        "are woken once with the members' results."
    ),
    "properties": {
        "tasks": {
            "type": "array",
            "minItems": 1,
            "items": {
                "type": "object",
                "properties": {
                    "member": {
                        "type": "string",
                        "description": "The member's handle, without @.",
                    },
                    "task": {
                        "type": "string",
                        "description": "The whole task, readable on its own.",
                    },
                },
                "required": ["member", "task"],
            },
        }
    },
    "required": ["tasks"],
}


class HandoffBackend(Protocol):
    """What the tool needs from the running group exchange."""

    def members(self) -> list[dict]: ...

    def hand_off(self, tasks: object) -> dict: ...


def register_handoff_tools(registry: ToolRegistry, backend: HandoffBackend | None) -> None:
    """Register ``hand_off_tasks`` for a lead's run. ``None`` registers nothing."""
    if backend is None:
        return

    def hand_off_tasks(tasks: list) -> dict:
        try:
            return backend.hand_off(tasks)
        except Exception as exc:  # noqa: BLE001 — a tool error, not a dead run
            return {"ok": False, "error": f"{type(exc).__name__}"}

    registry.register("hand_off_tasks", HAND_OFF_SCHEMA, hand_off_tasks)
