"""The agent's own model is stored on the host (CHAT-36)."""

from __future__ import annotations

from chuk_agents_runtime import StateStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import Executor, loopback_pair
from chuk_agents_executor.executor import AGENT_MODEL_FEATURE

from wiring import paired_channel

S = "local:Mail:14:138509541"
FLASH = "deepseek/deepseek-v4-flash-0731"


def _executor(tmp_path) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    return Executor(
        name="e",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "s.db"),
        model_factory=lambda: None,
    )


def test_stored_model_survives_a_new_executor_and_wins_for_automations(tmp_path):
    first = _executor(tmp_path)
    first.set_agent_model(S, FLASH, provider="deepinfra", reasoning_effort="low")
    # An earlier run on another model must not decide any more.
    store = StateStore(str(tmp_path / "s.db"))
    try:
        store.begin_run("r0", store.route(S), S, "hi", model="z-ai/glm-5.3-flash", provider="fireworks/serverless")
    finally:
        store.close()

    second = _executor(tmp_path)  # a host restart
    captured = []
    second._enqueue_run = captured.append  # type: ignore[method-assign]
    second.submit_task(S, "check mail", {"automation_id": "a1"})
    assert captured[0].model == FLASH
    assert captured[0].provider == "deepinfra"
    assert captured[0].reasoning_effort == "low"
    assert second._status_model(S, [])["source"] == "agent"


def test_clearing_falls_back_to_the_last_run(tmp_path):
    executor = _executor(tmp_path)
    executor.set_agent_model(S, FLASH)
    assert executor.set_agent_model(S, None) is None
    store = StateStore(str(tmp_path / "s.db"))
    try:
        assert store.load_feature(S, AGENT_MODEL_FEATURE) is None
    finally:
        store.close()


def test_the_frame_stores_and_answers(tmp_path):
    executor = _executor(tmp_path)
    sent = []
    executor._terminal = lambda rid, payload: sent.append(payload)  # type: ignore[method-assign]
    executor._handle_agent_model_set("q1", {"type": "agent_model_set", "session_key": S, "model": FLASH})
    assert sent[-1] == {"type": "agent_model", "session_key": S, "model": {"id": FLASH}}
    executor._handle_agent_model_set("q2", {"type": "agent_model_set", "model": FLASH})
    assert "error" in sent[-1]
