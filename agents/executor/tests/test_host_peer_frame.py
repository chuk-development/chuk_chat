"""The app's ``host_peer_*`` frames (CHAT-177): the executor hands them to
the host and sends its ``host_peer_list`` as the terminal. Never a bare
``error``."""

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
        name="peers",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["unused"]),
        on_host_peer_frame=hook,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def test_each_peer_frame_reaches_the_host_and_its_list_is_the_terminal(tmp_path):
    seen: list[str] = []

    def hook(payload):
        seen.append(payload["type"])
        return {"type": "host_peer_list", "ok": True, "peers": []}

    executor, controller = _boot(tmp_path, hook=hook)
    executor.start()
    try:
        replies = []
        for kind in ("host_peer_introduce", "host_peer_forget", "host_peer_list"):
            rid = controller.send_payload({"type": kind, "peer_host_id": "x"})
            replies.append(controller.collect(rid, timeout=10.0)[-1])
    finally:
        executor.stop()
    assert seen == ["host_peer_introduce", "host_peer_forget", "host_peer_list"]
    assert all(r == {"type": "host_peer_list", "ok": True, "peers": []} for r in replies)


def test_without_a_hook_the_answer_is_a_peer_list_error(tmp_path):
    executor, controller = _boot(tmp_path)
    executor.start()
    try:
        rid = controller.send_payload({"type": "host_peer_list"})
        reply = controller.collect(rid, timeout=10.0)[-1]
    finally:
        executor.stop()
    assert reply["type"] == "host_peer_list"
    assert reply["ok"] is False and "not enabled" in reply["error"]
