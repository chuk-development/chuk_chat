"""What did one run change, and undo it (docs/WIRE_CONTRACT.md, "What did it
do: run changes and undo", bead chuk_chat-4qry).

Every test builds a real git repo under ``tmp_path``. A "run" is a
:class:`GitWorkspace` with :meth:`begin_run` called, writing files and
journaling each write the way the registry does.
"""

import shutil
import subprocess

import pytest

from chuk_agents_runtime.run_changes import (
    CONFLICT_CHANGED_LATER,
    CONFLICT_UNCOMMITTED,
    REASON_ALREADY_UNDONE,
    REASON_CONFLICTS,
    REASON_NO_CHANGES,
    REASON_NO_HISTORY,
    REASON_RUN_ACTIVE,
    SKIP_NOT_IN_RUN,
    SKIP_OUTSIDE,
    has_history,
    run_change_summary,
    run_changes,
    undo_run,
)
from chuk_agents_runtime.workspace_git import GitWorkspace

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")


def _git(root, *args) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=True
    ).stdout


class _Run:
    """One run of the agent in ``root``: every write is one journaled commit."""

    def __init__(self, root, run_id: str) -> None:
        self.root = root
        self.ws = GitWorkspace.open(root)
        assert self.ws is not None and self.ws.enabled
        self.ws.begin_run(run_id)

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        self.ws.record("write_file", {"path": path}, {"ok": True})

    def delete(self, path: str) -> None:
        (self.root / path).unlink()
        self.ws.record("run_command", {"command": f"rm {path}"}, {"ok": True})

    def read(self, path: str) -> None:
        self.ws.record("read_file", {"path": path}, {"ok": True})


@pytest.fixture
def root(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    (workspace / "keep.txt").write_text("one\ntwo\n", encoding="utf-8")
    (workspace / "old.txt").write_text("old\n", encoding="utf-8")
    # The user's files exist before the first run: the repo adopts them.
    assert GitWorkspace.open(workspace).enabled
    return workspace


def _by_path(body: dict) -> dict[str, dict]:
    return {f["path"]: f for f in body["files"]}


# -- listing ---------------------------------------------------------------------


def test_changes_lists_added_modified_deleted_with_line_counts(root):
    run = _Run(root, "run-a")
    run.write("keep.txt", "one\nTWO\nthree\n")
    run.write("new/notes.md", "a\nb\n")
    run.read("keep.txt")  # a journal-only commit: no file
    run.delete("old.txt")

    body = run_changes(root, "run-a")
    files = _by_path(body)
    assert set(files) == {"keep.txt", "new/notes.md", "old.txt"}
    assert files["keep.txt"]["change"] == "modified"
    assert (files["keep.txt"]["additions"], files["keep.txt"]["deletions"]) == (2, 1)
    assert files["new/notes.md"]["change"] == "added"
    assert files["new/notes.md"]["additions"] == 2
    assert files["old.txt"]["change"] == "deleted"
    assert files["old.txt"]["deletions"] == 1
    assert all(f["undoable"] for f in body["files"])
    assert body["undoable"] is True and "reason" not in body
    # The agent's journal is never a "change".
    assert not any(p.startswith(".agents/") for p in files)
    # Three commits changed files; four actions in all.
    assert len(body["commits"]) == 3 and body["actions"] == 4
    assert all(c["files"] >= 1 for c in body["commits"])
    assert body["summary"] == {"files": 3, "additions": 4, "deletions": 2, "undone": 0}
    assert run_change_summary(root, "run-a") == body["summary"]


def test_a_file_created_and_deleted_in_one_run_is_no_change(root):
    run = _Run(root, "run-a")
    run.write("tmp.txt", "x\n")
    run.delete("tmp.txt")
    body = run_changes(root, "run-a")
    assert body["files"] == [] and body["reason"] == REASON_NO_CHANGES
    assert run_change_summary(root, "run-a") is None


def test_user_edits_before_the_run_are_not_the_runs(root):
    # The user edits a file by hand between runs; the next run starts.
    (root / "keep.txt").write_text("hand edit\n", encoding="utf-8")
    run = _Run(root, "run-a")
    run.write("agent.txt", "mine\n")

    files = _by_path(run_changes(root, "run-a"))
    assert set(files) == {"agent.txt"}
    log = _git(root, "log", "--format=%s%n%b")
    assert "checkpoint: changes outside the agent" in log

    assert undo_run(root, "run-a")["ok"] is True
    # The undo reverted the agent's file and left the hand edit alone.
    assert not (root / "agent.txt").exists()
    assert (root / "keep.txt").read_text(encoding="utf-8") == "hand edit\n"


def test_unknown_run_and_journal_only_run_have_nothing(root):
    assert run_changes(root, "nope")["reason"] == REASON_NO_CHANGES
    run = _Run(root, "run-r")
    run.read("keep.txt")
    body = run_changes(root, "run-r")
    assert body["reason"] == REASON_NO_CHANGES and body["undoable"] is False
    undo = undo_run(root, "run-r")
    assert undo["ok"] is False and undo["code"] == REASON_NO_CHANGES


def test_run_id_must_match_exactly(root):
    _Run(root, "abc").write("a.txt", "a\n")
    _Run(root, "abcdef").write("b.txt", "b\n")
    assert set(_by_path(run_changes(root, "abc"))) == {"a.txt"}
    assert set(_by_path(run_changes(root, "abcdef"))) == {"b.txt"}


# -- undo ------------------------------------------------------------------------


def test_undo_whole_run_is_a_new_commit(root):
    run = _Run(root, "run-a")
    run.write("keep.txt", "changed\n")
    run.write("new.txt", "new\n")
    run.delete("old.txt")
    head_before = _git(root, "rev-parse", "HEAD").strip()
    commits_before = int(_git(root, "rev-list", "--count", "HEAD"))

    result = undo_run(root, "run-a")
    assert result["ok"] is True, result
    assert result["reverted"] == ["keep.txt", "new.txt", "old.txt"]
    assert result["conflicts"] == []
    assert (root / "keep.txt").read_text(encoding="utf-8") == "one\ntwo\n"
    assert not (root / "new.txt").exists()
    assert (root / "old.txt").read_text(encoding="utf-8") == "old\n"
    # History is kept: the undo is one more commit on top.
    assert int(_git(root, "rev-list", "--count", "HEAD")) == commits_before + 1
    assert _git(root, "merge-base", "--is-ancestor", head_before, "HEAD") == ""
    body = _git(root, "log", "-1", "--format=%B")
    assert "undo-of: run-a" in body and "run-id:" not in body
    assert _git(root, "status", "--porcelain") == ""
    # The journal records the undo.
    journal = (root / ".agents" / "journal.jsonl").read_text(encoding="utf-8")
    assert "__run_undo__" in journal

    after = run_changes(root, "run-a")
    assert after["undoable"] is False and after["reason"] == REASON_ALREADY_UNDONE
    assert all(f.get("undone") for f in after["files"])
    assert run_change_summary(root, "run-a")["undone"] == 3
    again = undo_run(root, "run-a")
    assert again["ok"] is False and again["code"] == REASON_ALREADY_UNDONE


def test_undo_some_paths_only(root):
    run = _Run(root, "run-a")
    run.write("a.txt", "a\n")
    run.write("b.txt", "b\n")
    run.write("keep.txt", "k\n")

    result = undo_run(root, "run-a", paths=["./a.txt", "keep.txt", "missing.txt", "../etc/passwd"])
    assert result["ok"] is True, result
    assert result["reverted"] == ["a.txt", "keep.txt"]
    assert {(s["path"], s["reason"]) for s in result["skipped"]} == {
        ("missing.txt", SKIP_NOT_IN_RUN),
        ("../etc/passwd", SKIP_OUTSIDE),
    }
    assert not (root / "a.txt").exists()
    assert (root / "b.txt").read_text(encoding="utf-8") == "b\n"
    assert (root / "keep.txt").read_text(encoding="utf-8") == "one\ntwo\n"

    files = _by_path(run_changes(root, "run-a"))
    assert files["a.txt"].get("undone") and files["keep.txt"].get("undone")
    assert files["b.txt"]["undoable"] is True
    # The rest can still be undone later.
    assert undo_run(root, "run-a")["reverted"] == ["b.txt"]


def test_conflict_with_a_later_run_refuses_and_force_overrides(root):
    first = _Run(root, "run-1")
    first.write("shared.txt", "from run 1\n")
    first.write("solo.txt", "only run 1\n")
    second = _Run(root, "run-2")
    second.write("shared.txt", "from run 2\n")

    body = run_changes(root, "run-1")
    files = _by_path(body)
    assert files["shared.txt"]["undoable"] is False
    assert files["shared.txt"]["conflict"] == {
        "path": "shared.txt",
        "reason": CONFLICT_CHANGED_LATER,
        "runs": ["run-2"],
    }
    assert files["solo.txt"]["undoable"] is True
    # Partly undoable: the conflicts are listed next to it.
    assert body["undoable"] is True and body["conflicts"][0]["path"] == "shared.txt"

    refused = undo_run(root, "run-1")
    assert refused["ok"] is False and refused["code"] == REASON_CONFLICTS
    assert [c["path"] for c in refused["conflicts"]] == ["shared.txt"]
    assert "shared.txt" in refused["error"]
    # Nothing was touched by the refusal.
    assert (root / "solo.txt").exists()
    assert (root / "shared.txt").read_text(encoding="utf-8") == "from run 2\n"

    # Only the clean file: fine.
    clean = undo_run(root, "run-1", paths=["solo.txt"])
    assert clean["ok"] is True and clean["reverted"] == ["solo.txt"]

    forced = undo_run(root, "run-1", force=True)
    assert forced["ok"] is True and forced["forced"] is True
    assert forced["reverted"] == ["shared.txt"]
    assert not (root / "shared.txt").exists()  # run 1 created it
    # Run 2's version is still in the history.
    assert "from run 2" in _git(root, "log", "-p", "--", "shared.txt")


def test_an_undone_later_run_does_not_block(root):
    _Run(root, "run-1").write("f.txt", "one\n")
    _Run(root, "run-2").write("f.txt", "two\n")
    assert undo_run(root, "run-2")["ok"] is True
    # f.txt is back to what run 1 left: run 1 can be undone cleanly.
    body = run_changes(root, "run-1")
    assert _by_path(body)["f.txt"]["undoable"] is True
    assert undo_run(root, "run-1")["ok"] is True
    assert not (root / "f.txt").exists()


def test_uncommitted_user_edit_is_a_conflict_and_survives_force(root):
    _Run(root, "run-a").write("doc.txt", "agent\n")
    (root / "doc.txt").write_text("agent\nplus my edit\n", encoding="utf-8")

    files = _by_path(run_changes(root, "run-a"))
    assert files["doc.txt"]["conflict"]["reason"] == CONFLICT_UNCOMMITTED
    refused = undo_run(root, "run-a")
    assert refused["ok"] is False and refused["code"] == REASON_CONFLICTS
    assert (root / "doc.txt").read_text(encoding="utf-8") == "agent\nplus my edit\n"

    forced = undo_run(root, "run-a", force=True)
    assert forced["ok"] is True
    assert not (root / "doc.txt").exists()
    # The user's edit was committed before the undo: recoverable.
    assert "plus my edit" in _git(root, "log", "-p", "--", "doc.txt")


def test_busy_workspace_lists_but_does_not_undo(root):
    _Run(root, "run-a").write("x.txt", "x\n")
    body = run_changes(root, "run-a", busy=True)
    assert body["files"] and body["undoable"] is False
    assert body["reason"] == REASON_RUN_ACTIVE
    result = undo_run(root, "run-a", busy=True)
    assert result["ok"] is False and result["code"] == REASON_RUN_ACTIVE
    assert (root / "x.txt").exists()


def test_no_git_workspace_is_nothing_to_undo(tmp_path):
    plain = tmp_path / "plain"
    plain.mkdir()
    (plain / "file.txt").write_text("hi\n", encoding="utf-8")
    assert has_history(plain) is False
    body = run_changes(plain, "run-a")
    assert body == {
        "run_id": "run-a",
        "files": [],
        "commits": [],
        "undoable": False,
        "reason": REASON_NO_HISTORY,
    }
    result = undo_run(plain, "run-a")
    assert result["ok"] is False and result["code"] == REASON_NO_HISTORY
    assert run_change_summary(plain, "run-a") is None
    # Nothing was created by asking.
    assert not (plain / ".git").exists()
    assert run_changes(None, "run-a")["reason"] == REASON_NO_HISTORY
    assert run_changes(tmp_path / "missing", "run-a")["reason"] == REASON_NO_HISTORY


def test_a_subdirectory_of_another_repo_is_not_history(tmp_path):
    outer = tmp_path / "outer"
    GitWorkspace.open(outer)
    inner = outer / "inner"
    inner.mkdir()
    assert has_history(inner) is False


def test_symlinked_directory_leading_out_is_skipped(tmp_path, root):
    outside = tmp_path / "outside"
    outside.mkdir()
    run = _Run(root, "run-a")
    run.write("inside.txt", "in\n")
    (root / "link").symlink_to(outside, target_is_directory=True)
    run.ws.record("run_command", {"command": "ln -s"}, {"ok": True})
    (outside / "victim.txt").write_text("keep me\n", encoding="utf-8")
    result = undo_run(root, "run-a", paths=["link/victim.txt"])
    assert result["ok"] is False
    assert (outside / "victim.txt").read_text(encoding="utf-8") == "keep me\n"


def test_subagent_merge_counts_for_the_run(root):
    run = _Run(root, "run-a")
    info = run.ws.create_worktree("child")
    assert info is not None
    from pathlib import Path

    (Path(info.path) / "child.txt").write_text("from child\n", encoding="utf-8")
    merged = run.ws.merge_worktree(info)
    assert merged["ok"] is True, merged
    files = _by_path(run_changes(root, "run-a"))
    assert files["child.txt"]["change"] == "added"
    assert undo_run(root, "run-a")["reverted"] == ["child.txt"]
    assert not (root / "child.txt").exists()


def test_file_names_with_spaces_and_unicode(root):
    run = _Run(root, "run-a")
    run.write("my notes/über [1].txt", "x\n")
    files = _by_path(run_changes(root, "run-a"))
    assert "my notes/über [1].txt" in files
    result = undo_run(root, "run-a", paths=["my notes/über [1].txt"])
    assert result["ok"] is True and result["reverted"] == ["my notes/über [1].txt"]
    assert not (root / "my notes" / "über [1].txt").exists()


def test_a_glob_like_file_name_is_taken_literally(root):
    run = _Run(root, "run-a")
    run.write("ab.txt", "plain\n")
    run.write("a*.txt", "star\n")
    result = undo_run(root, "run-a", paths=["a*.txt"])
    assert result["ok"] is True and result["reverted"] == ["a*.txt"]
    assert not (root / "a*.txt").exists()
    assert (root / "ab.txt").read_text(encoding="utf-8") == "plain\n"
