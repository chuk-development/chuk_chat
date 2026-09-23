"""The host state directory and its one-time move (bug: pairing "lost").

Every test builds a throwaway HOME. Nothing here may read or write the real
``~/.cowork``, ``~/.agents`` or ``~/.local/share``.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from chuk_agents_config import (
    config_home,
    default_state_home,
    locate_state_home,
    resolve_state_home,
)
from chuk_agents_config.state_home import (
    MIGRATION_MARKER,
    MOVED_NOTE,
    migrate_state_home_report,
)


@pytest.fixture()
def home(tmp_path) -> Path:
    h = tmp_path / "home"
    h.mkdir()
    return h


def env_for(home: Path, **extra: str) -> dict[str, str]:
    return {"HOME": str(home), **extra}


def target_of(home: Path) -> Path:
    return home / ".local" / "share" / "chuk-agents"


def make_state(directory: Path, *, paired: bool, tag: str) -> None:
    """A host state as the host writes it; ``tag`` tells two states apart."""
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "host_device.key").write_text(f"seed-{tag}", encoding="utf-8")
    os.chmod(directory / "host_device.key", 0o600)
    (directory / "account.json").write_text(f'{{"who": "{tag}"}}', encoding="utf-8")
    (directory / "roster.db").write_bytes(b"roster-" + tag.encode())
    (directory / "executor-state.db").write_bytes(b"exec-" + tag.encode())
    (directory / "agents" / "nova").mkdir(parents=True, exist_ok=True)
    (directory / "agents" / "nova" / "notes.md").write_text(tag, encoding="utf-8")
    if paired:
        (directory / "paired.json").write_text(f'{{"peer": "{tag}"}}', encoding="utf-8")
        (directory / "secrets.enc").write_bytes(b"vault-" + tag.encode())
        (directory / "rooms.db").write_bytes(b"rooms-" + tag.encode())


def make_skills(agents_dir: Path) -> None:
    (agents_dir / "skills" / "pdf").mkdir(parents=True, exist_ok=True)
    (agents_dir / "skills" / "pdf" / "SKILL.md").write_text("pdf skill", encoding="utf-8")
    (agents_dir / ".skill-lock.json").write_text("{}", encoding="utf-8")


def assert_skills_untouched(agents_dir: Path) -> None:
    assert (agents_dir / "skills" / "pdf" / "SKILL.md").read_text(encoding="utf-8") == "pdf skill"
    assert (agents_dir / ".skill-lock.json").read_text(encoding="utf-8") == "{}"


def migrate(home: Path):
    return migrate_state_home_report(target_of(home), home=home)


# -- where the directory is -----------------------------------------------


def test_default_is_xdg_data_home_not_dot_agents(home):
    assert default_state_home(env_for(home)) == target_of(home)
    assert config_home(env_for(home)) == target_of(home)


def test_xdg_data_home_moves_the_default(home, tmp_path):
    data = tmp_path / "data"
    assert default_state_home(env_for(home, XDG_DATA_HOME=str(data))) == data / "chuk-agents"


def test_a_relative_xdg_data_home_is_ignored(home):
    assert default_state_home(env_for(home, XDG_DATA_HOME="rel/data")) == target_of(home)


def test_agents_home_wins_and_is_never_migrated_into(home, tmp_path):
    make_state(home / ".cowork", paired=True, tag="old")
    chosen = tmp_path / "mine"
    got = resolve_state_home(environ=env_for(home, AGENTS_HOME=str(chosen)))
    assert got == chosen
    assert not chosen.exists()
    assert (home / ".cowork" / "paired.json").is_file()


def test_cowork_home_is_still_read(home, tmp_path):
    chosen = tmp_path / "legacy-env"
    assert resolve_state_home(environ=env_for(home, COWORK_HOME=str(chosen))) == chosen
    assert locate_state_home(environ=env_for(home, COWORK_HOME=str(chosen))) == chosen
    both = env_for(home, AGENTS_HOME=str(tmp_path / "a"), COWORK_HOME=str(tmp_path / "c"))
    assert resolve_state_home(environ=both) == tmp_path / "a"


def test_explicit_path_wins_and_expands_a_tilde(home):
    make_state(home / ".cowork", paired=True, tag="old")
    got = resolve_state_home("~/somewhere", environ=env_for(home))
    assert got == home / "somewhere"
    assert (home / ".cowork" / "paired.json").is_file()


# -- the case that was broken ----------------------------------------------


def test_dot_agents_with_only_skills_is_not_a_host_state(home):
    make_skills(home / ".agents")
    report = migrate(home)
    assert report.source is None
    assert not (target_of(home) / "paired.json").exists()
    assert_skills_untouched(home / ".agents")
    assert not (home / ".agents" / MOVED_NOTE).exists()


def test_paired_cowork_moves_even_when_dot_agents_exists_with_skills(home):
    make_state(home / ".cowork", paired=True, tag="old")
    (home / ".cowork" / "host.log").write_text("log", encoding="utf-8")
    make_skills(home / ".agents")

    got = resolve_state_home(environ=env_for(home))

    target = target_of(home)
    assert got == target
    assert (target / "paired.json").read_text(encoding="utf-8") == '{"peer": "old"}'
    assert (target / "host_device.key").read_text(encoding="utf-8") == "seed-old"
    assert (target / "host_device.key").stat().st_mode & 0o777 == 0o600
    assert (target / "secrets.enc").read_bytes() == b"vault-old"
    assert (target / "agents" / "nova" / "notes.md").read_text(encoding="utf-8") == "old"
    # ~/.cowork is wholly ours, so everything moved, and it is now a symlink.
    assert (target / "host.log").is_file()
    assert (home / ".cowork").is_symlink()
    assert (home / ".cowork").resolve() == target.resolve()
    assert (target.stat().st_mode & 0o777) == 0o700
    assert not (target / MIGRATION_MARKER).exists()
    assert_skills_untouched(home / ".agents")


def test_owner_machine_paired_cowork_beats_fresh_unpaired_dot_agents(home):
    """The verified state: ~/.cowork paired, ~/.agents fresh + skills."""
    make_state(home / ".cowork", paired=True, tag="old")
    make_state(home / ".agents", paired=False, tag="fresh")
    make_skills(home / ".agents")

    report = migrate(home)

    target = target_of(home)
    assert report.source == home / ".cowork"
    assert (target / "paired.json").is_file()
    assert (target / "host_device.key").read_text(encoding="utf-8") == "seed-old"
    # The fresh, unpaired identity is left where it is and reported.
    assert report.left_in_place == [home / ".agents"]
    assert (home / ".agents" / "host_device.key").read_text(encoding="utf-8") == "seed-fresh"
    assert_skills_untouched(home / ".agents")


def test_top_level_dot_agents_state_moves_but_skills_stay(home):
    make_state(home / ".agents", paired=True, tag="renamed")
    (home / ".agents" / "roster.db-wal").write_bytes(b"wal")
    (home / ".agents" / "somebody-elses.txt").write_text("keep", encoding="utf-8")
    (home / ".agents" / "bin").mkdir()
    make_skills(home / ".agents")

    report = migrate(home)

    target = target_of(home)
    assert report.source == home / ".agents"
    for name in ("paired.json", "host_device.key", "account.json", "secrets.enc",
                 "roster.db", "roster.db-wal", "executor-state.db", "rooms.db", "agents"):
        assert (target / name).exists(), name
        assert not (home / ".agents" / name).exists(), name
    # Not ours: never moved.
    assert (home / ".agents" / "somebody-elses.txt").read_text(encoding="utf-8") == "keep"
    assert (home / ".agents" / "bin").is_dir()
    assert_skills_untouched(home / ".agents")
    note = (home / ".agents" / MOVED_NOTE).read_text(encoding="utf-8")
    assert str(target) in note
    assert not (home / ".agents").is_symlink()


def test_old_migration_left_cowork_as_a_symlink_into_dot_agents(home):
    make_state(home / ".agents", paired=True, tag="renamed")
    make_skills(home / ".agents")
    (home / ".cowork").symlink_to(home / ".agents", target_is_directory=True)

    report = migrate(home)

    target = target_of(home)
    assert (target / "paired.json").is_file()
    assert report.left_in_place == []
    # The old symlink now points at the new place, and skills never moved.
    assert (home / ".cowork").is_symlink()
    assert (home / ".cowork").resolve() == target.resolve()
    assert_skills_untouched(home / ".agents")


def test_with_two_paired_states_the_newer_pairing_wins(home):
    make_state(home / ".cowork", paired=True, tag="older")
    make_state(home / ".agents", paired=True, tag="newer")
    os.utime(home / ".cowork" / "paired.json", (1_000_000, 1_000_000))
    os.utime(home / ".agents" / "paired.json", (2_000_000, 2_000_000))

    report = migrate(home)

    assert report.source == home / ".agents"
    assert (target_of(home) / "paired.json").read_text(encoding="utf-8") == '{"peer": "newer"}'
    assert report.left_in_place == [home / ".cowork"]
    assert (home / ".cowork" / "paired.json").is_file()


def test_an_existing_pairing_in_the_target_is_never_overwritten(home):
    make_state(target_of(home), paired=True, tag="current")
    make_state(home / ".cowork", paired=True, tag="old")

    report = migrate(home)

    assert report.source is None
    assert (target_of(home) / "paired.json").read_text(encoding="utf-8") == '{"peer": "current"}'
    assert report.left_in_place == [home / ".cowork"]
    assert (home / ".cowork" / "paired.json").is_file()


def test_empty_directories_from_the_installer_do_not_block_the_move(home):
    target = target_of(home)
    (target / "agents").mkdir(parents=True)
    (target / "logs").mkdir()
    make_state(home / ".cowork", paired=True, tag="old")

    migrate(home)

    assert (target / "paired.json").is_file()
    assert (target / "agents" / "nova" / "notes.md").read_text(encoding="utf-8") == "old"


def test_a_conflicting_file_is_kept_on_both_sides(home):
    target = target_of(home)
    target.mkdir(parents=True)
    (target / "config.toml").write_text("new", encoding="utf-8")
    make_state(home / ".cowork", paired=True, tag="old")
    (home / ".cowork" / "config.toml").write_text("old", encoding="utf-8")

    report = migrate(home)

    assert report.conflicts == ["config.toml"]
    assert (target / "config.toml").read_text(encoding="utf-8") == "new"
    assert (target / "paired.json").is_file()
    # ~/.cowork could not be emptied, so it stays a directory with a note.
    assert (home / ".cowork" / "config.toml").read_text(encoding="utf-8") == "old"
    assert (home / ".cowork" / MOVED_NOTE).is_file()


def test_an_interrupted_move_is_finished_on_the_next_start(home):
    make_state(home / ".agents", paired=True, tag="renamed")
    make_skills(home / ".agents")
    target = target_of(home)
    target.mkdir(parents=True)
    # A crash after the marker and the first file: the pairing already moved,
    # the device key did not.
    (target / MIGRATION_MARKER).write_text(str((home / ".agents").resolve()) + "\n", encoding="utf-8")
    os.replace(home / ".agents" / "paired.json", target / "paired.json")

    migrate(home)

    assert (target / "paired.json").is_file()
    assert (target / "host_device.key").read_text(encoding="utf-8") == "seed-renamed"
    assert not (home / ".agents" / "host_device.key").exists()
    assert not (target / MIGRATION_MARKER).exists()
    assert_skills_untouched(home / ".agents")


def test_running_twice_changes_nothing(home):
    make_state(home / ".cowork", paired=True, tag="old")
    make_skills(home / ".agents")
    migrate(home)
    before = sorted(str(p.relative_to(home)) for p in home.rglob("*"))
    second = migrate(home)
    assert second.source is None and second.moved == []
    assert sorted(str(p.relative_to(home)) for p in home.rglob("*")) == before


def test_no_legacy_state_creates_nothing(home):
    report = migrate(home)
    assert report.source is None
    assert not target_of(home).exists()


# -- read-only lookup (status, doctor) --------------------------------------


def test_locate_points_at_the_legacy_state_without_moving_it(home):
    make_state(home / ".cowork", paired=True, tag="old")
    make_skills(home / ".agents")
    assert locate_state_home(environ=env_for(home)) == (home / ".cowork").resolve()
    assert (home / ".cowork" / "paired.json").is_file()
    assert not target_of(home).exists()


def test_locate_and_resolve_agree_after_the_move(home):
    make_state(home / ".cowork", paired=True, tag="old")
    resolved = resolve_state_home(environ=env_for(home))
    assert locate_state_home(environ=env_for(home)) == resolved


def test_locate_ignores_a_skills_only_dot_agents(home):
    make_skills(home / ".agents")
    assert locate_state_home(environ=env_for(home)) == target_of(home)
