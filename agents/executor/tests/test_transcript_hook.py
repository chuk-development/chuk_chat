"""The executor keeps ``<workspace>/transcript/`` current: after every tool
call and after the finished turn (bead cowork-2tq.2)."""

from __future__ import annotations

import stat

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_runtime.memory import MemoryStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _model() -> MockModelClient:
    return MockModelClient(
        [tool_call_response(("run_command", {"command": "echo hi"})), "done"]
    )


def test_a_run_lands_in_the_workspace_transcript_read_only(tmp_path, monkeypatch):
    # With a workspace the runtime enables memory; keep this test offline.
    monkeypatch.setattr(MemoryStore, "recall_messages", lambda self, q, **k: [])
    monkeypatch.setattr(MemoryStore, "observe_turn", lambda self, *a, **k: None)
    workspace = tmp_path / "ws"
    workspace.mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="scribe",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "s.db"),
        model_factory=_model,
        workspace=str(workspace),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        rid = controller.send_task("say hi", session_key="thread-1")
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()
    assert events[-1]["type"] == "done"

    transcript = workspace / "transcript" / "thread-1.md"
    text = transcript.read_text(encoding="utf-8")
    assert "· user\n\nsay hi" in text
    assert "**call** `run_command`" in text and "echo hi" in text
    assert "**result** `run_command`" in text
    assert text.rstrip().endswith("done")
    # Read-only between appends: the agent's shell cannot rm or overwrite it.
    assert stat.S_IMODE(transcript.stat().st_mode) == 0o444
    assert stat.S_IMODE((workspace / "transcript").stat().st_mode) == 0o555
    # The cursor is at the store's last row for the thread.
    store = StateStore(str(tmp_path / "s.db"))
    try:
        last = store.max_message_id(store.route("thread-1"))
    finally:
        store.close()
    import json

    assert json.loads((workspace / "transcript" / ".cursor.json").read_text())["thread-1"] == last


def test_no_workspace_means_no_transcript(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="quiet",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path)),
        db_path=str(tmp_path / "s.db"),
        model_factory=lambda: MockModelClient(["ok"]),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        rid = controller.send_task("hi", session_key="t")
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()
    assert events[-1]["type"] == "done"
    assert not (tmp_path / "transcript").exists()
