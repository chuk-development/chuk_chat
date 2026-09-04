"""Per-task model selection: a task may name the model it runs on.

The controller seals a ``model`` (plus an optional ``provider`` and
``reasoning_effort``) into the task frame — the three keys the app's mode
selector sends. When a ``model_select`` is wired, the executor builds that model
for the task; a task that names nothing falls back to the default
``model_factory``. The offline path (no select wired) always uses the factory, so
no credits are spent no matter what a task names.
"""

from __future__ import annotations

from cowork_agent import MockModelClient, tool_call_response
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _scripted_model(answer: str = "done") -> MockModelClient:
    """Fresh scripted model: one run_command tool call, then a final answer.

    ``answer`` marks *which* client ran the loop. That marker is the assertion,
    not a call count: the executor also builds a second, separate factory client
    for the browser fallback (§8), which is never run, so counting factory calls
    would prove nothing about the model the task actually spoke to.
    """
    return MockModelClient(
        [
            tool_call_response(("run_command", {"command": "echo hi > f.txt"})),
            answer,
        ]
    )


def _answer(events: list[dict]) -> str | None:
    """The last assistant text the run streamed — the loop's own model talking."""
    deltas = [e["text"] for e in events if e.get("type") == "delta"]
    return deltas[-1] if deltas else None


def _wire(tmp_path, *, model_factory, model_select):
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="e",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "s.db"),
        model_factory=model_factory,
        model_select=model_select,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def _run(executor: Executor, controller: ControllerSession, prompt: str, **kw):
    executor.start()
    try:
        rid = controller.send_task(prompt, session_key="s", **kw)
        return controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()


def _recording_pair():
    """A default factory and a per-task selector, each handing back a client that
    names itself, plus the list of ``(model, provider, reasoning_effort)`` the
    selector was asked for."""
    calls: list[tuple[str | None, str | None, str | None]] = []

    def factory():
        return _scripted_model("from-factory")

    def select(model, provider, reasoning_effort):
        calls.append((model, provider, reasoning_effort))
        return _scripted_model("from-select")

    return factory, select, calls


def test_named_model_routes_through_select(tmp_path):
    factory, select, calls = _recording_pair()

    executor, controller = _wire(tmp_path, model_factory=factory, model_select=select)
    events = _run(
        executor,
        controller,
        "do it",
        model="anthropic/claude-x",
        provider="anthropic",
        reasoning_effort="low",
    )

    assert events[-1]["type"] == "done"
    # The named model went through the selector, not the default factory, and the
    # task's own reasoning effort reached it (that is what Fast Mode is).
    assert calls == [("anthropic/claude-x", "anthropic", "low")]
    assert _answer(events) == "from-select"


def test_effort_only_routes_through_select(tmp_path):
    """Fast Mode on the host's default model: the task names no model, only how
    hard to think. That still has to reach the selector, or the effort is lost."""
    factory, select, calls = _recording_pair()

    executor, controller = _wire(tmp_path, model_factory=factory, model_select=select)
    events = _run(executor, controller, "do it", reasoning_effort="low")

    assert events[-1]["type"] == "done"
    assert calls == [(None, None, "low")]
    assert _answer(events) == "from-select"


def test_no_model_falls_back_to_factory(tmp_path):
    factory, select, calls = _recording_pair()

    executor, controller = _wire(tmp_path, model_factory=factory, model_select=select)
    events = _run(executor, controller, "do it")  # no model named

    assert events[-1]["type"] == "done"
    assert calls == []
    assert _answer(events) == "from-factory"


def test_named_model_without_select_uses_factory(tmp_path):
    """Offline/mock path: a task names a model but no selector is wired, so the
    injected factory runs it and no backend model is ever built (no credits)."""
    factory, _select, _calls = _recording_pair()

    executor, controller = _wire(tmp_path, model_factory=factory, model_select=None)
    events = _run(executor, controller, "do it", model="anthropic/claude-x")

    assert events[-1]["type"] == "done"
    assert _answer(events) == "from-factory"


def test_selector_failure_is_an_error_terminal_and_the_worker_survives(tmp_path):
    """The blocker the review caught. Building the task's model happens BEFORE
    ``_run_task``'s own try/finally, so an exception there — a real ``ModelSelect``
    raises on an unknown model id — used to escape the worker thread and kill it
    for the rest of the executor's life: no terminal frame for the app, and every
    later task queued forever. Now it is an ``error`` terminal, and a plain task on
    the SAME executor still runs afterwards."""

    def factory():
        return _scripted_model("from-factory")

    def select(model, provider, reasoning_effort):
        raise ValueError(f"model {model!r} has no providers")

    executor, controller = _wire(tmp_path, model_factory=factory, model_select=select)
    executor.start()
    try:
        rid = controller.send_task("do it", session_key="s", model="x/y")
        events = controller.collect(rid, timeout=15.0)
        assert events, "the failed task produced no frames at all (dead worker)"
        assert events[-1]["type"] == "error"
        assert "task failed" in str(events[-1])

        # The worker is still alive: the next task completes on the same executor.
        rid2 = controller.send_task("again", session_key="s")
        events2 = controller.collect(rid2, timeout=15.0)
        assert events2 and events2[-1]["type"] == "done"
        assert _answer(events2) == "from-factory"
    finally:
        executor.stop()
