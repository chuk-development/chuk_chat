"""Checkpoints, rewind and fork (docs/WIRE_CONTRACT.md, "Checkpoints, rewind
and fork"; Hermes H30/H31)."""

from __future__ import annotations

import shutil
import subprocess

import pytest

from chuk_agents_runtime.checkpoints import (
    ForkError,
    checkpoint_after,
    find_checkpoint,
    fork_session,
    list_checkpoints,
    record_checkpoint,
)
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.workspace_git import GitWorkspace
from chuk_agents_runtime.workspace_tools import JournalingRegistry

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def _registry(root):
    ws = GitWorkspace.open(root)
    assert ws.enabled
    reg = JournalingRegistry(ws)

    def write_file(path: str, content: str) -> dict:
        (root / path).write_text(content)
        return {"ok": True}

    reg.register("write_file", {"type": "object", "properties": {}}, write_file)
    pinned = []
    reg.checkpoint_sink = lambda cid, info: pinned.append((cid, info.commit))
    return ws, reg, pinned


def test_the_first_write_of_a_run_pins_the_users_state(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    ws, reg, pinned = _registry(root)
    (root / "notes.txt").write_text("mine\n")  # the user's file, not committed yet
    reg.dispatch("write_file", {"path": "a.txt", "content": "one\n"})
    reg.dispatch("write_file", {"path": "a.txt", "content": "two\n"})
    assert len(pinned) == 1
    cid, commit = pinned[0]
    show = subprocess.run(["git", "-C", str(root), "show", f"{commit}:notes.txt"], capture_output=True, text=True)
    assert show.stdout == "mine\n"
    assert ws.agent_writes()["a.txt"] != "-"
    assert "notes.txt" not in ws.agent_writes()


def test_rewind_restores_the_agents_files(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    (root / "a.txt").write_text("before\n")
    ws, reg, pinned = _registry(root)
    reg.dispatch("write_file", {"path": "a.txt", "content": "agent\n"})
    reg.dispatch("write_file", {"path": "new.txt", "content": "made by agent\n"})
    out = ws.rewind(pinned[0][1])
    assert out["ok"] is True
    assert (root / "a.txt").read_text() == "before\n"
    assert not (root / "new.txt").exists()


def test_a_hand_edit_after_the_agent_blocks_a_safe_rewind(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    (root / "a.txt").write_text("l1\nl2\nl3\nl4\nl5\n")
    ws, reg, pinned = _registry(root)
    reg.dispatch("write_file", {"path": "a.txt", "content": "l1\nAGENT\nl3\nl4\nl5\n"})
    reg.dispatch("write_file", {"path": "b.txt", "content": "agent b\n"})
    # The user edits a.txt by hand afterwards (another line).
    (root / "a.txt").write_text("l1\nAGENT\nl3\nl4\nUSER\n")
    commit = pinned[0][1]

    refused = ws.rewind(commit)
    assert refused["ok"] is False and refused["conflicts"] == ["a.txt"]
    assert (root / "b.txt").exists()  # nothing changed

    kept = ws.rewind(commit, mode="keep_user_edits")
    assert kept["ok"] and kept["kept"] == ["a.txt"]
    assert not (root / "b.txt").exists()
    assert (root / "a.txt").read_text() == "l1\nAGENT\nl3\nl4\nUSER\n"


def test_merge_mode_keeps_the_hand_edit_and_undoes_the_agent(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    (root / "a.txt").write_text("l1\nl2\nl3\nl4\nl5\n")
    ws, reg, pinned = _registry(root)
    reg.dispatch("write_file", {"path": "a.txt", "content": "l1\nAGENT\nl3\nl4\nl5\n"})
    (root / "a.txt").write_text("l1\nAGENT\nl3\nl4\nUSER\n")
    out = ws.rewind(pinned[0][1], mode="merge")
    assert out["ok"] and out["merged"] == ["a.txt"]
    assert (root / "a.txt").read_text() == "l1\nl2\nl3\nl4\nUSER\n"


def test_force_restores_everything(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    (root / "a.txt").write_text("before\n")
    ws, reg, pinned = _registry(root)
    reg.dispatch("write_file", {"path": "a.txt", "content": "agent\n"})
    (root / "a.txt").write_text("user\n")
    out = ws.rewind(pinned[0][1], mode="force")
    assert out["ok"] and (root / "a.txt").read_text() == "before\n"
    assert ws.rewind(pinned[0][1], mode="bogus")["ok"] is False


def test_checkpoint_records_and_fork(tmp_path):
    store = StateStore(str(tmp_path / "state.db"))
    sid = store.route("t1")
    m1 = store.append_message(sid, "user", {"role": "user", "content": "first task"})
    m2 = store.append_message(sid, "assistant", {"role": "assistant", "content": "done 1"})
    store.append_event(sid, {"type": "file", "name": "x.txt", "data": "aGk="})
    m3 = store.append_message(sid, "user", {"role": "user", "content": "second task"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "done 2"})
    item, dropped = record_checkpoint(store, "t1", checkpoint_id="c2", commit="abc", run_id="r2", user_mid=m3)
    assert dropped == [] and item["prompt"] == "second task"
    assert list_checkpoints(store, "t1")[0]["id"] == "c2"
    assert find_checkpoint(store, "t1", "c2")["commit"] == "abc"
    assert checkpoint_after(store, "t1", m2)["id"] == "c2"
    assert checkpoint_after(store, "t1", m3) is None

    copied = fork_session(store, "t1", m2 + 1, "t1:fork")
    assert copied == 3
    new_id = store.resolve_session("t1:fork")
    rows = store.get_conversation(new_id, include_events=True)
    assert [r.content.get("content") for r in rows[:2]] == ["first task", "done 1"]
    assert store.event_blob(rows[2].id) == b"hi"
    with pytest.raises(ForkError):
        fork_session(store, "t1", m1, "t1:fork")
    with pytest.raises(ForkError):
        fork_session(store, "other", m1, "x")
    store.close()


def test_the_cap_drops_the_oldest(tmp_path):
    store = StateStore(str(tmp_path / "state.db"))
    store.route("t")
    from chuk_agents_runtime import checkpoints as cp

    dropped_all = []
    for i in range(cp.MAX_CHECKPOINTS + 2):
        _, dropped = record_checkpoint(store, "t", checkpoint_id=f"c{i}", commit="x")
        dropped_all += dropped
    assert dropped_all == ["c0", "c1"]
    assert len(list_checkpoints(store, "t")) == cp.MAX_CHECKPOINTS
    store.close()
