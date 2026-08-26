"""Task 5: the whole vertical, local and encrypted end to end, no real model.

An agent is created in the roster. A controller and an executor share a derived
channel key and each other's approved device keys. The controller sends an
encrypted task ("run ``echo hello > f.txt`` then tell me done"). Assert:

(a) the executor really ran it in a real sandbox — the file exists with the
    content — and
(b) the controller received encrypted result frames that decrypt to the final
    answer plus the tool activity.
"""

from __future__ import annotations

import pytest
from cowork_crypto import ApprovedDevices, CoworkFrameOpener, CoworkFrameRejected
from cowork_manager import RosterStore, RuntimeStatus, decode_frames

from cowork_executor import (
    ControllerSession,
    Executor,
    ExecutorSupervisor,
    loopback_pair,
)
from cowork_agent import MockModelClient

from wiring import KEY_VERSION, paired_channel


def _scripted_model() -> MockModelClient:
    """A fresh scripted model: first a run_command tool call, then a final answer.
    The tool call travels as a <tool_call> block in the assistant content — the
    one wire format a real backend model produces."""
    return MockModelClient(
        [
            '<tool_call>{"name":"run_command",'
            '"arguments":{"command":"echo hello > f.txt"}}</tool_call>',
            "done",
        ]
    )


def test_encrypted_end_to_end_local(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()

    # 1. Roster: one agent whose workspace is the sandbox workdir.
    roster = RosterStore(":memory:")
    agent = roster.create(workspace_dir=str(workspace), persona="do the thing")

    # 2. Paired crypto + a loopback link.
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()

    from cowork_sandbox import LocalEnvironment

    # 3. A real supervisor starts a real Executor for the roster agent.
    def factory(a):
        return Executor(
            name=a.name,
            endpoint=executor_ep,
            opener=channel.executor.opener,
            sealer=channel.executor.sealer,
            environment=LocalEnvironment(workdir=a.workspace_dir),
            db_path=str(tmp_path / "executor-state.db"),
            model_factory=_scripted_model,
            system_prompt="You are a CoWork coworker.",
        )

    supervisor = ExecutorSupervisor(roster, factory)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    try:
        state = supervisor.start(agent.id)
        assert state.status is RuntimeStatus.RUNNING

        request_id = controller.send_task(
            "run `echo hello > f.txt` then tell me done", session_key="thread-1"
        )
        events = controller.collect(request_id, timeout=15.0)
    finally:
        supervisor.stop(agent.id)

    # (a) the executor actually ran it in a real sandbox.
    produced = workspace / "f.txt"
    assert produced.exists(), "sandbox did not run the command"
    assert produced.read_text().strip() == "hello"

    # (b) the controller received decryptable result frames: the tool activity and
    #     the final answer.
    types = [e["type"] for e in events]
    assert types[-1] == "done"

    tool_events = [e for e in events if e["type"] == "tool"]
    assert len(tool_events) == 1
    tool = tool_events[0]
    assert tool["name"] == "run_command"
    assert tool["command"] == "echo hello > f.txt"
    assert tool["exit_code"] == 0
    assert tool["timed_out"] is False

    done = events[-1]
    assert done["final_answer"] == "done"
    assert done["reason"] == "finished"
    assert done["iterations"] >= 2
    # The spend field always rides the done frame (0 here: the mock model
    # reports no usage), so the app never has to guess whether the host sends it.
    assert done["tokens_spent"] == 0

    assert supervisor.status(agent.id).status is RuntimeStatus.STOPPED


def test_wire_frames_are_encrypted_and_authenticated(tmp_path):
    """A frame captured off the loopback wire is opaque to an unapproved opener:
    default-deny and real encryption, not plaintext on the wire."""
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()

    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    controller.send_task("secret prompt text", session_key="s")

    raw = executor_ep.recv(timeout=1.0)
    # The plaintext prompt never appears on the wire.
    assert b"secret prompt text" not in raw

    # The envelope is readable (relay is blind but structured); the sealed frame
    # inside is not openable by a stranger with an empty trust store.
    frames, _ = decode_frames(raw)
    frame_b64 = frames[0]["params"]["frame"]
    import base64

    sealed = base64.b64decode(frame_b64)
    stranger = CoworkFrameOpener(
        channel_key=channel.channel_key,
        key_version=KEY_VERSION,
        approved_devices=ApprovedDevices(),  # default deny
    )
    with pytest.raises(CoworkFrameRejected):
        stranger.open(sealed)

    # The executor's real opener (controller approved) opens it fine.
    opened = channel.executor.opener.open(sealed)
    assert b"secret prompt text" in opened


def test_unapproved_controller_is_rejected(tmp_path):
    """If the executor does not approve the controller's device, the task is
    rejected and the controller gets an encrypted ``error`` terminal."""
    workspace = tmp_path / "ws"
    workspace.mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()

    from cowork_sandbox import LocalEnvironment

    # Executor with an EMPTY approved set: it trusts no controller.
    empty_opener = CoworkFrameOpener(
        channel_key=channel.channel_key,
        key_version=KEY_VERSION,
        approved_devices=ApprovedDevices(),
    )
    executor = Executor(
        name="lonely",
        endpoint=executor_ep,
        opener=empty_opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "s.db"),
        model_factory=_scripted_model,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    executor.start()
    try:
        rid = controller.send_task("do it", session_key="s")
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    assert events, "controller received no terminal frame"
    assert events[-1]["type"] == "error"
    assert "rejected" in events[-1]["message"]
    # The command never ran.
    assert not (workspace / "f.txt").exists()
