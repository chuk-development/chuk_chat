"""Agent Skills (§11).

A skill is one file — ``skills/<name>/SKILL.md`` in the agent's workspace —
with YAML frontmatter carrying ``name`` and ``description``, and a markdown body
holding the procedure. Same shape as agentskills.io and chuk_chat, so a skill
written for one runs on the other.

**Progressive disclosure is the whole point.** Only ``name`` + ``description``
sit in the always-on prompt; that is level-1 weight, charged on every single
round, which is why the catalog description is capped at 300 characters.
Source descriptions may contain up to 1024 characters. The body loads
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
:meth:`chuk_agents_runtime.backend.BackendModelClient._messages_to_payload`), so a
mid-conversation system message would overwrite the frozen system prompt and
cost the prefix cache — the exact expense §7.9 exists to avoid.

Broken frontmatter skips that one skill and is reported; it never takes the
agent down. A workspace is user territory, and a half-edited file is normal.

**The user decides which skills the model gets.** The app shows the host's
skill list and switches each one on or off (docs/WIRE_CONTRACT.md, "Skills").
That choice lives in :class:`SkillSettingsStore`, one table in the executor's
state database, and :func:`load_skills` applies it: a switched-off skill stays
on disk, is reported in :attr:`SkillLibrary.disabled`, but never reaches the
catalogue, the ``skill`` tool or the prompt. The default is on — a skill the
user never touched behaves as before.
"""

from __future__ import annotations

import re
import sqlite3
import time
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from pathlib import Path

from .registry import ToolRegistry
from .sqlite_tuning import tune_connection

MAX_DESCRIPTION_CHARS = 1024
MAX_CATALOG_DESCRIPTION_CHARS = 300
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
        description = self.description
        if len(description) > MAX_CATALOG_DESCRIPTION_CHARS:
            description = description[: MAX_CATALOG_DESCRIPTION_CHARS - 1] + "…"
        return f"- `{self.name}` — {description}"


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
            f"limit is {MAX_DESCRIPTION_CHARS}"
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
    #: Skills that load fine but the user switched off. Listed for the app,
    #: never offered to the model.
    disabled: dict[str, Skill] = field(default_factory=dict)
    settings: "SkillSettingsStore | None" = None
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

    def upgrade_catalog(self, prompt: str) -> str:
        """Refresh only the generated catalog in a persisted session prompt.

        A coworker has one permanent session, so its original catalog cannot
        remain authoritative after skills are installed or disabled. Memory
        and operator instructions stay intact; no stored rows are rewritten.
        """
        marker = "# Skills\n\nNamed procedures you can load."
        start = prompt.find(marker)
        catalog = self.catalog()
        if start < 0:
            return prompt if not catalog else prompt.rstrip() + "\n\n" + catalog + "\n"
        end = prompt.find("\n# ", start + len(marker))
        if end < 0:
            end = len(prompt)
        replacement = catalog + "\n" if catalog else ""
        return prompt[:start] + replacement + prompt[end:]

    def reload(self) -> "SkillLibrary":
        """Re-read the skill directory in place. Called when a session is
        seeded, so a skill added between sessions is picked up without
        rebuilding the runtime — and never mid-session, which would put the
        catalogue out of step with the frozen prompt."""
        if self.root is None:
            return self
        fresh = load_skills(self.root, settings=self.settings)
        self.skills = fresh.skills
        self.disabled = fresh.disabled
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
                        "conversation. Relative script and reference paths "
                        "are relative to the skill directory, not the workspace "
                        f"root. Workspace skills live under `skills/{skill.name}/`."
                        f"\n\n{_TAG_OPEN.sub('&lt;', skill.body)}"
                    ),
                }
            )
        return messages


def load_skills(
    root: str | Path | None,
    *,
    settings: "SkillSettingsStore | None" = None,
    disabled: Iterable[str] = (),
) -> SkillLibrary:
    """Read ``<root>/<name>/SKILL.md`` for every subdirectory.

    A file that fails validation is skipped and recorded in ``errors`` — one
    broken skill must not cost the agent the other ninety-nine.

    ``settings`` (or a plain ``disabled`` name set) keeps the user's switches
    out of the catalogue: those skills land in ``library.disabled`` instead of
    ``library.skills``. A settings store that cannot be read counts as "all
    on" — a broken preference must not silently strip the agent of skills.
    """
    library = SkillLibrary(root=str(root) if root else None, settings=settings)
    if root is None:
        return library
    off = set(disabled)
    if settings is not None:
        try:
            off |= settings.disabled()
        except sqlite3.Error as exc:
            library.errors.append(f"skill settings unreadable, all skills on: {exc}")
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
        if skill.name in library.skills or skill.name in library.disabled:
            library.errors.append(
                f"{path}: duplicate skill name {skill.name!r}, keeping the first"
            )
            continue
        if skill.name in off:
            library.disabled[skill.name] = skill
            continue
        library.skills[skill.name] = skill
    return library


# -- the user's switches ---------------------------------------------------


class SkillSettingsStore:
    """Which skills the user switched off, by name.

    One table in the executor's state database (the same file the runs and
    messages live in), so the host, the executor and ``build_runtime`` all read
    one truth. Only ``enabled = 0`` rows matter: an absent row is "on", so a
    skill that appears later starts enabled, and a row for a skill that has
    since been deleted from disk is harmless.

    Connections are opened per call: the store is touched a handful of times
    per session (one read per task, one write per switch), and a connection
    per call is what lets the host's frame thread and the executor's task
    thread share it without a thread-local dance.
    """

    def __init__(self, db_path: str | Path) -> None:
        self._path = str(db_path)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS skill_settings ("
                " name TEXT PRIMARY KEY,"
                " enabled INTEGER NOT NULL DEFAULT 1,"
                " updated_at REAL NOT NULL)"
            )

    def _connect(self) -> sqlite3.Connection:
        conn = tune_connection(sqlite3.connect(self._path, timeout=5.0))
        conn.execute("PRAGMA busy_timeout=5000;")
        return conn

    def disabled(self) -> set[str]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT name FROM skill_settings WHERE enabled = 0"
            ).fetchall()
        return {row[0] for row in rows}

    def is_enabled(self, name: str) -> bool:
        return name not in self.disabled()

    def set_enabled(self, name: str, enabled: bool) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO skill_settings (name, enabled, updated_at)"
                " VALUES (?, ?, ?)"
                " ON CONFLICT(name) DO UPDATE SET"
                " enabled = excluded.enabled, updated_at = excluded.updated_at",
                (name, 1 if enabled else 0, time.time()),
            )

    def close(self) -> None:  # symmetry with the other stores; nothing is held
        return None


# -- the host's inventory (docs/WIRE_CONTRACT.md, "Skills") -----------------

SOURCE_BUILTIN = "builtin"
SOURCE_WORKSPACE = "workspace"
SKILL_ACTIONS = ("enable", "disable")


SEED_SOURCES = (SOURCE_BUILTIN, SOURCE_WORKSPACE)


def iter_seed_skills(
    seed_root: str | Path | None,
) -> Iterator[tuple[str, str, Path]]:
    """Walk the shipped seed tree, yielding ``(source, name, directory)``.

    **The directory layout is the classification.** The repository's
    ``skills/`` holds one directory per source value of the wire contract:

    .. code-block:: text

        skills/builtin/<name>/SKILL.md     -> source "builtin"
        skills/workspace/<name>/SKILL.md   -> source "workspace"

    ``builtin`` is for skills that document Agents's own machinery — the tools
    the app itself provides (schedules, secrets, the sandbox terminal, the
    workspace). They belong to the app, so the app vouches for them. Everything
    under ``workspace`` is an ordinary skill that merely ships in the box: the
    coworker owns it, may edit it, and the user may delete it. Reclassifying a
    skill is a ``git mv`` between the two directories and nothing else — there
    is no list of names anywhere.

    A skill directory sitting *directly* under the seed root is the pre-split
    layout and counts as ``builtin``, so an older ``AGENTS_SEED_SKILLS`` tree
    keeps working.
    """
    if seed_root is None:
        return
    base = Path(seed_root)
    if not base.is_dir():
        return
    for entry in sorted(base.iterdir()):
        if not entry.is_dir():
            continue
        if (entry / SKILL_FILENAME).is_file():
            yield SOURCE_BUILTIN, entry.name, entry  # pre-split layout
            continue
        if entry.name not in SEED_SOURCES:
            continue
        for child in sorted(entry.iterdir()):
            if child.is_dir() and (child / SKILL_FILENAME).is_file():
                yield entry.name, child.name, child


def seed_sources(seed_root: str | Path | None) -> dict[str, str]:
    """Map each shipped seed skill's name to its source (see
    :func:`iter_seed_skills`). A workspace skill whose name is absent from the
    map was put there by the agent or the user, so it is a ``workspace`` skill.
    """
    return {name: source for source, name, _ in iter_seed_skills(seed_root)}


def skill_row(skill: Skill, *, enabled: bool, seeds: dict[str, str]) -> dict:
    return {
        "name": skill.name,
        "description": skill.description,
        "source": seeds.get(skill.name, SOURCE_WORKSPACE),
        "enabled": enabled,
        "path": skill.path,
    }


def skills_inventory(
    root: str | Path | None,
    *,
    settings: "SkillSettingsStore | None" = None,
    seed_root: str | Path | None = None,
    errors: Iterable[str] = (),
) -> dict:
    """The body of a host → app ``skills_list`` frame.

    Every skill on disk, enabled or not, built-in seeds first, then the
    workspace's own, each group by name. ``errors`` are the loader's (a broken
    SKILL.md) plus whatever the caller adds (an unknown name in a control).
    """
    library = load_skills(root, settings=settings)
    seeds = seed_sources(seed_root)
    rows = [
        skill_row(skill, enabled=True, seeds=seeds) for skill in library.skills.values()
    ] + [
        skill_row(skill, enabled=False, seeds=seeds)
        for skill in library.disabled.values()
    ]
    rows.sort(key=lambda row: (row["source"] != SOURCE_BUILTIN, row["name"]))
    return {"skills": rows, "errors": [*library.errors, *errors]}


def apply_skill_control(
    root: str | Path | None,
    settings: "SkillSettingsStore",
    *,
    name: object,
    action: object,
    seed_root: str | Path | None = None,
) -> dict:
    """An app → host ``skill_control``: flip one switch, answer with the
    inventory. A bad name or action changes nothing and is reported in the
    reply's ``errors`` — the list is still the truth, so the app can redraw."""
    key = name.strip() if isinstance(name, str) else ""
    problems: list[str] = []
    library = load_skills(root, settings=settings)
    if not key or (key not in library.skills and key not in library.disabled):
        problems.append(f"no skill named {key!r}")
    elif action not in SKILL_ACTIONS:
        problems.append(f"unknown action {action!r}: use enable or disable")
    else:
        settings.set_enabled(key, action == "enable")
    return skills_inventory(root, settings=settings, seed_root=seed_root, errors=problems)


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
