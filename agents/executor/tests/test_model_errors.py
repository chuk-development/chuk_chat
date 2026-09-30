"""A model failure the user can act on reaches the app as its own message
(``loop.ModelServiceError``), not as "loop failed: <exception class>"."""

from __future__ import annotations

from chuk_agents_runtime.loop import ModelServiceError

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


class _NoCredits:
    def complete(self, messages):
        raise ModelServiceError("no credits left", status=402)


def test_no_credits_reaches_the_app_as_a_readable_error(tmp_path):
    from chuk_agents_sandbox import LocalEnvironment

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="errors",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path)),
        db_path=str(tmp_path / "state.db"),
        model_factory=_NoCredits,
        system_prompt="You are a coworker.",
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        request_id = controller.send_task("hello", session_key="s1")
        events = controller.collect(request_id, timeout=15.0)
    finally:
        executor.stop()
    errors = [e for e in events if e["type"] == "error"]
    assert errors and errors[-1]["message"] == "no credits left"
