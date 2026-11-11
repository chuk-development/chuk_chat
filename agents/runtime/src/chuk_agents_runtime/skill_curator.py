"""Skill curator: archive skills nobody uses (Hermes H5).

Skills that the agent proposes pile up. The curator reads the usage counters
that :class:`~chuk_agents_runtime.skills.SkillSettingsStore` keeps (one row per
skill, bumped on every load) and moves a skill that was not used for
``unused_days`` into ``<root>/.archive/``. It **never deletes**: an archived
skill is a directory move away from active again (:func:`restore_skill`).

What the curator never touches:

- a shipped seed skill (``builtin`` or ``workspace`` source in the seed tree,
  see :func:`~chuk_agents_runtime.skills.seed_sources`). The host re-seeds those,
  and the app vouches for them;
- a skill with ``pinned: true`` in its frontmatter, or one named in ``pinned``
  (for example a skill that an automation loads);
- a skill whose clock has not run out. The clock starts at the newest of: the
  last load, the first time the curator saw the skill, and the SKILL.md mtime.
  So a skill nobody loaded yet still gets its full grace period.

The loader skips ``.archive`` (it has no ``SKILL.md`` of its own), so an
archived skill leaves the catalogue at the next task.
"""

from __future__ import annotations

import os
import sqlite3
import time
from collections.abc import Iterable
from pathlib import Path

from .skills import SKILL_FILENAME, SkillSettingsStore, load_skills, seed_sources

ARCHIVE_DIRNAME = ".archive"
DEFAULT_UNUSED_DAYS = 30
_DAY = 86_400.0


def _archive_name(name: str, now: float) -> str:
    return f"{name}-{time.strftime('%Y%m%d%H%M%S', time.gmtime(now))}"


def curate_skills(
    root: str | Path | None,
    settings: SkillSettingsStore,
    *,
    seed_root: str | Path | None = None,
    pinned: Iterable[str] = (),
    unused_days: float = DEFAULT_UNUSED_DAYS,
    now: float | None = None,
    dry_run: bool = False,
) -> dict:
    """Archive the unused skills under ``root``; the report.

    ``{"archived": [{name, archived_as, idle_days}], "kept": [names],
    "skipped": [{name, reason}], "errors": [...]}``. ``dry_run`` reports
    without moving anything.
    """
    report: dict = {"archived": [], "kept": [], "skipped": [], "errors": []}
    if root is None or not Path(root).is_dir():
        return report
    stamp = time.time() if now is None else now
    base = Path(root)
    library = load_skills(base, settings=settings)
    seeds = seed_sources(seed_root)
    keep = set(pinned)
    try:
        usage = settings.usage()
    except sqlite3.Error as exc:
        report["errors"].append(f"usage unreadable, nothing archived: {exc}")
        return report
    limit = max(0.0, float(unused_days)) * _DAY
    skills = {**library.skills, **library.disabled}
    for name in sorted(skills):
        skill = skills[name]
        if name in seeds:
            report["skipped"].append({"name": name, "reason": "seed"})
            continue
        if skill.pinned or name in keep:
            report["skipped"].append({"name": name, "reason": "pinned"})
            continue
        row = usage.get(name)
        if row is None:
            # First sight: the grace clock starts now.
            try:
                settings.mark_seen(name, now=stamp)
            except sqlite3.Error:
                pass
            report["kept"].append(name)
            continue
        path = Path(skill.path) if skill.path else base / name / SKILL_FILENAME
        try:
            mtime = path.stat().st_mtime
        except OSError:
            mtime = 0.0
        last = max(
            float(row.get("last_used_at") or 0.0),
            float(row.get("first_seen_at") or 0.0),
            mtime,
        )
        idle = stamp - last
        if idle < limit:
            report["kept"].append(name)
            continue
        directory = path.parent
        target = base / ARCHIVE_DIRNAME / _archive_name(directory.name, stamp)
        entry = {"name": name, "archived_as": target.name, "idle_days": round(idle / _DAY, 1)}
        if not dry_run:
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(directory, target)
            except OSError as exc:
                report["errors"].append(f"{name}: could not archive: {exc}")
                continue
        report["archived"].append(entry)
    report["archive"] = list_archived(base)
    return report


def list_archived(root: str | Path) -> list[str]:
    """The archived skill directories, newest name last."""
    archive = Path(root) / ARCHIVE_DIRNAME
    if not archive.is_dir():
        return []
    return sorted(
        entry.name
        for entry in archive.iterdir()
        if entry.is_dir() and (entry / SKILL_FILENAME).is_file()
    )


def restore_skill(root: str | Path, archived_as: str) -> dict:
    """Move one archived skill back. Refused when the name is taken again or
    the entry does not exist; nothing is overwritten."""
    base = Path(root)
    source = base / ARCHIVE_DIRNAME / archived_as
    if "/" in archived_as or archived_as in ("", ".", "..") or not source.is_dir():
        return {"ok": False, "error": f"no archived skill {archived_as!r}"}
    name = archived_as.rsplit("-", 1)[0] if "-" in archived_as else archived_as
    target = base / name
    if target.exists():
        return {"ok": False, "error": f"a skill directory {name!r} exists already"}
    os.replace(source, target)
    return {"ok": True, "name": name, "path": str(target / SKILL_FILENAME)}


__all__ = [
    "ARCHIVE_DIRNAME",
    "DEFAULT_UNUSED_DAYS",
    "curate_skills",
    "list_archived",
    "restore_skill",
]
