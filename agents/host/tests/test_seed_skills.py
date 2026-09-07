"""Seeding shipped skills into a fresh agent workspace (§11).

A new coworker starts with an empty ``skills/`` directory. The host copies the
repository's seed skills in so the agent can, for example, summarize a YouTube
link with no setup. These tests pin the copy, the non-destructive rule that an
agent's own skill of the same name is never overwritten, and the no-op when
there is nothing to seed.
"""

from __future__ import annotations

from cowork_agent.skills import SOURCE_BUILTIN, iter_seed_skills, seed_sources
from cowork_host.seed_skills import seed_skills_dir, seed_workspace_skills

SKILL = "---\nname: {name}\ndescription: {desc}\n---\n\n{body}\n"


def _write_seed(root, name, desc="Does a thing.", body="Step one."):
    directory = root / name
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "SKILL.md").write_text(SKILL.format(name=name, desc=desc, body=body))
    return directory


def test_the_shipped_seed_dir_holds_the_youtube_skill():
    src = seed_skills_dir()
    assert src is not None, "the repository skills/ directory was not found"
    assert (src / "workspace" / "youtube-transcript" / "SKILL.md").is_file()


def test_the_shipped_seed_tree_classifies_every_skill_by_its_directory():
    """The repository's ``skills/`` layout IS the built-in/workspace split.

    Built-in means the skill documents CoWork's own machinery: schedules,
    the secrets vault, the sandbox terminal, the workspace itself. That set is
    closed and is pinned here, so adding a skill to it is a deliberate act.
    ``youtube-transcript`` only ships in the box — it is an ordinary workspace
    skill the coworker owns, and it must never drift back into the built-ins.
    """
    src = seed_skills_dir()
    assert src is not None, "the repository skills/ directory was not found"
    sources = seed_sources(src)

    builtin = {name for name, source in sources.items() if source == SOURCE_BUILTIN}
    assert builtin == {"automations", "secrets", "terminal", "workspace"}
    assert sources["youtube-transcript"] == "workspace"

    # Nothing is left lying directly under skills/: every seed skill sits in a
    # group directory, so nothing gets classified by accident.
    assert not list(src.glob("*/SKILL.md"))


def test_both_seed_groups_are_copied_flat_into_the_workspace(tmp_path):
    src = tmp_path / "seed"
    _write_seed(src / "builtin", "terminal", desc="Runs commands.")
    _write_seed(src / "workspace", "youtube-transcript", desc="Pulls a transcript.")
    workspace = tmp_path / "ws"

    seeded = seed_workspace_skills(workspace, source=src)

    assert sorted(seeded) == ["terminal", "youtube-transcript"]
    skills = workspace / "skills"
    assert (skills / "terminal" / "SKILL.md").is_file()
    assert (skills / "youtube-transcript" / "SKILL.md").is_file()
    # Flat: the group directory does not survive the copy.
    assert not (skills / "builtin").exists()
    assert not (skills / "workspace").exists()


def test_a_group_directory_is_never_mistaken_for_a_skill(tmp_path):
    src = tmp_path / "seed"
    _write_seed(src / "workspace", "youtube-transcript")
    (src / "docs").mkdir()  # not a source group, not a skill

    assert [name for _s, name, _d in iter_seed_skills(src)] == ["youtube-transcript"]


def test_seed_is_copied_into_an_empty_workspace(tmp_path):
    src = tmp_path / "seed"
    _write_seed(src, "youtube-transcript", desc="Pull a YouTube transcript.")
    workspace = tmp_path / "ws"

    seeded = seed_workspace_skills(workspace, source=src)

    assert seeded == ["youtube-transcript"]
    body = (workspace / "skills" / "youtube-transcript" / "SKILL.md").read_text()
    assert "Pull a YouTube transcript." in body


def test_seeding_never_overwrites_the_agents_own_skill(tmp_path):
    src = tmp_path / "seed"
    _write_seed(src, "youtube-transcript", desc="Seed version.")
    workspace = tmp_path / "ws"
    # the agent already has a skill of that name, edited by hand
    owned = workspace / "skills" / "youtube-transcript"
    owned.mkdir(parents=True)
    (owned / "SKILL.md").write_text("agent's own edited copy")

    seeded = seed_workspace_skills(workspace, source=src)

    assert seeded == []  # left untouched
    assert (owned / "SKILL.md").read_text() == "agent's own edited copy"


def test_seeding_is_idempotent(tmp_path):
    src = tmp_path / "seed"
    _write_seed(src, "youtube-transcript")
    workspace = tmp_path / "ws"

    assert seed_workspace_skills(workspace, source=src) == ["youtube-transcript"]
    assert seed_workspace_skills(workspace, source=src) == []  # already there


def test_a_missing_source_is_a_silent_no_op(tmp_path):
    assert seed_workspace_skills(tmp_path / "ws", source=tmp_path / "nope") == []


def test_a_dir_without_a_skill_md_is_skipped(tmp_path):
    src = tmp_path / "seed"
    (src / "not-a-skill").mkdir(parents=True)  # no SKILL.md inside
    _write_seed(src, "youtube-transcript")

    seeded = seed_workspace_skills(tmp_path / "ws", source=src)

    assert seeded == ["youtube-transcript"]


def test_env_override_points_at_a_seed_dir(tmp_path, monkeypatch):
    src = tmp_path / "custom-seed"
    _write_seed(src, "youtube-transcript")
    monkeypatch.setenv("COWORK_SEED_SKILLS", str(src))

    assert seed_skills_dir() == src
