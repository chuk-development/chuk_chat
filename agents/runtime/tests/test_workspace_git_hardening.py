"""Security review of 3cb9aa01, H2 and H3: host-side git never runs what the
agent planted, never writes through a symlink, and keeps its private git dir
and rewind ledger outside the agent-writable workspace.

Every test is an exploit an agent could stage with plain file writes in its
own workspace, and checks that the host does not fall for it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from chuk_agents_runtime.workspace_git import (
    LEGACY_PRIVATE_GIT_DIR,
    GitWorkspace,
    git_state_home,
)

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def _plain_git(cwd, *args, env=None) -> str:
    proc = subprocess.run(
        ["git", "-C", str(cwd), *args],
        capture_output=True, text=True, check=True,
        env={**os.environ, **(env or {})},
    )
    return proc.stdout


def _user_repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    _plain_git(root, "init", "-q")
    _plain_git(root, "config", "user.name", "Real Person")
    _plain_git(root, "config", "user.email", "real@example.com")
    (root / "README.md").write_text("theirs\n")
    _plain_git(root, "add", "-A")
    _plain_git(root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "their commit")
    return root


def _marker_script(tmp_path: Path) -> tuple[Path, Path]:
    """A program that leaves a marker file when anything runs it."""
    marker = tmp_path / "PWNED"
    script = tmp_path / "evil.sh"
    script.write_text(f"#!/bin/sh\ntouch {marker}\ncat\nexit 0\n")
    script.chmod(0o755)
    return script, marker


def _fresh(tmp_path: Path) -> GitWorkspace:
    ws = GitWorkspace.open(tmp_path / "ws")
    assert ws is not None and ws.enabled and not ws.private
    return ws


# -- H3: nothing the agent plants is executed --------------------------------


def test_planted_fsmonitor_diff_filter_and_textconv_never_run(tmp_path):
    """The agent owns ``.git`` in a fresh workspace. It writes every exec hook
    git has into the config and a .gitattributes / info/attributes that
    selects them. No host git run (record, history, checkpoint, rewind) may
    execute the program."""
    ws = _fresh(tmp_path)
    script, marker = _marker_script(tmp_path)
    (ws.root / "a.txt").write_text("one\n")
    ws.record("write_file", {"path": "a.txt"}, {"ok": True})
    cp = ws.create_checkpoint("cp1")
    assert cp is not None

    config = ws.root / ".git" / "config"
    with config.open("a") as handle:
        handle.write(
            f"[core]\n\tfsmonitor = {script}\n\thooksPath = {tmp_path}\n"
            f"[diff]\n\texternal = {script}\n"
            f"[diff \"evil\"]\n\ttextconv = {script}\n\tcommand = {script}\n"
            f"[filter \"evil\"]\n\tclean = {script}\n\tsmudge = {script}\n"
            f"\tprocess = {script}\n\trequired = true\n"
            f"[merge \"evil\"]\n\tdriver = {script}\n"
        )
    (ws.root / ".gitattributes").write_text("* filter=evil diff=evil merge=evil\n")
    info = ws.root / ".git" / "info"
    info.mkdir(exist_ok=True)
    (info / "attributes").write_text("* filter=evil diff=evil merge=evil\n")
    (tmp_path / "post-commit").write_text(f"#!/bin/sh\ntouch {marker}\n")
    (tmp_path / "post-commit").chmod(0o755)

    (ws.root / "a.txt").write_text("two\n")
    ws.record("write_file", {"path": "a.txt"}, {"ok": True})
    ws.note_agent_writes(["a.txt"])
    ws.history(5)
    ws.outside_changes()
    result = ws.rewind(cp.commit, mode="force")
    assert result["ok"] is True
    assert (ws.root / "a.txt").read_text() == "one\n"
    assert not marker.exists(), "host git executed a program the agent planted"


def test_planted_core_worktree_cannot_point_host_git_elsewhere(tmp_path):
    """``core.worktree`` in the agent's own config would make the host commit
    (and rewind) another directory."""
    ws = _fresh(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "secret.txt").write_text("host secret\n")
    _plain_git(ws.root, "config", "core.worktree", str(elsewhere))
    (ws.root / "mine.txt").write_text("x\n")
    ws.record("write_file", {"path": "mine.txt"}, {"ok": True})
    tracked = subprocess.run(
        ["git", "--git-dir", str(ws.root / ".git"), "ls-tree", "-r", "--name-only", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    assert "mine.txt" in tracked
    assert "secret.txt" not in tracked


# -- H3: private git dir and ledger are host state ----------------------------


def test_private_git_dir_and_ledger_live_outside_the_workspace(tmp_path):
    root = _user_repo(tmp_path)
    ws = GitWorkspace.open(root)
    assert ws.enabled and ws.private
    (root / "a.txt").write_text("x\n")
    ws.record("write_file", {"path": "a.txt"}, {"ok": True})
    ws.note_agent_writes(["a.txt"])
    home = git_state_home().resolve()
    assert home in ws._private_dir.parents
    ledger = ws._ledger_path()
    assert ledger is not None and ledger.is_file()
    assert home in ledger.resolve().parents
    assert not (root / LEGACY_PRIVATE_GIT_DIR).exists()
    for path in root.rglob("*"):
        assert path.name != "agents-writes.json"


def test_own_repo_ledger_is_not_in_the_agents_git_dir(tmp_path):
    """A ledger inside ``.git`` is a ledger the agent can make lie (claim the
    user's file as its own, so a safe rewind overwrites the user's edit)."""
    ws = _fresh(tmp_path)
    (ws.root / "a.txt").write_text("x\n")
    ws.note_agent_writes(["a.txt"])
    ledger = ws._ledger_path()
    assert ledger is not None and ws.root.resolve() not in ledger.resolve().parents
    assert not (ws.root / ".git" / "agents-writes.json").exists()


def _legacy_private(root: Path) -> Path:
    """What an older build left: a private repo at ``.agents/git``."""
    legacy = root / LEGACY_PRIVATE_GIT_DIR
    legacy.parent.mkdir(parents=True, exist_ok=True)
    env = {"GIT_DIR": str(legacy), "GIT_WORK_TREE": str(root)}
    subprocess.run(["git", "init", "-q", "--bare", str(legacy)], check=True)
    _plain_git(root, "config", "core.bare", "false", env=env)
    _plain_git(root, "config", "user.name", "Agents Agent", env=env)
    _plain_git(root, "config", "user.email", "agent@cowork.local", env=env)
    (legacy / "info").mkdir(exist_ok=True)
    (legacy / "info" / "exclude").write_text("/.agents/git/\n")
    (root / ".agents" / "journal.jsonl").write_text('{"seq": 1, "tool": "write_file"}\n')
    (root / "agent.txt").write_text("agent work\n")
    _plain_git(root, "add", "-A", env=env)
    _plain_git(root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "write_file: agent.txt", env=env)
    (root / "agent.txt").write_text("agent work 2\n")
    _plain_git(root, "add", "-A", env=env)
    _plain_git(root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "write_file: again", env=env)
    _plain_git(root, "update-ref", "refs/agents/checkpoints/c1", "HEAD~1", env=env)
    return legacy


def test_legacy_private_dir_is_moved_to_host_state_with_its_history(tmp_path):
    root = _user_repo(tmp_path)
    legacy = _legacy_private(root)
    old_log = _plain_git(root, "log", "--format=%H %s", env={"GIT_DIR": str(legacy)})
    old_refs = _plain_git(root, "for-each-ref", env={"GIT_DIR": str(legacy)})

    ws = GitWorkspace.open(root)
    assert ws.enabled and ws.private
    assert not legacy.exists(), "the old in-workspace git dir must be gone"
    assert git_state_home().resolve() in ws._private_dir.parents
    env = {"GIT_DIR": str(ws._private_dir)}
    new_log = _plain_git(root, "log", "--format=%H %s", env=env)
    assert new_log.endswith(old_log)
    new_refs = _plain_git(root, "for-each-ref", env=env)
    for line in old_refs.splitlines():
        assert line in new_refs
    # It keeps working: numbering resumes from the journal, commits land.
    ws.record("list_dir", {"path": "."}, {"ok": True})
    assert "list_dir" in _plain_git(root, "log", "-1", "--format=%s", env=env)
    # The user's repo was never touched.
    assert _plain_git(root, "log", "--format=%s").splitlines() == ["their commit"]


def test_migration_drops_planted_config_and_does_not_run_it(tmp_path):
    root = _user_repo(tmp_path)
    legacy = _legacy_private(root)
    script, marker = _marker_script(tmp_path)
    with (legacy / "config").open("a") as handle:
        handle.write(
            f"[core]\n\tfsmonitor = {script}\n[diff]\n\texternal = {script}\n"
            f"[filter \"evil\"]\n\tclean = {script}\n"
        )
    (root / ".gitattributes").write_text("* filter=evil\n")
    ws = GitWorkspace.open(root)
    assert ws.enabled and ws.private
    (root / "b.txt").write_text("b\n")
    ws.record("write_file", {"path": "b.txt"}, {"ok": True})
    assert not marker.exists()
    config = (ws._private_dir / "config").read_text()
    assert "fsmonitor" not in config and "evil" not in config and "external" not in config


def test_a_legacy_dir_holding_a_symlink_is_not_trusted(tmp_path):
    """``.agents/git/objects`` pointing elsewhere would make host git write
    there. Such a dir is neither moved nor deleted; a fresh private repo is
    made in the host state."""
    root = _user_repo(tmp_path)
    legacy = _legacy_private(root)
    outside = tmp_path / "outside-objects"
    shutil.move(str(legacy / "refs"), str(outside))
    os.symlink(outside, legacy / "refs")
    ws = GitWorkspace.open(root)
    assert ws.enabled and ws.private
    assert legacy.is_dir()  # left alone, not deleted
    assert git_state_home().resolve() in ws._private_dir.parents
    assert ws._private_dir != legacy.resolve()


# -- H2: rewind never writes or deletes through a symlink ----------------------


def _with_checkpoint(tmp_path: Path):
    ws = _fresh(tmp_path)
    (ws.root / "sub").mkdir()
    (ws.root / "sub" / "a.txt").write_text("checkpoint\n")
    (ws.root / "top.txt").write_text("checkpoint\n")
    ws.record("write_file", {"path": "sub/a.txt"}, {"ok": True})
    cp = ws.create_checkpoint("cp")
    assert cp is not None
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "a.txt").write_text("victim\n")
    (outside / "new.txt").write_text("victim\n")
    (outside / "top.txt").write_text("victim\n")
    return ws, cp.commit, outside


def test_rewind_through_a_symlinked_parent_writes_nothing_outside(tmp_path):
    ws, target, outside = _with_checkpoint(tmp_path)
    (ws.root / "sub" / "a.txt").write_text("agent\n")
    ws.record("write_file", {"path": "sub/a.txt"}, {"ok": True})
    ws.note_agent_writes(["sub/a.txt"])
    # The agent swaps the directory for a link out of the workspace.
    shutil.rmtree(ws.root / "sub")
    os.symlink(outside, ws.root / "sub")
    result = ws.rewind(target, mode="force")
    assert result["ok"] is True
    assert (outside / "a.txt").read_text() == "victim\n"
    assert (outside / "new.txt").read_text() == "victim\n"
    # The workspace itself is back: a real directory with the checkpoint file.
    assert not (ws.root / "sub").is_symlink()
    assert (ws.root / "sub" / "a.txt").read_text() == "checkpoint\n"


def test_restore_refuses_a_parent_swapped_for_a_symlink_mid_rewind(tmp_path):
    """The race: the diff is computed, then the parent becomes a symlink.
    A write and a delete under it must both be refused."""
    ws, target, outside = _with_checkpoint(tmp_path)
    shutil.rmtree(ws.root / "sub")
    os.symlink(outside, ws.root / "sub")
    assert ws._restore_path("sub/a.txt", target) is False
    assert ws._restore_path("sub/new.txt", target) is False  # not in target: a delete
    assert (outside / "a.txt").read_text() == "victim\n"
    assert (outside / "new.txt").read_text() == "victim\n"


def test_rewind_replaces_a_leaf_symlink_instead_of_writing_through_it(tmp_path):
    ws, target, outside = _with_checkpoint(tmp_path)
    (ws.root / "top.txt").unlink()
    os.symlink(outside / "top.txt", ws.root / "top.txt")
    result = ws.rewind(target, mode="force")
    assert result["ok"] is True
    assert (outside / "top.txt").read_text() == "victim\n"
    assert not (ws.root / "top.txt").is_symlink()
    assert (ws.root / "top.txt").read_text() == "checkpoint\n"


def test_merge_never_reads_or_writes_through_a_leaf_symlink(tmp_path):
    ws, target, outside = _with_checkpoint(tmp_path)
    (ws.root / "top.txt").write_text("agent\n")
    ws.record("write_file", {"path": "top.txt"}, {"ok": True})
    ws.note_agent_writes(["top.txt"])
    ledger_blob = ws.agent_writes()["top.txt"]
    (ws.root / "top.txt").unlink()
    os.symlink(outside / "top.txt", ws.root / "top.txt")
    assert ws._merge_back("top.txt", ledger_blob, target) is False
    assert (outside / "top.txt").read_text() == "victim\n"


def test_blob_of_does_not_hash_a_file_outside_through_a_symlink(tmp_path):
    ws, _target, outside = _with_checkpoint(tmp_path)
    shutil.rmtree(ws.root / "sub")
    os.symlink(outside, ws.root / "sub")
    assert ws._blob_of("sub/a.txt") == "?"
    victim_hash = _plain_git(tmp_path, "hash-object", str(outside / "top.txt")).strip()
    (ws.root / "top.txt").unlink()
    os.symlink(outside / "top.txt", ws.root / "top.txt")
    assert ws._blob_of("top.txt") != victim_hash
