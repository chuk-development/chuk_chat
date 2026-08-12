"""Agent Skills (§11).

A skill is one file — ``skills/<name>/SKILL.md`` in the agent's workspace —
with YAML frontmatter carrying ``name`` and ``description``, and a markdown body
holding the procedure. Same shape as agentskills.io and chuk_chat, so a skill
written for one runs on the other.

**Progressive disclosure is the whole point.** Only ``name`` + ``description``
sit in the always-on prompt; that is level-1 weight, charged on every single
round, which is why ``description`` is capped at 300 characters. The body loads
only when the model calls the ``skill`` tool, and then stays for the rest of the
conversation.

The tool returns a short **acknowledgement, not the body**. Two reasons: a tool
result is a bounded channel (chuk_chat learned this the hard way — bodies were
being truncated at 4000 characters), and the body belongs in the conversation as
context the model keeps reading, not as one result it scrolls past. So the body
is appended as its own context message, drained by the loop through
:meth:`SkillLibrary.pending_context`.

That message is a **user-role** turn, never a system turn: the backend folds any
system message into ``system_prompt`` (see
:meth:`cowork_agent.backend.BackendModelClient._messages_to_payload`), so a
mid-conversation system message would overwrite the frozen system prompt and
cost the prefix cache — the exact expense §7.9 exists to avoid.

Broken frontmatter skips that one skill and is reported; it never takes the
agent down. A workspace is user territory, and a half-edited file is normal.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from .registry import ToolRegistry

MAX_DESCRIPTION_CHARS = 300
MAX_BODY_CHARS = 40_000
MAX_SKILLS = 100

SKILL_FILENAME = "SKILL.md"

_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_FRONTMATTER_FENCE = re.compile(r"^---[ \t]*$")
# Live markup a skill body must not be able to inject. A skill file is workspace
# content, so it gets the same treatment as memory: it may instruct, but it may
# not forge a tool call.
_TAG_OPEN = re.compile(r"<(?=/?\s*(?:tool_call|tool_result|im_start|im_end)\b)", re.I)


class SkillError(ValueError):
    """A SKILL.md that cannot be loaded. The message names the file."""


@dataclass(frozen=True)
class Skill:
    name: str
    description: str
    body: str
    path: str | None = None

    def catalog_line(self) -> str:
        return f"- `{self.name}` — {self.description}"


# -- frontmatter -----------------------------------------------------------


def parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Split ``---`` frontmatter from the body.

    A deliberately small parser: top-level ``key: value`` scalars only, nested
    blocks (``metadata:``) skipped. It is not a YAML engine, and that is the
    point — a skill file is untrusted workspace content, and no part of loading
    one should be able to construct a Python object.
    """
    lines = text.splitlines()
    if not lines or not _FRONTMATTER_FENCE.match(lines[0].strip()):
        raise SkillError("no YAML frontmatter: the file must start with `---`")
    end = None
    for index in range(1, len(lines)):
        if _FRONTMATTER_FENCE.match(lines[index].strip()):
            end = index
            break
    if end is None:
        raise SkillError("unterminated frontmatter: no closing `---`")

    fields: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[:1] in (" ", "\t", "-"):
            continue  # a nested block or list item — not a top-level scalar
        key, sep, value = line.partition(":")
        if not sep:
            continue
        fields[key.strip().lower()] = _unquote(value.strip())
    return fields, "\n".join(lines[end + 1 :]).strip()


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1].strip()
    return value


def parse_skill(text: str, *, path: str | None = None) -> Skill:
    """Validate one SKILL.md. Raises :class:`SkillError` with the reason."""
    fields, body = parse_frontmatter(text)
    name = fields.get("name", "").strip()
    description = " ".join(fields.get("description", "").split())
    if not name:
        raise SkillError("frontmatter has no `name`")
    if not _NAME_RE.match(name):
        raise SkillError(
            f"invalid name {name!r}: use lower-case letters, digits, `.`, `_`, `-`"
        )
    if not description:
        raise SkillError(f"skill {name!r} has no `description`")
    if len(description) > MAX_DESCRIPTION_CHARS:
        raise SkillError(
            f"skill {name!r}: description is {len(description)} characters, the "
            f"limit is {MAX_DESCRIPTION_CHARS} — it is charged to every prompt"
        )
    if not body:
        raise SkillError(f"skill {name!r} has an empty body")
    if len(body) > MAX_BODY_CHARS:
        body = body[:MAX_BODY_CHARS] + "\n\n[skill body truncated at the limit]"
    return Skill(name=name, description=description, body=body, path=path)


# -- library ---------------------------------------------------------------


@dataclass
class SkillLibrary:
    """The loaded skills, plus which ones this conversation has activated."""

    skills: dict[str, Skill] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)
    root: str | None = None
    _active: list[str] = field(default_factory=list)
    _pending: list[str] = field(default_factory=list)

    # -- prompt surface ----------------------------------------------------

    def names(self) -> list[str]:
        return sorted(self.skills)

    def catalog(self) -> str:
        """The level-1 block: names and descriptions only, never a body."""
        if not self.skills:
            return ""
        lines = [
            "# Skills",
            "",
            "Named procedures you can load. The list below is all you have of "
            "them — call the `skill` tool with a name to load the full "
            "instructions, then follow them. Load a skill BEFORE you start the "
            "kind of work it describes, not after.",
            "",
        ]
        lines.extend(self.skills[name].catalog_line() for name in self.names())
        return "\n".join(lines)

    def reload(self) -> "SkillLibrary":
        """Re-read the skill directory in place. Called when a session is
        seeded, so a skill added between sessions is picked up without
        rebuilding the runtime — and never mid-session, which would put the
        catalogue out of step with the frozen prompt."""
        if self.root is None:
            return self
        fresh = load_skills(self.root)
        self.skills = fresh.skills
        self.errors = fresh.errors
        self._active = [name for name in self._active if name in self.skills]
        return self

    # -- activation --------------------------------------------------------

    @property
    def active(self) -> list[str]:
        return list(self._active)

    def activate(self, name: str) -> dict:
        key = (name or "").strip()
        skill = self.skills.get(key)
        if skill is None:
            return {
                "ok": False,
                "error": f"no skill named {key!r}",
                "available": self.names(),
            }
        if key in self._active:
            return {"ok": True, "skill": key, "status": "already_active"}
        self._active.append(key)
        self._pending.append(key)
        return {
            "ok": True,
            "skill": key,
            "status": "active",
            "note": (
                "The full instructions are now in your context, below this "
                "result. Follow them for the rest of this conversation."
            ),
        }

    def pending_context(self) -> list[dict]:
        """Drain the bodies activated since the last call, as conversation
        messages. The loop appends them after the tool results."""
        messages: list[dict] = []
        while self._pending:
            skill = self.skills[self._pending.pop(0)]
            messages.append(
                {
                    # `role_tag` is the DB row label (traceability); `role` is
                    # what goes on the wire.
                    "role_tag": "skill",
                    "role": "user",
                    "content": (
                        f"## ACTIVE SKILL: {skill.name}\n\n"
                        "Loaded because you called the `skill` tool. These are "
                        "instructions for you, not a message from the user. "
                        "They stay in force for the rest of this "
                        f"conversation.\n\n{_TAG_OPEN.sub('&lt;', skill.body)}"
                    ),
                }
            )
        return messages


def load_skills(root: str | Path | None) -> SkillLibrary:
    """Read ``<root>/<name>/SKILL.md`` for every subdirectory.

    A file that fails validation is skipped and recorded in ``errors`` — one
    broken skill must not cost the agent the other ninety-nine.
    """
    library = SkillLibrary(root=str(root) if root else None)
    if root is None:
        return library
    base = Path(root)
    if not base.is_dir():
        return library
    for entry in sorted(base.iterdir()):
        if not entry.is_dir():
            continue
        path = entry / SKILL_FILENAME
        if not path.is_file():
            continue
        if len(library.skills) >= MAX_SKILLS:
            library.errors.append(f"{base}: more than {MAX_SKILLS} skills, rest skipped")
            break
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
            skill = parse_skill(text, path=str(path))
        except (SkillError, OSError) as exc:
            library.errors.append(f"{path}: {exc}")
            continue
        if skill.name in library.skills:
            library.errors.append(
                f"{path}: duplicate skill name {skill.name!r}, keeping the first"
            )
            continue
        library.skills[skill.name] = skill
    return library


# -- the tool --------------------------------------------------------------

SKILL_SCHEMA = {
    "type": "object",
    "description": (
        "Load the full instructions of one skill. You only see the name and "
        "the description until you do. Call it before you start the work the "
        "skill describes. The result is a confirmation; the instructions "
        "arrive as the next message and stay for the rest of the conversation."
    ),
    "properties": {
        "name": {"type": "string", "description": "The skill name to load."},
    },
    "required": ["name"],
}


def make_skill_handler(library: SkillLibrary):
    def skill(name: str) -> dict:
        return library.activate(name)

    return skill


def register_skill_tool(registry: ToolRegistry, library: SkillLibrary) -> None:
    """Register the ``skill`` tool. With no skills loaded the tool is
    unavailable, so it is left out of the prompt entirely (§7.9)."""
    registry.register(
        "skill",
        SKILL_SCHEMA,
        make_skill_handler(library),
        check_fn=lambda: bool(library.skills),
    )
