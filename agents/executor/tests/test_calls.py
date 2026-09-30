"""The agent calls the user, in the executor (docs/WIRE_CONTRACT.md, "The agent
calls the user"): ``call_user`` / ``call_status`` are bound to the task's
session, a fired automation run gets them too (a reminder by call), and the
app's ``voice_call_state`` frame reaches the host hook."""

from __future__ import annotations

import time

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_runtime.calls import RecordingCallBackend
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


class _Calls:
    """Stands in for the host's CallService: one recording backend per
    session, so a test sees which session a task's tools were bound to."""

    def __init__(self) -> None:
        self.bound_keys: list[str] = []
        self.backends: dict[str, RecordingCallBackend] = {}

    def bound(self, session_key: str) -> RecordingCallBackend:
        self.bound_keys.append(session_key)
        return self.backends.setdefault(session_key, RecordingCallBackend())


def _executor(tmp_path, channel, executor_ep, *, model_factory, **kw) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="calls",
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


def _calling_model() -> MockModelClient:
    return MockModelClient(
        [tool_call_response(("call_user", {"reason": "Your pizza is ready."})), "calling"]
    )


def test_the_call_tools_are_bound_to_the_tasks_session(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    calls = _Calls()
    executor = _executor(tmp_path, channel, executor_ep, model_factory=_calling_model, calls=calls)
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        rid = controller.send_payload({"type": "task", "prompt": "call me", "session_key": "thread-A"})
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()
    assert calls.bound_keys == ["thread-A"]
    assert calls.backends["thread-A"].calls[0]["reason"] == "Your pizza is ready."
    tool = [e for e in events if e["type"] == "tool" and e["name"] == "call_user"]
    assert tool and tool[0]["status"] == "completed"
    assert "ringing (call_id c1)" in str(tool[0]["result"])


def test_a_fired_automation_run_can_call_the_user(tmp_path):
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    calls = _Calls()
    finished: list[dict] = []
    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=_calling_model,
        calls=calls,
        on_run_finished=finished.append,
    )
    executor.start()
    try:
        executor.submit_task(
            "thread-B",
            "[automation ab12 fired: pizza reminder]\nCall the user about the pizza.",
            {"automation_id": "ab12", "name": "pizza reminder"},
        )
        assert _wait(lambda: len(finished) == 1)
    finally:
        executor.stop()
    assert finished[0]["origin"] == "automation"
    assert calls.bound_keys == ["thread-B"]
    assert [c["reason"] for c in calls.backends["thread-B"].calls] == ["Your pizza is ready."]


def test_without_a_call_service_no_call_tool_is_offered(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep, model_factory=_calling_model)
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        rid = controller.send_payload({"type": "task", "prompt": "call me", "session_key": "s"})
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()
    tool = [e for e in events if e["type"] == "tool"]
    assert tool and tool[0]["status"] == "error" and "unknown tool" in tool[0]["result"]


def test_voice_call_state_reaches_the_host_hook_and_opens_no_stream(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    seen: list[dict] = []
    executor = _executor(
        tmp_path, channel, executor_ep,
        model_factory=lambda: MockModelClient(["unused"]),
        on_call_frame=seen.append,
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "voice_call_state", "call_id": "3f2a9c1d0b7e4a55", "state": "accepted"}
        )
        assert _wait(lambda: len(seen) == 1)
        # A control frame: no terminal comes back for it.
        events = controller.collect(rid, timeout=0.5)
    finally:
        executor.stop()
    assert seen == [{"type": "voice_call_state", "call_id": "3f2a9c1d0b7e4a55", "state": "accepted"}]
    assert events == []


def test_voice_call_state_without_the_hook_is_answered_with_an_error(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep, model_factory=lambda: MockModelClient(["x"]))
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        rid = controller.send_payload({"type": "voice_call_state", "call_id": "c", "state": "ended"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert events and events[0]["type"] == "error" and "calls not enabled" in events[0]["message"]
