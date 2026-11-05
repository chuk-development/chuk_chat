"""The Home dashboard over the wire (docs/DASHBOARD.md §5): ``dashboard_get``
and ``dashboard_op`` are answered with one terminal ``dashboard_state`` (or
``dashboard_error``), and every stored change, also one made by the agent's
``dashboard`` tool, is pushed as a ``dashboard_state`` to the attached app."""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_runtime.dashboard import DashboardStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.protocol import METHOD_EVENT

from wiring import paired_channel


class _Controller(ControllerSession):
    """Keeps the host-originated events (no request id) the base drops."""

    pushed: list

    def _consume(self, frame):
        if frame.get("method") == METHOD_EVENT and "requestId" not in (frame.get("params") or {}):
            self.pushed.append(self._open(frame["params"]["frame"]))
            return
        super()._consume(frame)


def _start(tmp_path, model_factory=lambda: MockModelClient(["unused"]), **kw):
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
        **kw,
    )
    controller = _Controller(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    controller.pushed = []
    executor.start()
    return executor, controller


def _ask(controller, payload):
    events = controller.collect(controller.send_payload(payload), timeout=10.0)
    assert len(events) == 1, events
    return events[0]


def test_get_op_duplicate_and_refused_round_trip(tmp_path):
    store = DashboardStore(str(tmp_path / "state.db"))
    store.apply("add", {"widget": {"type": "tracker", "title": "Push-ups", "goal": 100}}, by="Chuk")
    executor, controller = _start(tmp_path)
    try:
        state = _ask(controller, {"type": "dashboard_get"})
        assert state["type"] == "dashboard_state"
        assert state["dashboard"]["version"] == 1
        assert [w["id"] for w in state["dashboard"]["widgets"]] == ["push-ups"]

        op = {"type": "dashboard_op", "op_id": "op-1", "action": "log", "id": "push-ups", "value": 10}
        applied = _ask(controller, op)
        assert applied["op_id"] == "op-1"
        assert applied["dashboard"]["version"] == 2
        widget = applied["dashboard"]["widgets"][0]
        assert widget["by"] == "You" and widget["entries"][0]["value"] == 10

        again = _ask(controller, op)
        assert again["type"] == "dashboard_state" and again["op_id"] == "op-1"
        assert again["dashboard"]["version"] == 2
        assert len(again["dashboard"]["widgets"][0]["entries"]) == 1

        refused = _ask(controller, {"type": "dashboard_op", "op_id": "op-2", "action": "check",
                                    "id": "push-ups", "item": "x", "done": True})
        assert refused["type"] == "dashboard_error" and refused["op_id"] == "op-2"
        assert "checklist" in refused["message"]
        assert store.get()["version"] == 2
    finally:
        executor.stop()
    # The applied op was also pushed to every attached app, once.
    assert [p["dashboard"]["version"] for p in controller.pushed
            if p.get("type") == "dashboard_state"] == [2]


def test_tool_write_pushes_dashboard_state(tmp_path):
    model = MockModelClient([
        tool_call_response(("dashboard", {"action": "add", "widget": {
            "type": "tracker", "title": "Water", "unit": "glasses", "goal": 8, "icon": "water"}})),
        tool_call_response(("dashboard", {"action": "log", "id": "water", "value": 2})),
        "done",
    ])
    executor, controller = _start(tmp_path, model_factory=lambda: model)
    try:
        events = controller.collect(controller.send_task("track water", session_key="s1"), timeout=30.0)
        assert events[-1]["type"] == "done", events[-1]
    finally:
        executor.stop()
    states = [p for p in controller.pushed if p.get("type") == "dashboard_state"]
    assert [s["dashboard"]["version"] for s in states] == [1, 2]
    widget = states[-1]["dashboard"]["widgets"][0]
    assert widget["by"] == "Chuk" and widget["entries"][0]["value"] == 2


def test_host_store_is_shared_and_the_host_pushes(tmp_path):
    """With the host's store handed in the executor does not push itself: the
    host's listener does, once per change, for every agent of the host."""
    shared = DashboardStore(str(tmp_path / "host.db"))
    heard = []
    shared.add_listener(lambda doc: heard.append(doc["version"]))
    model = MockModelClient([
        tool_call_response(("dashboard", {"action": "add", "widget": {"type": "note", "title": "Hi"}})),
        "done",
    ])
    executor, controller = _start(
        tmp_path, model_factory=lambda: model, dashboard=shared,
        agent_name_for=lambda key: f"agent {key}",
    )
    try:
        controller.collect(controller.send_task("note", session_key="s9"), timeout=30.0)
    finally:
        executor.stop()
    assert heard == [1]
    assert shared.get()["widgets"][0]["by"] == "agent s9"
    assert not [p for p in controller.pushed if p.get("type") == "dashboard_state"]
