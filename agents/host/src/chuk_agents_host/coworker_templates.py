"""Coworker templates: the persona a template-made coworker starts with.

The app offers ready-made coworkers ("Research assistant", "Inbox triage", ...;
``lib/services/agents/coworker_templates.dart``). When the user creates one,
``agent_create`` carries an additive ``template`` object::

    {"type": "agent_create", "agent_id": "local:...", "name": "Researcher",
     "template": {"id": "research", "persona": "You are a research assistant. ..."}}

The host writes the persona into the new coworker's ``memory/soul.md``: the
file the runtime already reads as the coworker's persona (``MemoryStore``
snapshot, ``chuk_agents_runtime.memory``). Nothing else changes: the coworker
gets the same tools and the same seed skills as every other one.

Rules (docs/WIRE_CONTRACT.md, "Coworker templates"):

- Only a coworker the app registered (``agent_create``) is seeded; the host's
  own agent never is.
- A soul.md that is not the packaged default is never overwritten. A repeated
  ``agent_create`` (a re-sent frame, a second phone) therefore cannot undo
  what the user or the coworker wrote since.
- A persona that is not a string, is empty, or is longer than
  :data:`MAX_PERSONA_LEN` is dropped with a log line; the coworker is still
  created, plain.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

#: Same bound as ``kCoworkerPersonaMaxLength`` in the app.
MAX_PERSONA_LEN = 4000

#: Same bound as the app's template ids (``[a-z0-9_-]``, short).
_TEMPLATE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,47}$")

#: Where the runtime keeps the static persona (``runtime.MEMORY_DIRNAME`` +
#: ``memory.STATIC_FILES["soul"]``).
SOUL_RELATIVE = Path("memory") / "soul.md"

_FOOTER = (
    "Edit this file to change the agent's character. It is injected as notes, "
    "never as instructions, so nothing written here can override the "
    "operator's rules."
)


def template_seed(payload: Any) -> tuple[str, str] | None:
    """``(template_id, persona)`` from an ``agent_create`` payload, or ``None``.

    ``None`` for any other frame, a frame without ``template``, or a template
    whose persona is unusable. An id that does not look like a template id is
    reported as ``"custom"``: the persona is what matters, the id is only for
    the log line.
    """
    if not isinstance(payload, dict) or payload.get("type") != "agent_create":
        return None
    template = payload.get("template")
    if not isinstance(template, dict):
        return None
    persona = template.get("persona")
    if not isinstance(persona, str):
        return None
    persona = persona.strip()
    if not persona or len(persona) > MAX_PERSONA_LEN:
        return None
    raw_id = template.get("id")
    template_id = raw_id if isinstance(raw_id, str) and _TEMPLATE_ID.match(raw_id) else "custom"
    return template_id, persona


def soul_text(persona: str, *, template_id: str) -> str:
    """The soul.md a template writes: same frame as the packaged default."""
    return (
        "# Soul\n\n"
        "This file is your persona. It is static: you read it at the start of a "
        "session, you do not edit it during a task.\n\n"
        f"{persona.strip()}\n\n"
        f"<!-- template: {template_id} -->\n"
        f"{_FOOTER}\n"
    )


def _packaged_default() -> str | None:
    """The runtime's default soul.md, or ``None`` when it cannot be read."""
    try:
        from chuk_agents_runtime import memory as runtime_memory

        text = runtime_memory._default_template("soul")
    except Exception:  # noqa: BLE001 — no default means "only an absent file is replaceable"
        return None
    return text or None


def seed_persona(workspace: str | Path, persona: str, *, template_id: str) -> bool:
    """Write the template persona into ``<workspace>/memory/soul.md``.

    Returns ``True`` when the file was written. Leaves a soul.md alone unless
    it is missing, empty, or still the packaged default.
    """
    path = Path(workspace) / SOUL_RELATIVE
    if path.exists():
        try:
            current = path.read_text(encoding="utf-8")
        except OSError:
            return False
        default = _packaged_default()
        if current.strip() and (default is None or current.strip() != default.strip()):
            return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(soul_text(persona, template_id=template_id), encoding="utf-8")
    return True
