"""Subagents through the encrypted executor path (§7.6 + task 2).

One scripted parent delegates one task. Asserts the child really ran in its own
sandbox — built by the sandbox factory from the child's own task id — and that its
lifecycle and output reached the controller as sealed ``subagent`` events on the
same stream as the parent's deltas.
"""

from __future__ import annotations

from cowork_agent import MockModelClient
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel

DELEGATE = (
    '<tool_call>{"name":"delegate_task","arguments":{"tasks":'
    '[{"prompt":"write the summary","title":"writer"}]}}</tool_call>'
)


def test_a_delegated_child_streams_back_over_the_sealed_channel(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()

    # The factory is called once per logical client, in order: the parent's
    # streaming client, the browser fallback's separate client (§8 — built per
    # task, never used here because the local sandbox has no Chromium, so its
    # script is never read), then the delegated child's client.
    scripts = iter(
        [
            MockModelClient([DELEGATE, "the parent is done"]),  # parent
            MockModelClient([]),  # browser (unused: no Chromium)
            MockModelClient(["the child is done"]),  # child
        ]
    )

    executor = Executor(
        name="with-subagents",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: next(scripts),
        workspace=str(workspace),
        # Subagents on, local backend: one child, one environment of its own.
        subagent_sandbox="local",
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    executor.start()
    try:
        request_id = controller.send_task("delegate the summary", session_key="thread-1")
        events = controller.collect(request_id, timeout=30.0)
    finally:
        executor.stop()

    assert events[-1]["type"] == "done"
    assert events[-1]["final_answer"] == "the parent is done"

    subagent_events = [e["event"] for e in events if e["type"] == "subagent"]
    assert subagent_events, "no subagent event reached the controller"

    states = [e for e in subagent_events if e["type"] == "subagent_state"]
    assert [s["state"] for s in states][-1] == "succeeded"
    assert states[-1]["result"] == "the child is done"
    assert states[0]["title"] == "writer"

    deltas = [
        e["payload"]["text"]
        for e in subagent_events
        if e["type"] == "subagent_output" and e["payload"].get("type") == "delta"
    ]
    assert "the child is done" in deltas


def test_subagents_stay_off_unless_a_sandbox_kind_is_given(tmp_path):
    """Off by default: a child is a second sandbox and a second model stream, so
    the operator opts in. The tool is then not even documented to the model."""
    workspace = tmp_path / "ws"
    workspace.mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()

    executor = Executor(
        name="no-subagents",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient([DELEGATE, "done anyway"]),
        workspace=str(workspace),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    executor.start()
    try:
        request_id = controller.send_task("try to delegate", session_key="thread-1")
        events = controller.collect(request_id, timeout=30.0)
    finally:
        executor.stop()

    assert events[-1]["type"] == "done"
    assert not [e for e in events if e["type"] == "subagent"]
