"""Git-versioned workspace + action journal (§7.7).

Every test builds its repo under ``tmp_path``. Nothing here may run git against
the checkout the tests live in.
"""

import json
import shutil
import subprocess

import pytest

from cowork_agent.environment import LocalEnvironment
from cowork_agent.registry import ToolRegistry
from cowork_agent.tools import register_file_tools
from cowork_agent.workspace_git import (
    JOURNAL_PATH,
    GitWorkspace,
    redact_args,
    summarize_result,
)
from cowork_agent.workspace_tools import JournalingRegistry, register_workspace_tools

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None, reason="git is not installed"
)


def _git(root, *args) -> str:
    proc = subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return proc.stdout


def _ws(tmp_path, name="workspace", **kwargs) -> GitWorkspace:
    workspace = GitWorkspace.open(tmp_path / name, **kwargs)
    assert workspace is not None and workspace.enabled
    return workspace


def _registry(workspace) -> JournalingRegistry:
    registry = JournalingRegistry(workspace)
    register_file_tools(registry, LocalEnvironment())
    register_workspace_tools(registry, workspace)
    return registry


# -- journal ---------------------------------------------------------------


def test_every_tool_call_is_journaled_in_order_including_read_only(tmp_path):
    """A read-only call changes no file and must still be in the record — that
    is the difference between an action journal and a diff log."""
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    target = workspace.root / "notes.txt"

    registry.dispatch("write_file", {"path": str(target), "content": "one\n"})
    registry.dispatch("read_file", {"path": str(target)})
    registry.dispatch("list_dir", {"path": str(workspace.root)})
    registry.dispatch("write_file", {"path": str(target), "content": "two\n"})

    entries = workspace.journal_entries()
    assert [e["tool"] for e in entries] == [
        "write_file",
        "read_file",
        "list_dir",
        "write_file",
    ]
    assert [e["seq"] for e in entries] == [1, 2, 3, 4]
    # the read-only calls touched nothing, and are recorded anyway
    assert entries[1]["changed_files"] == []
    assert entries[2]["changed_files"] == []
    assert entries[0]["changed_files"] == ["notes.txt"]
    assert all(e["ok"] for e in entries)


def test_a_read_only_call_still_produces_a_commit(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    before = len(workspace.history(limit=50))

    registry.dispatch("list_dir", {"path": str(workspace.root)})

    history = workspace.history(limit=50)
    assert len(history) == before + 1
    assert "journal only" in history[0].subject
    assert history[0].seq == 1


def test_a_failed_call_is_journaled_as_not_ok(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)

    registry.dispatch("read_file", {"path": str(tmp_path / "missing" / "nope.txt")})

    entry = workspace.journal_entries()[-1]
    assert entry["tool"] == "read_file"
    # `read_file` reports its own failure in a result envelope, not by raising.
    assert entry["result"].startswith("{")
    assert '"ok": false' in entry["result"].lower()


def test_an_existing_repo_is_adopted_without_rewriting_its_config(tmp_path):
    """From the second start on, "already a repo" is the normal case — and the
    repo may be one the user already owned."""
    root = tmp_path / "theirs"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    _git(root, "config", "user.name", "Real Person")
    _git(root, "config", "user.email", "real@example.com")
    (root / "README.md").write_text("theirs\n")
    _git(root, "add", "-A")
    _git(root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "their commit")

    workspace = GitWorkspace.open(root)
    assert workspace is not None and workspace.enabled
    workspace.record("list_dir", {"path": "."}, {"ok": True})

    assert _git(root, "config", "--local", "--get", "user.name").strip() == "Real Person"
    assert "their commit" in _git(root, "log", "--format=%s")
    # the agent's own commits are attributed to the agent, not to the user
    assert _git(root, "log", "-1", "--format=%an").strip() == "CoWork Agent"


def test_the_journal_survives_a_restart_and_keeps_counting(tmp_path):
    workspace = _ws(tmp_path)
    _registry(workspace).dispatch("list_dir", {"path": str(workspace.root)})

    reopened = _ws(tmp_path)
    _registry(reopened).dispatch("list_dir", {"path": str(workspace.root)})

    assert [e["seq"] for e in reopened.journal_entries()] == [1, 2]


# -- commits ---------------------------------------------------------------


def test_write_file_commits_exactly_that_file(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)

    registry.dispatch(
        "write_file",
        {"path": str(workspace.root / "notes.txt"), "content": "hello\n"},
    )

    changed = set(_git(workspace.root, "show", "--name-only", "--format=", "HEAD").split())
    # The journal rides along by design — it is the point of the commit.
    assert changed == {"notes.txt", JOURNAL_PATH}
    assert (workspace.root / "notes.txt").read_text() == "hello\n"


def test_a_mutating_command_is_committed_without_guessing_what_it_did(tmp_path):
    """No text heuristic decides whether a command mutated anything — git does,
    by looking at the tree afterwards."""
    workspace = _ws(tmp_path)
    registry = JournalingRegistry(workspace)
    from cowork_agent.tools import register_run_command

    register_run_command(registry, LocalEnvironment())

    registry.dispatch(
        "run_command",
        {"command": f"printf 'built\\n' > {workspace.root / 'artifact.txt'}"},
    )
    registry.dispatch("run_command", {"command": "true"})

    entries = workspace.journal_entries()
    assert entries[0]["changed_files"] == ["artifact.txt"]
    assert entries[1]["changed_files"] == []
    assert "artifact.txt" in _git(workspace.root, "ls-files")


def test_the_commit_message_carries_the_round_summary(tmp_path):
    workspace = _ws(tmp_path)
    workspace.record(
        "write_file",
        {"path": "a.txt"},
        {"ok": True},
        summary="Wrote the release notes",
    )
    assert workspace.history(limit=1)[0].subject == "Wrote the release notes"


def test_a_memory_write_is_versioned_like_any_other_change(tmp_path):
    """MEMORY.md is markdown in the workspace, so §7.7 gives it a diffable,
    revertible history for free — that is the point of putting it there."""
    from cowork_agent.memory import MemoryStore, register_memory_tool

    workspace = _ws(tmp_path)
    registry = JournalingRegistry(workspace)
    register_memory_tool(registry, MemoryStore(workspace.root / "memory"))

    result = registry.dispatch(
        "memory", {"action": "add", "file": "user", "text": "Prefers short answers."}
    )

    assert result.get("ok") is True
    assert workspace.journal_entries()[-1]["changed_files"] == ["memory/USER.md"]
    assert "memory/USER.md" in _git(workspace.root, "ls-files")


def test_batch_groups_a_round_into_one_commit(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    before = len(workspace.history(limit=50))

    with workspace.batch("round: three edits"):
        for index in range(3):
            registry.dispatch(
                "write_file",
                {"path": str(workspace.root / f"f{index}.txt"), "content": "x\n"},
            )

    history = workspace.history(limit=50)
    assert len(history) == before + 1
    assert history[0].subject == "round: three edits"
    # every action is still journaled individually
    assert len(workspace.journal_entries()) == 3


# -- rollback --------------------------------------------------------------


def test_rollback_restores_the_file_state_and_keeps_the_journal(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    kept = workspace.root / "kept.txt"
    later = workspace.root / "later.txt"

    registry.dispatch("write_file", {"path": str(kept), "content": "v1\n"})
    checkpoint = workspace.history(limit=1)[0].commit
    registry.dispatch("write_file", {"path": str(kept), "content": "v2\n"})
    registry.dispatch("write_file", {"path": str(later), "content": "new\n"})
    assert kept.read_text() == "v2\n"
    assert later.exists()

    result = workspace.rollback(commit=checkpoint)

    assert result["ok"] is True
    assert "NOT undone" in result["note"]
    # exact file state of the target commit
    assert kept.read_text() == "v1\n"
    assert not later.exists()
    # history was not rewritten: the rollback is a new commit on top
    history = workspace.history(limit=50)
    assert history[0].subject.startswith("undo: restore workspace to")
    assert checkpoint in [entry.commit for entry in history]
    # the journal still records everything that happened, plus the undo
    entries = workspace.journal_entries()
    assert [e["tool"] for e in entries] == [
        "write_file",
        "write_file",
        "write_file",
        "__rollback__",
    ]
    assert sorted(entries[-1]["changed_files"]) == ["kept.txt", "later.txt"]
    assert result["files"] == 2


def test_undo_the_last_n_actions(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    target = workspace.root / "count.txt"
    for value in ("1", "2", "3", "4"):
        registry.dispatch("write_file", {"path": str(target), "content": value})

    assert workspace.rollback(actions=3)["ok"] is True

    assert target.read_text() == "1"


def test_the_agent_can_undo_through_the_tool(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    target = workspace.root / "draft.txt"
    registry.dispatch("write_file", {"path": str(target), "content": "keep\n"})
    registry.dispatch("write_file", {"path": str(target), "content": "oops\n"})

    result = registry.dispatch("workspace_undo", {"actions": 1})

    assert result["ok"] is True
    assert target.read_text() == "keep\n"
    history = registry.dispatch("workspace_history", {"limit": 5})
    assert history["ok"] is True
    assert history["commits"][0]["commit"]


def test_rollback_to_an_unknown_commit_is_an_error_not_a_crash(tmp_path):
    workspace = _ws(tmp_path)
    assert workspace.rollback(commit="deadbeef")["ok"] is False
    assert workspace.rollback(actions=99)["ok"] is False


# -- secrets ---------------------------------------------------------------


def test_secrets_in_arguments_and_results_never_reach_the_journal(tmp_path):
    """The journal is committed, so a leak into it is permanent."""
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    token = "sk-live-6UqQ2m0PZk3xVt9wAb7Nc4Rd"
    api_key = "AIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY"

    registry.dispatch(
        "write_file",
        {
            "path": str(workspace.root / "config.env"),
            "content": f"OPENAI_API_KEY={token}\nGOOGLE_KEY={api_key}\n",
        },
    )
    workspace.record(
        "http_post",
        {"url": "https://api.example.com", "password": "hunter2-correct-horse"},
        {"ok": True, "echo": f"Authorization: Bearer {token}"},
    )

    journal = (workspace.root / JOURNAL_PATH).read_text()
    assert token not in journal
    assert api_key not in journal
    assert "hunter2-correct-horse" not in journal
    assert "[REDACTED]" in journal
    # the whole git history, not only the working copy
    log = _git(workspace.root, "log", "-p", "--", JOURNAL_PATH)
    assert token not in log
    assert "hunter2-correct-horse" not in log


def test_redaction_helpers_are_key_aware_and_shape_aware():
    args = redact_args(
        {
            "api_token": "not-obviously-a-secret",
            "note": "use sk-live-6UqQ2m0PZk3xVt9wAb7Nc4Rd for now",
            "nested": {"password": "swordfish"},
            "count": 3,
        }
    )
    assert args["api_token"] == "[REDACTED]"
    assert "sk-live" not in args["note"]
    assert args["nested"]["password"] == "[REDACTED]"
    assert args["count"] == 3


def test_long_arguments_and_results_are_capped(tmp_path):
    args = redact_args({"content": "x" * 5_000})
    assert len(args["content"]) < 700
    assert summarize_result({"stdout": "y" * 50_000}).endswith("chars]")


# -- the binary boundary ---------------------------------------------------


def test_a_large_binary_is_not_committed_but_the_text_is(tmp_path):
    workspace = _ws(tmp_path, max_blob_bytes=64 * 1024)
    (workspace.root / "notes.md").write_text("# real work\n")
    (workspace.root / "capture.bin").write_bytes(b"\x00" * (256 * 1024))

    workspace.record("run_command", {"command": "make capture"}, {"exit_code": 0})

    tracked = _git(workspace.root, "ls-files").split()
    assert "notes.md" in tracked
    assert "capture.bin" not in tracked
    assert "capture.bin" in _git(workspace.root, "log", "-1", "--format=%B")
    # still on disk — excluded from the repo, not deleted from the workspace
    assert (workspace.root / "capture.bin").exists()


def test_the_journal_is_never_dropped_for_being_large(tmp_path):
    """The size guard protects the repo from blobs. The record of what happened
    is not a blob — a long run must not silently stop being audited."""
    workspace = _ws(tmp_path, max_blob_bytes=1)
    (workspace.root / "note.txt").write_text("this is longer than one byte\n")

    workspace.record("list_dir", {"path": "."}, {"ok": True})

    tracked = _git(workspace.root, "ls-files").split()
    assert JOURNAL_PATH in tracked
    assert "note.txt" not in tracked


def test_media_patterns_are_ignored_by_default(tmp_path):
    workspace = _ws(tmp_path)
    (workspace.root / "clip.mp4").write_bytes(b"\x00" * 128)
    (workspace.root / "report.md").write_text("text\n")

    workspace.record("run_command", {"command": "ffmpeg"}, {"exit_code": 0})

    tracked = _git(workspace.root, "ls-files").split()
    assert "report.md" in tracked
    assert "clip.mp4" not in tracked


# -- degraded environments -------------------------------------------------


def test_without_git_the_feature_switches_off_and_the_loop_runs(tmp_path, monkeypatch):
    monkeypatch.setattr("cowork_agent.workspace_git.shutil.which", lambda _: None)
    workspace = GitWorkspace.open(tmp_path / "nogit")
    assert workspace is not None and workspace.enabled is False

    registry = JournalingRegistry(workspace)
    register_file_tools(registry, LocalEnvironment())
    register_workspace_tools(registry, workspace)

    target = tmp_path / "nogit" / "out.txt"
    result = registry.dispatch("write_file", {"path": str(target), "content": "hi\n"})

    assert result["ok"] is True
    assert target.read_text() == "hi\n"
    # a disabled workspace documents no undo tools to the model
    assert "workspace_undo" not in registry.names()
    assert workspace.history() == []
    assert workspace.rollback(actions=1)["ok"] is False


def test_a_directory_that_cannot_hold_a_repo_switches_off(tmp_path):
    blocker = tmp_path / "not-a-dir"
    blocker.write_text("i am a file\n")
    workspace = GitWorkspace.open(blocker)
    assert workspace is not None and workspace.enabled is False


def test_a_broken_repo_does_not_take_the_dispatch_down(tmp_path):
    workspace = _ws(tmp_path)
    registry = _registry(workspace)
    shutil.rmtree(workspace.root / ".git")

    result = registry.dispatch(
        "write_file",
        {"path": str(workspace.root / "after.txt"), "content": "still works\n"},
    )

    assert result["ok"] is True
    assert (workspace.root / "after.txt").read_text() == "still works\n"


def test_no_workspace_means_no_versioning():
    assert GitWorkspace.open(None) is None
    registry = JournalingRegistry(None)
    register_file_tools(registry, LocalEnvironment())
    assert registry.dispatch("list_dir", {"path": "."})["ok"] is True


# -- wiring ----------------------------------------------------------------


def test_build_runtime_versions_the_workspace_end_to_end(tmp_path):
    from cowork_agent.model import MockModelClient
    from cowork_agent.runtime import build_runtime

    workspace = tmp_path / "ws"
    target = workspace / "made.txt"
    call = "<tool_call>" + json.dumps(
        {
            "name": "write_file",
            "arguments": {"path": str(target), "content": "from the loop\n"},
        }
    ) + "</tool_call>"
    loop = build_runtime(
        MockModelClient([call, "done"]),
        db_path=str(tmp_path / "state.db"),
        environment=LocalEnvironment(),
        workspace=str(workspace),
        system_prompt="You are a CoWork agent.",
    )

    loop.run("session", "write a file")

    assert target.read_text() == "from the loop\n"
    entries = [
        json.loads(line)
        for line in (workspace / JOURNAL_PATH).read_text().splitlines()
        if line.strip()
    ]
    assert [e["tool"] for e in entries] == ["write_file"]
    assert "made.txt" in _git(workspace, "log", "-1", "--name-only", "--format=")


def test_build_runtime_can_leave_the_workspace_unversioned(tmp_path):
    from cowork_agent.model import MockModelClient
    from cowork_agent.runtime import build_runtime

    workspace = tmp_path / "plain"
    workspace.mkdir()
    build_runtime(
        MockModelClient(["done"]),
        db_path=str(tmp_path / "state.db"),
        environment=LocalEnvironment(),
        workspace=str(workspace),
        version_workspace=False,
    )
    assert not (workspace / ".git").exists()


def test_a_plain_registry_is_unaffected(tmp_path):
    """The journaling registry is a drop-in: the plain one keeps working."""
    registry = ToolRegistry()
    register_file_tools(registry, LocalEnvironment())
    target = tmp_path / "plain.txt"
    assert registry.dispatch("write_file", {"path": str(target), "content": "x"})["ok"]
