"""Seed skills into a fresh agent workspace.

Skills are workspace-relative: the agent loads ``<workspace>/skills/<name>/
SKILL.md`` (see ``chuk_agents_runtime.skills``). A brand-new agent therefore starts
with an empty skill set. This module copies the repository's shipped seed
skills — the top-level ``skills/`` directory — into a new agent workspace the
first time it is provisioned, so every coworker can, for example, summarize a
YouTube video out of the box.

The seed tree is **grouped by source**: ``skills/builtin/<name>/SKILL.md`` for
the skills that document Agents's own machinery, ``skills/workspace/<name>/
SKILL.md`` for the ones that merely ship in the box and belong to the coworker.
That grouping is the single source of truth for the ``source`` field of a
``skills_list`` row — see :func:`chuk_agents_runtime.skills.iter_seed_skills`, which
this module walks so the copy and the classification can never disagree. The
copy itself is **flat**: both groups land side by side in
``<workspace>/skills/<name>``, because a workspace skill is a workspace skill
wherever it came from.

The copy is **non-destructive**: a seed skill is written only when the agent
does not already have a directory of that name. That keeps the agent's own
edits and any user-added skills untouched, and makes seeding safe to run on
every host boot.

One exception: a **built-in** skill documents the app's own machinery, so the
app keeps it current. When the shipped copy carries a higher
``metadata.version`` than the installed copy, the shipped files replace it
(live test 2026-10-09: the old ``automations`` description told the model to
set up a routine whenever a request said "daily"). An installed copy without a
readable version is left alone: it may be the agent's own file. A
``workspace`` seed is never replaced.

The seed directory is found next to the repository root, located by walking up
from this file until a ``skills/`` directory is seen. ``AGENTS_SEED_SKILLS``
overrides that, mostly for tests and for non-editable installs where the source
tree is not on disk. If no seed directory is found, seeding is a silent no-op —
a missing seed set must never take the host down.
"""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

from chuk_agents_runtime.skills import SKILL_FILENAME, SOURCE_BUILTIN, iter_seed_skills

SKILLS_DIRNAME = "skills"

__all__ = ["SKILL_FILENAME", "seed_skills_dir", "seed_workspace_skills", "skill_version"]

#: ``version: "1.2"`` in the frontmatter's ``metadata`` block.
_VERSION_RE = re.compile(r"^\s*version:\s*[\"']?(\d+(?:\.\d+)*)[\"']?\s*$", re.MULTILINE)


def skill_version(skill_dir: str | Path) -> tuple[int, ...] | None:
    """The ``metadata.version`` of a skill directory's SKILL.md as a tuple,
    or ``None`` when there is no file, no frontmatter or no version."""
    try:
        text = (Path(skill_dir) / SKILL_FILENAME).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    if not text.startswith("---"):
        return None
    frontmatter = text.split("---", 2)[1] if text.count("---") >= 2 else ""
    match = _VERSION_RE.search(frontmatter)
    if match is None:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def seed_skills_dir() -> Path | None:
    """Locate the repository's shipped ``skills/`` directory, or ``None``.

    ``AGENTS_SEED_SKILLS`` wins if set and pointing at a real directory. Else
    walk up from this file looking for a ``skills/`` sibling of the repo.
    """
    override = os.environ.get("AGENTS_SEED_SKILLS")
    if override:
        candidate = Path(override).expanduser()
        return candidate if candidate.is_dir() else None
    for parent in Path(__file__).resolve().parents:
        candidate = parent / SKILLS_DIRNAME
        if not candidate.is_dir():
            continue
        # Either layout counts: the grouped tree the repository ships
        # (skills/<source>/<name>/SKILL.md) or a flat pre-split one.
        for pattern in (f"*/*/{SKILL_FILENAME}", f"*/{SKILL_FILENAME}"):
            if any(candidate.glob(pattern)):
                return candidate
    return None


def seed_workspace_skills(
    workspace: str | Path, *, source: str | Path | None = None
) -> list[str]:
    """Copy shipped seed skills into ``<workspace>/skills`` if absent.

    Returns the names of the skills that were newly written (empty when there
    is nothing to seed or every seed already exists). Never raises for a
    missing source or an unreadable seed — a broken seed costs that one skill,
    not the host.
    """
    src = Path(source).expanduser() if source is not None else seed_skills_dir()
    if src is None or not src.is_dir():
        return []

    dest_root = Path(workspace).expanduser() / SKILLS_DIRNAME
    seeded: list[str] = []
    for group, name, directory in iter_seed_skills(src):
        target = dest_root / name
        if target.exists():
            # The agent already has this skill: leave it alone, unless it is
            # an older copy of a built-in (see the module docstring).
            if group == SOURCE_BUILTIN and _outdated(target, directory):
                try:
                    shutil.copytree(directory, target, dirs_exist_ok=True)
                except OSError:
                    continue
                seeded.append(name)
            continue
        try:
            shutil.copytree(directory, target)
        except OSError:
            continue
        seeded.append(name)
    return seeded


def _outdated(installed: Path, shipped: Path) -> bool:
    """True when both copies carry a version and the shipped one is higher."""
    have = skill_version(installed)
    ship = skill_version(shipped)
    return have is not None and ship is not None and ship > have
