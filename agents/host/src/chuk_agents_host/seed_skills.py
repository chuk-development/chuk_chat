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
every host boot. It is not an upgrade path — a changed seed does not overwrite
an agent's existing copy; that is a deliberate v1 boundary (the workspace is
the agent's territory, §11).

The seed directory is found next to the repository root, located by walking up
from this file until a ``skills/`` directory is seen. ``AGENTS_SEED_SKILLS``
overrides that, mostly for tests and for non-editable installs where the source
tree is not on disk. If no seed directory is found, seeding is a silent no-op —
a missing seed set must never take the host down.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

from chuk_agents_runtime.skills import SKILL_FILENAME, iter_seed_skills

SKILLS_DIRNAME = "skills"

__all__ = ["SKILL_FILENAME", "seed_skills_dir", "seed_workspace_skills"]


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
    for _source, name, directory in iter_seed_skills(src):
        target = dest_root / name
        if target.exists():
            continue  # the agent already has this skill — leave it alone
        try:
            shutil.copytree(directory, target)
        except OSError:
            continue
        seeded.append(name)
    return seeded
