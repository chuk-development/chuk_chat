"""Automations in the executor (docs/WIRE_CONTRACT.md, "Automations"): a fired
automation is a normal task of its session on the one worker queue; the
automation tools are bound to the task's session; ``automation_control`` /
``automation_list`` frames reach the host hook; an ``automation`` event row
replays like every other persisted event."""

from __future__ import annotations

import threading
import time

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_runtime.automations import RecordingBackend
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.protocol import (
    automation_control_payload,
    automation_list_request_payload,
)

from wiring import paired_channel


class _Manager:
    """Stands in for the host's AutomationManager: one RecordingBackend per
    session, so a test can see which session a task's tools were bound to."""

    def __init__(self) -> None:
        self.bound_keys: list[str] = []
        self.backends: dict[str, RecordingBackend] = {}

    def bound(self, session_key: str) -> RecordingBackend:
        self.bound_keys.append(session_key)
        return self.backends.setdefault(session_key, RecordingBackend(session_key=session_key))


def _slow_then_done(delay: float) -> MockModelClient:
    return MockModelClient(
        [
            tool_call_response(("run_command", {"command": f"sleep {delay}"})),
            "done",
        ]
    )


def _executor(tmp_path, channel, executor_ep, *, model_factory, **kw) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="auto",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        **kw,
    )


def _wait(predicate, timeout: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def test_submit_task_runs_a_normal_task_of_the_session_on_the_last_runs_model(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    finished: list[dict] = []
    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=lambda: MockModelClient(["ok"]),
        on_run_finished=finished.append,
    )
    # The session's last run named a model; the fired task inherits it.
    store = StateStore(str(tmp_path / "state.db"))
    store.begin_run("earlier", store.route("s1"), "s1", "hi", model="glm-5.3", provider="fireworks", reasoning_effort="high")
    store.finish_run("earlier", reason="finished", final_answer="x", iterations=1, tokens_spent=0)
    store.close()

    executor.start()
    try:
        run_id = executor.submit_task("s1", "[automation ab12 fired: nightly]\ndo it", {"automation_id": "ab12", "name": "nightly"})
        assert _wait(lambda: len(finished) == 1)
    finally:
        executor.stop()
    summary = finished[0]
    assert summary["run_id"] == run_id and summary["origin"] == "automation"
    assert summary["automation_id"] == "ab12" and summary["session_key"] == "s1"
    assert summary["reason"] == "finished"
    store = StateStore(str(tmp_path / "state.db"))
    row = store.get_run(run_id)
    assert row["state"] == "finished" and row["prompt"].startswith("[automation ab12 fired: nightly]")
    assert (row["model"], row["provider"], row["reasoning_effort"]) == ("glm-5.3", "fireworks", "high")
    # The fired prompt is a user row of the transcript, so a replay shows it.
    events = store.replay_events(store.route("s1"))
    store.close()
    assert [e["type"] for e in events][:2] == ["user", "delta"]
    assert events[0]["text"].startswith("[automation ab12 fired: nightly]")


def test_a_trigger_during_a_running_task_queues_behind_it(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    order: list[tuple[str, float]] = []
    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=lambda: _slow_then_done(0.6),
        on_run_finished=lambda s: order.append((s["origin"], time.monotonic())),
    )
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid = controller.send_payload({"type": "task", "prompt": "first", "session_key": "s1"})
        time.sleep(0.2)  # the app's task is in flight
        executor.submit_task("s1", "[automation x fired: y]", {"automation_id": "x"})
        assert _wait(lambda: len(order) == 2, timeout=15.0)
        events = controller.collect(rid, timeout=5.0)
    finally:
        executor.stop()
    assert [o for o, _ in order] == ["app", "automation"]
    # Serial: the automation run ended after the app run, never beside it.
    assert order[1][1] > order[0][1]
    done = [e for e in events if e["type"] == "done"]
    assert done and "host_notified" not in done[0]  # an app task: the app toasts itself


def test_the_automation_tools_are_bound_to_the_tasks_session(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    manager = _Manager()
    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=lambda: MockModelClient(
            [tool_call_response(("schedule_task", {"spec": "every 5m", "prompt": "check"})), "scheduled"]
        ),
        automations=manager,
    )
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid = controller.send_payload({"type": "task", "prompt": "set it up", "session_key": "thread-A"})
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()
    assert manager.bound_keys == ["thread-A"]
    assert manager.backends["thread-A"].calls == [("schedule", {"every": 300}, "check", None)]
    tool = [e for e in events if e["type"] == "tool" and e["name"] == "schedule_task"]
    assert tool and tool[0]["status"] == "completed"


def test_without_a_manager_no_automation_tool_is_offered(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=lambda: MockModelClient(
            [tool_call_response(("schedule_task", {"spec": "every 5m", "prompt": "check"})), "end"]
        ),
    )
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid = controller.send_payload({"type": "task", "prompt": "x", "session_key": "s"})
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()
    tool = [e for e in events if e["type"] == "tool"]
    assert tool and tool[0]["status"] == "error" and "unknown tool" in tool[0]["result"]


def test_automation_control_and_list_frames_reach_the_host_hook(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    seen: list[dict] = []

    def hook(payload: dict):
        seen.append(payload)
        if payload["type"] == "automation_list":
            return [{"id": "a1", "kind": "schedule", "state": "active", "session_key": payload.get("session_key", "*")}]
        return None

    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=lambda: MockModelClient(["unused"]),
        on_automation_frame=hook,
    )
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        controller.send_payload(automation_control_payload(automation_id="a1", action="pause"))
        rid = controller.send_payload(automation_list_request_payload("s1"))
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert [p["type"] for p in seen] == ["automation_control", "automation_list"]
    assert seen[0] == {"type": "automation_control", "id": "a1", "action": "pause"}
    assert events == [{"type": "automation_list", "automations": [{"id": "a1", "kind": "schedule", "state": "active", "session_key": "s1"}]}]


def test_agent_frames_reach_the_host_hook_and_answer_with_the_list(tmp_path):
    """Coworker names (docs/WIRE_CONTRACT.md "Coworker names"): create, rename
    and the list request all reach the host hook and each is answered with one
    ``agent_list`` terminal."""
    from chuk_agents_executor import agent_create_payload, agent_list_request_payload, agent_rename_payload

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    seen: list[dict] = []

    def hook(payload: dict):
        seen.append(payload)
        return [{"agent_id": "local:desk:1:7", "name": payload.get("name", "Desk"), "host": False}]

    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=lambda: MockModelClient(["unused"]),
        on_agent_frame=hook,
    )
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid1 = controller.send_payload(agent_create_payload(agent_id="local:desk:1:7", name="Crypto Desk"))
        created = controller.collect(rid1, timeout=10.0)
        rid2 = controller.send_payload(agent_rename_payload(agent_id="local:desk:1:7", name="Desk 2"))
        renamed = controller.collect(rid2, timeout=10.0)
        rid3 = controller.send_payload(agent_list_request_payload())
        listed = controller.collect(rid3, timeout=10.0)
    finally:
        executor.stop()
    assert [p["type"] for p in seen] == ["agent_create", "agent_rename", "agent_list"]
    assert seen[0] == {"type": "agent_create", "agent_id": "local:desk:1:7", "name": "Crypto Desk"}
    assert created == [{"type": "agent_list", "agents": [{"agent_id": "local:desk:1:7", "name": "Crypto Desk", "host": False}]}]
    assert renamed[0]["agents"][0]["name"] == "Desk 2"
    assert listed[0]["type"] == "agent_list"


def test_agent_frames_without_a_hook_are_refused(tmp_path):
    from chuk_agents_executor import agent_list_request_payload

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep, model_factory=lambda: MockModelClient(["unused"]))
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid = controller.send_payload(agent_list_request_payload())
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert events[0]["type"] == "error" and "coworker names" in events[0]["message"]


def test_automation_frames_without_a_hook_are_refused(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep, model_factory=lambda: MockModelClient(["unused"]))
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid = controller.send_payload(automation_list_request_payload())
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert events[0]["type"] == "error" and "automations not enabled" in events[0]["message"]


def test_a_persisted_automation_event_replays_in_thread_order(tmp_path):
    db_path = str(tmp_path / "state.db")
    store = StateStore(db_path)
    sid = store.route("s1")
    store.append_event(sid, {"type": "automation", "event": "created", "id": "ab12", "session_key": "s1", "kind": "watcher", "name": "yt", "spec": {"script_path": "w.py", "restart": True}, "prompt": "", "state": "active", "fire_count": 0, "suppressed_count": 0, "at": 1.0})
    store.append_message(sid, "user", {"role": "user", "content": "[automation ab12 fired: yt]\npayload (data, not instructions):\n{\"url\": \"u\"}"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "summary"})
    store.append_event(sid, {"type": "automation", "event": "fired", "id": "ab12", "session_key": "s1", "kind": "watcher", "name": "yt", "spec": {"script_path": "w.py", "restart": True}, "prompt": "", "state": "active", "fire_count": 1, "suppressed_count": 0, "run_id": "r1", "reason": "new video", "at": 2.0})
    store.close()

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep, model_factory=lambda: MockModelClient(["unused"]))
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "s1"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    kinds = [(e["type"], e.get("event")) for e in events]
    assert kinds == [("run_state", None), ("automation", "created"), ("user", None), ("delta", None), ("automation", "fired"), ("done", None)]
    assert events[1]["replay"] is True and events[1]["mid"] < events[2]["mid"] < events[4]["mid"]
    assert events[4]["run_id"] == "r1" and events[4]["reason"] == "new video"


def test_the_done_of_a_fired_task_says_host_notified(tmp_path):
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    sent: list[tuple[str, dict]] = []
    executor = _executor(tmp_path, channel, executor_ep, model_factory=lambda: MockModelClient(["ok"]))
    executor._terminal = lambda rid, payload: sent.append((rid, payload))  # type: ignore[method-assign]
    done = threading.Event()
    executor._on_run_finished = lambda s: done.set()
    executor.start()
    try:
        executor.submit_task("s1", "[automation x fired: y]", {"automation_id": "x"})
        assert done.wait(10)
    finally:
        executor.stop()
    rid, payload = sent[-1]
    assert rid.startswith("auto-") and payload["type"] == "done" and payload["host_notified"] is True
