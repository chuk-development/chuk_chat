"""``agent_status``: the figures behind the app's agent controls (cowork-6ag).

The panel used to draw "Not connected yet" under Models, Token usage and Session
runtime because nothing carried them. These tests hold the host to the opposite
promise: every figure it sends is one it measured, and a figure it did not
measure is absent from the frame rather than sent as a zero.
"""

from __future__ import annotations

from cowork_agent import MockModelClient, tool_call_response
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor.protocol import agent_status_request_payload

from wiring import paired_channel


class _NamedModel(MockModelClient):
    """A mock that answers ``model_id`` / ``provider_slug`` like a real client."""

    model_id = "anthropic/claude-test"
    provider_slug = "anthropic"


def _model() -> MockModelClient:
    return MockModelClient(
        [tool_call_response(("run_command", {"command": "echo hi > f.txt"})), "done"]
    )


def _build(tmp_path, workdir, model_factory=_model):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="agent",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workdir)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        workspace=str(workdir),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def _status(controller, session_key: str) -> dict:
    request_id = controller.send_payload(agent_status_request_payload(session_key))
    events = controller.collect(request_id, timeout=15.0)
    frames = [e for e in events if e.get("type") == "agent_status"]
    assert frames, f"no agent_status in {[e.get('type') for e in events]}"
    return frames[-1]


def test_a_session_that_never_ran_reports_no_figures(tmp_path):
    """No run, no measurement — and therefore no block, not a zero."""
    workdir = tmp_path / "ws"
    workdir.mkdir()
    executor, controller = _build(tmp_path, workdir)
    executor.start()
    try:
        status = _status(controller, "fresh")
    finally:
        executor.stop()

    assert status["session_key"] == "fresh"
    assert "tokens" not in status
    assert "runtime" not in status
    # The sandbox is real even before the first run: it is where the agent WILL
    # work, and the app shows which box that is.
    assert status["sandbox"]["kind"] == "local"
    assert status["sandbox"]["workspace"] == str(workdir)


def test_status_reports_the_model_the_run_used(tmp_path):
    workdir = tmp_path / "ws"
    workdir.mkdir()
    executor, controller = _build(tmp_path, workdir)
    executor.start()
    try:
        controller.collect(
            controller.send_task(
                "do it",
                session_key="amber",
                model="anthropic/claude-x",
                provider="anthropic",
                reasoning_effort="low",
            ),
            timeout=20.0,
        )
        status = _status(controller, "amber")
    finally:
        executor.stop()

    assert status["model"]["id"] == "anthropic/claude-x"
    assert status["model"]["provider"] == "anthropic"
    assert status["model"]["reasoning_effort"] == "low"
    assert status["model"]["source"] == "run"


def test_status_counts_the_runs_and_the_clock(tmp_path):
    workdir = tmp_path / "ws"
    workdir.mkdir()
    executor, controller = _build(tmp_path, workdir)
    executor.start()
    try:
        controller.collect(
            controller.send_task("one", session_key="amber"), timeout=20.0
        )
        controller.collect(
            controller.send_task("two", session_key="amber"), timeout=20.0
        )
        # A second coworker's spend must not land in the first one's figures.
        controller.collect(
            controller.send_task("hers", session_key="blue"), timeout=20.0
        )
        amber = _status(controller, "amber")
        blue = _status(controller, "blue")
    finally:
        executor.stop()

    assert amber["tokens"]["runs"] == 2
    assert blue["tokens"]["runs"] == 1
    assert amber["runtime"]["runs"] == 2
    assert amber["runtime"]["running"] is False
    assert amber["runtime"]["active_seconds"] >= 0.0
    assert amber["runtime"]["started_at"] > 0.0


def test_a_finished_run_pushes_the_status_before_its_done(tmp_path):
    """The panel's figures move with the work, not only when it is reopened."""
    workdir = tmp_path / "ws"
    workdir.mkdir()
    executor, controller = _build(tmp_path, workdir)
    executor.start()
    try:
        events = controller.collect(
            controller.send_task("do it", session_key="amber"), timeout=20.0
        )
    finally:
        executor.stop()

    types = [e.get("type") for e in events]
    assert "agent_status" in types
    assert types.index("agent_status") < types.index("done")
    status = [e for e in events if e["type"] == "agent_status"][-1]
    assert status["session_key"] == "amber"
    assert status["tokens"]["runs"] == 1


def test_a_task_that_named_no_model_still_reports_the_model_that_ran(tmp_path):
    """The host's default is reported from the client it really built.

    Nothing is constructed to answer a status request: a probe would cost a
    client (and, with a real backend, a connection) every time the panel opens.
    """
    workdir = tmp_path / "ws"
    workdir.mkdir()

    def factory() -> MockModelClient:
        return _NamedModel(
            [tool_call_response(("run_command", {"command": "true"})), "done"]
        )

    executor, controller = _build(tmp_path, workdir, model_factory=factory)
    executor.start()
    try:
        before = _status(controller, "amber")
        controller.collect(
            controller.send_task("do it", session_key="amber"), timeout=20.0
        )
        after = _status(controller, "amber")
    finally:
        executor.stop()

    # Never run: nothing measured, so no model block at all.
    assert "model" not in before
    assert after["model"] == {
        "id": "anthropic/claude-test",
        "provider": "anthropic",
        "source": "run",
    }
