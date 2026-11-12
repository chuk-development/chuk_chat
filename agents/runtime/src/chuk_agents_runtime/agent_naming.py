"""Self-naming: an agent gives itself a display name (``rename_self``).

The agent-side half of docs/WIRE_CONTRACT.md, "Agent names". The name is a
label the user reads in the app's roster; it is never the workspace or the
agent id. The executor binds a backend to the run's own agent id, so a model
can only ever rename itself, and stores the name through the same host path
as a rename in the app: the host's name store, then an ``agent_list`` push to
every attached app, so each roster shows the new name at once.

The behaviour lives in the prompt (:func:`naming_prompt_section`): a new
agent proposes a name early and asks; later it may suggest a new one when its
job clearly changed. It renames only after the user agreed, or when the user
asked for it. Never silently.
"""

from __future__ import annotations

import re
from typing import Any, Protocol

from .registry import ToolRegistry

#: The same limit as the host's name store (``coworker_names.MAX_NAME_LEN``).
MAX_NAME_LEN = 80

#: Names the roster gives an agent before anyone chose one: the host's
#: generic label and the app's random two-word codenames ("saffron-osprey").
_GENERIC_NAMES = frozenset({"your computer", "agent", "new agent", "coworker"})
_CODENAME = re.compile(r"^[a-z]+-[a-z]+$")

RENAME_SELF_SCHEMA = {
    "type": "object",
    "description": (
        "Change your own display name, the name the user sees for you in the "
        "agent list on every device. Call it ONLY after the user agreed to the "
        "name you proposed, or when the user told you to take a name. Never "
        "rename yourself on your own. Use a short name that says what you do, "
        "e.g. 'Mail', 'Price Watch', 'Wahlradar'."
    ),
    "properties": {
        "name": {
            "type": "string",
            "description": f"The new name. 1 to {MAX_NAME_LEN} characters, no line breaks.",
        },
    },
    "required": ["name"],
}


class AgentNamingBackend(Protocol):
    """What the executor binds to one agent."""

    def current_name(self) -> str | None:
        """The name the user sees now, or ``None`` when none is known."""

    def rename(self, name: str) -> dict:
        """Store ``name``; ``{"ok": True, "name": ...}`` or ``{"ok": False, "error": ...}``."""


def clean_name(value: Any) -> str | None:
    """``value`` as a valid display name, or ``None``: a string, whitespace
    folded to single spaces, 1..:data:`MAX_NAME_LEN` characters."""
    if not isinstance(value, str):
        return None
    name = " ".join(value.split())
    if not name or len(name) > MAX_NAME_LEN:
        return None
    return name


def is_placeholder_name(name: str | None) -> bool:
    """Whether ``name`` is one nobody chose: empty, the generic label, or a
    random roster codename such as ``saffron-osprey``."""
    if not name or not name.strip():
        return True
    text = name.strip()
    return text.lower() in _GENERIC_NAMES or bool(_CODENAME.match(text))


def naming_prompt_section(current_name: str | None) -> str:
    """The prompt block that tells the agent its name and the naming rules."""
    shown = (current_name or "").strip()
    head = f'Your name in the app is "{shown}".' if shown else "You have no name in the app yet."
    lines = [
        "# Your name",
        "",
        head,
    ]
    if is_placeholder_name(current_name):
        lines.append(
            "- Nobody chose this name. As soon as you know what your job is "
            "(usually after the first task), propose one short name that says "
            "what you do, and ask the user if it is OK. Ask only once."
        )
    lines += [
        "- Rename yourself with `rename_self` only after the user agreed to "
        "the name, or when the user tells you to take a name. Never rename "
        "yourself silently.",
        "- If your job later changes clearly, you may suggest a new name once "
        "and ask first. If the user says no, keep the name.",
    ]
    return "\n".join(lines)


def make_rename_self_handler(backend: AgentNamingBackend):
    def rename_self(name: str) -> dict:
        new = clean_name(name)
        if new is None:
            return {
                "ok": False,
                "error": f"name must be 1 to {MAX_NAME_LEN} characters of text",
            }
        current = backend.current_name()
        if current is not None and current.strip() == new:
            return {"ok": True, "name": new, "unchanged": True}
        result = backend.rename(new)
        if not isinstance(result, dict) or not result.get("ok"):
            message = result.get("error") if isinstance(result, dict) else None
            return {"ok": False, "error": str(message or "the name could not be stored")}
        return {"ok": True, "name": new, "previous": current}

    return rename_self


def register_naming_tools(registry: ToolRegistry, backend: AgentNamingBackend | None) -> None:
    """Register ``rename_self`` for one bound agent. ``None`` (no host, a room
    or a child run) registers nothing."""
    if backend is None:
        return
    # Not deferred: the prompt names the tool, and the schema is small.
    registry.register("rename_self", RENAME_SELF_SCHEMA, make_rename_self_handler(backend))


class RecordingNamingBackend:
    """An in-memory backend for tests."""

    def __init__(self, name: str | None = None, *, fail: str | None = None) -> None:
        self.name = name
        self.fail = fail
        self.renames: list[str] = []

    def current_name(self) -> str | None:
        return self.name

    def rename(self, name: str) -> dict:
        if self.fail:
            return {"ok": False, "error": self.fail}
        self.renames.append(name)
        self.name = name
        return {"ok": True, "name": name}
