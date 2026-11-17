"""The app's ``agent_avatar_set`` (docs/agents/NOTIFICATIONS.md, CHAT-128):
the executor hands it to the host's agent hook and sends the host's
``agent_avatar`` answer as the terminal. Never a bare ``error``."""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _boot(tmp_path, *, hook=None):
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="avatar",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["unused"]),
        on_agent_frame=hook,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def test_the_avatar_reaches_the_host_and_its_answer_is_the_terminal(tmp_path):
    seen: list[dict] = []

    def hook(payload):
        seen.append(payload)
        return {"type": "agent_avatar", "agent_id": payload["agent_id"], "ok": True}

    executor, controller = _boot(tmp_path, hook=hook)
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "agent_avatar_set", "agent_id": "local:a", "png_b64": "iVBORw0KGgo="}
        )
        reply = controller.collect(rid, timeout=10.0)[-1]
    finally:
        executor.stop()
    assert [p["type"] for p in seen] == ["agent_avatar_set"]
    assert reply == {"type": "agent_avatar", "agent_id": "local:a", "ok": True}


def test_without_a_host_hook_the_avatar_is_answered_with_an_avatar_error(tmp_path):
    executor, controller = _boot(tmp_path)
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "agent_avatar_set", "agent_id": "local:a", "png_b64": "x"}
        )
        reply = controller.collect(rid, timeout=10.0)[-1]
    finally:
        executor.stop()
    assert reply["type"] == "agent_avatar"
    assert reply["ok"] is False and "not enabled" in reply["error"]
