"""Self-naming over the wire (docs/WIRE_CONTRACT.md, "Agent names"): the
agent's ``rename_self`` goes through the host's name hook like an app
``agent_rename`` and the new ``agent_list`` is pushed to every attached app;
``agent_delete`` reaches the hook and the answer carries ``deleted``."""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.executor import is_agent_session_key
from chuk_agents_executor.protocol import METHOD_EVENT, agent_delete_payload

from wiring import paired_channel


class _Controller(ControllerSession):
    """Keeps the host-originated events (no request id) the base drops."""

    pushed: list

    def _consume(self, frame):
        if frame.get("method") == METHOD_EVENT and "requestId" not in (frame.get("params") or {}):
            self.pushed.append(self._open(frame["params"]["frame"]))
            return
        super()._consume(frame)


class _Names:
    """Stands in for the host's name store and its ``_on_agent_frame``."""

    def __init__(self) -> None:
        self.names = {"local:desk:1:7": "saffron-osprey"}
        self.deleted: list[str] = []
        self.seen: list[dict] = []

    def hook(self, payload: dict):
        self.seen.append(payload)
        kind = payload.get("type")
        agent_id = payload.get("agent_id")
        if kind == "agent_rename":
            self.names[agent_id] = payload["name"]
        if kind == "agent_delete":
            self.names.pop(agent_id, None)
            self.deleted.append(agent_id)
        return {
            "type": "agent_list",
            "agents": [{"agent_id": k, "name": v, "host": False} for k, v in self.names.items()],
            "deleted": list(self.deleted),
        }

    def name_for(self, session_key: str) -> str:
        return self.names.get(session_key, "Your computer")


def _start(tmp_path, names: _Names, model_factory):
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="Chuk",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        workspace=str(workspace),
        on_agent_frame=names.hook,
        agent_name_for=names.name_for,
    )
    controller = _Controller(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    controller.pushed = []
    executor.start()
    return executor, controller


def test_agent_session_keys():
    assert is_agent_session_key("local:Mail:14:138509541")
    assert is_agent_session_key("host:cowork-host")
    assert not is_agent_session_key("default")
    assert not is_agent_session_key("room:abc")
    assert not is_agent_session_key("local:")


def test_rename_self_stores_the_name_and_pushes_the_list(tmp_path):
    names = _Names()
    model = MockModelClient([tool_call_response(("rename_self", {"name": "Shopping"})), "done"])
    executor, controller = _start(tmp_path, names, lambda: model)
    try:
        events = controller.collect(
            controller.send_task("call yourself Shopping", session_key="local:desk:1:7"), timeout=30.0
        )
        assert events[-1]["type"] == "done", events[-1]
    finally:
        executor.stop()
    assert names.seen == [{"type": "agent_rename", "agent_id": "local:desk:1:7", "name": "Shopping"}]
    lists = [p for p in controller.pushed if p.get("type") == "agent_list"]
    assert lists and lists[-1]["agents"] == [
        {"agent_id": "local:desk:1:7", "name": "Shopping", "host": False}
    ]
    # The model saw the agent's name in its prompt.
    assert '"saffron-osprey"' in model.calls[0][0]["content"]


def test_a_session_that_is_no_agent_gets_no_rename_tool(tmp_path):
    names = _Names()
    model = MockModelClient([tool_call_response(("rename_self", {"name": "X"})), "done"])
    executor, controller = _start(tmp_path, names, lambda: model)
    try:
        controller.collect(controller.send_task("hi", session_key="default"), timeout=30.0)
    finally:
        executor.stop()
    assert names.seen == []
    assert not [p for p in controller.pushed if p.get("type") == "agent_list"]


def test_agent_delete_reaches_the_hook_and_answers_with_deleted(tmp_path):
    names = _Names()
    executor, controller = _start(tmp_path, names, lambda: MockModelClient(["unused"]))
    try:
        events = controller.collect(
            controller.send_payload(agent_delete_payload(agent_id="local:desk:1:7")), timeout=10.0
        )
    finally:
        executor.stop()
    assert names.seen == [{"type": "agent_delete", "agent_id": "local:desk:1:7"}]
    assert events == [{"type": "agent_list", "agents": [], "deleted": ["local:desk:1:7"]}]
