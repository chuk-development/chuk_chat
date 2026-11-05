"""Checkpoint frames (docs/WIRE_CONTRACT.md, "Checkpoints, rewind and fork"):
``checkpoints_list``, ``checkpoint_rewind`` and ``thread_fork``, each
answered with one terminal frame."""

from __future__ import annotations

import shutil

import pytest
from chuk_agents_runtime import MockModelClient
from chuk_agents_runtime.checkpoints import record_checkpoint
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.workspace_git import GitWorkspace
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def _roundtrip(tmp_path, payloads):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    workspace = tmp_path / "ws"
    executor = Executor(
        name="cp",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["unused"]),
        workspace=str(workspace),
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        return [controller.collect(controller.send_payload(p), timeout=10.0) for p in payloads]
    finally:
        executor.stop()


def test_list_rewind_and_fork(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    (workspace / "a.txt").write_text("before\n")
    git = GitWorkspace.open(workspace)
    info = git.create_checkpoint("cp1")
    (workspace / "a.txt").write_text("agent\n")
    git.note_agent_writes(["a.txt"])
    store = StateStore(str(tmp_path / "state.db"))
    sid = store.route("t")
    m1 = store.append_message(sid, "user", {"role": "user", "content": "one"})
    m2 = store.append_message(sid, "assistant", {"role": "assistant", "content": "ok"})
    m3 = store.append_message(sid, "user", {"role": "user", "content": "change a.txt"})
    record_checkpoint(store, "t", checkpoint_id="cp1", commit=info.commit, run_id="r", user_mid=m3)
    store.close()

    listed, rewound, forked, bad = _roundtrip(
        tmp_path,
        [
            {"type": "checkpoints_list", "session_key": "t"},
            {"type": "checkpoint_rewind", "session_key": "t", "checkpoint_id": "cp1"},
            {"type": "thread_fork", "session_key": "t", "mid": m2, "new_session_key": "t2"},
            {"type": "checkpoint_rewind", "session_key": "t", "checkpoint_id": "nope"},
        ],
    )
    [reply] = listed
    assert reply["type"] == "checkpoints" and reply["items"][0]["id"] == "cp1"
    assert reply["items"][0]["prompt"] == "change a.txt"
    [reply] = rewound
    assert reply["type"] == "checkpoint_rewound" and reply["ok"] is True
    assert (workspace / "a.txt").read_text() == "before\n"
    [reply] = forked
    assert reply["type"] == "thread_forked" and reply["ok"] is True
    assert reply["new_session_key"] == "t2" and reply["copied"] == 2
    assert reply["checkpoint_id"] == "cp1"
    assert reply["workspace"]["ok"] is True
    [reply] = bad
    assert reply["ok"] is False and reply["error"] == "no such checkpoint"
    assert m1 < m2
