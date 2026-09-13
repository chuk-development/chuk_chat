"""Per-task model selection: a task may name the model it runs on.

The controller seals a ``model`` (plus an optional ``provider`` and
``reasoning_effort``) into the task frame — the three keys the app's mode
selector sends. When a ``model_select`` is wired, the executor builds that model
for the task; a task that names nothing falls back to the default
``model_factory``. The offline path (no select wired) always uses the factory, so
no credits are spent no matter what a task names.
"""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

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

        # The durable record agrees with the terminal (docs/WIRE_CONTRACT.md): an
        # app that reconnects later must see this run as failed, not running.
        from chuk_agents_runtime import StateStore

        store = StateStore(str(tmp_path / "s.db"))
        try:
            row = store.latest_run("s")
        finally:
            store.close()
        assert row is not None, "the failed run must have a runs row"
        assert row["state"] == "failed"
        assert "task failed" in str(row)

        # The worker is still alive: the next task completes on the same executor.
        rid2 = controller.send_task("again", session_key="s")
        events2 = controller.collect(rid2, timeout=15.0)
        assert events2 and events2[-1]["type"] == "done"
        assert _answer(events2) == "from-factory"
    finally:
        executor.stop()


def test_stop_closes_and_forgets_the_cached_mem0_handles(tmp_path, monkeypatch):
    """The teardown half of the per-workspace mem0 cache. One Memory handle per
    workspace root is kept for the life of the process so task 2 can open the
    same embedded Qdrant folder; when the executor stops, those handles must be
    closed and forgotten, or the storage lock outlives the process that owns the
    workspace and the next start hits "already accessed"."""
    from chuk_agents_runtime import memory as memory_mod

    closed: list[str] = []

    class _Client:
        def close(self):
            closed.append("closed")

    class _Store:
        client = _Client()

    class _Handle:
        vector_store = _Store()

    monkeypatch.setattr(memory_mod, "_MEM_BY_ROOT", {str(tmp_path / "ws"): _Handle()})

    executor, _controller = _wire(
        tmp_path,
        model_factory=lambda: _scripted_model("from-factory"),
        model_select=None,
    )
    executor.start()
    executor.stop()

    assert closed == ["closed"], "stop() must close the cached Qdrant client"
    assert memory_mod._MEM_BY_ROOT == {}, "stop() must forget the cached handles"


def test_a_non_string_prompt_is_refused_before_anything_is_recorded(tmp_path):
    """A task frame whose prompt is not text is refused at accept time with an
    error terminal — not written into the runs table and not handed to the
    worker to fail later. (The controller's type hint says str; the wire does
    not enforce it, so the executor must.)"""
    executor, controller = _wire(
        tmp_path,
        model_factory=lambda: _scripted_model("from-factory"),
        model_select=None,
    )
    executor.start()
    try:
        rid = controller.send_task(123, session_key="s")  # type: ignore[arg-type]
        events = controller.collect(rid, timeout=15.0)
        assert events and events[-1]["type"] == "error"
        assert "prompt must be a string" in str(events[-1])

        from chuk_agents_runtime import StateStore

        store = StateStore(str(tmp_path / "s.db"))
        try:
            assert store.latest_run("s") is None, "nothing may be recorded for a refused task"
        finally:
            store.close()
    finally:
        executor.stop()


def test_the_runs_row_and_the_log_prove_which_model_a_task_ran_on(tmp_path, caplog):
    """A live run must be provable afterwards: the runs row carries the task's
    model / provider / reasoning_effort (NULL = host default), and the executor
    logs one line per accepted task naming them — never the prompt."""
    import logging

    from chuk_agents_runtime import StateStore

    factory, select, _calls = _recording_pair()
    executor, controller = _wire(tmp_path, model_factory=factory, model_select=select)
    with caplog.at_level(logging.INFO, logger="chuk_agents_executor.executor"):
        events = _run(
            executor,
            controller,
            "the secret prompt text",
            model="anthropic/claude-x",
            provider="anthropic",
            reasoning_effort="low",
        )
    assert events[-1]["type"] == "done"

    store = StateStore(str(tmp_path / "s.db"))
    try:
        row = store.latest_run("s")
    finally:
        store.close()
    assert row["model"] == "anthropic/claude-x"
    assert row["provider"] == "anthropic"
    assert row["reasoning_effort"] == "low"

    lines = [r.getMessage() for r in caplog.records if "task accepted" in r.getMessage()]
    assert len(lines) == 1
    assert "model=anthropic/claude-x" in lines[0]
    assert "provider=anthropic" in lines[0]
    assert "reasoning_effort=low" in lines[0]
    assert "secret prompt" not in lines[0]


def test_a_task_naming_nothing_is_recorded_as_host_default(tmp_path, caplog):
    import logging

    from chuk_agents_runtime import StateStore

    factory, select, _calls = _recording_pair()
    executor, controller = _wire(tmp_path, model_factory=factory, model_select=select)
    with caplog.at_level(logging.INFO, logger="chuk_agents_executor.executor"):
        events = _run(executor, controller, "do it")
    assert events[-1]["type"] == "done"

    store = StateStore(str(tmp_path / "s.db"))
    try:
        row = store.latest_run("s")
    finally:
        store.close()
    assert row["model"] is None and row["provider"] is None and row["reasoning_effort"] is None

    line = next(r.getMessage() for r in caplog.records if "task accepted" in r.getMessage())
    assert "model=host-default" in line and "reasoning_effort=host-default" in line


# -- reasoning effort clamp (bead cowork-3hk, host side) -----------------------

_CATALOGUE = [
    {
        "id": "z-ai/glm-5.3-flash",
        "supported_efforts": ["low", "high", "max"],
        "reasoning_default_effort": "max",
        "providers": [{"slug": "fireworks/serverless", "pricing": {"completion": "0.1"}}],
    },
]


def _fake_session():
    from chuk_agents_runtime import SupabaseSession

    return SupabaseSession(
        access_token="valid-token",
        refresh_token="r",
        supabase_url="https://proj.supabase.co",
        anon_key="anon",
    )


def test_the_selector_clamps_an_unsupported_effort_and_logs_once(caplog):
    """Live finding 2026-09-05: ``medium`` on glm-5.3-flash yields NO reasoning
    frames from the backend. The selector clamps to the catalogue's next
    stronger level and says so once per (model, level)."""
    import logging

    from chuk_agents_executor.backend import make_backend_model_select

    select = make_backend_model_select(_fake_session(), _CATALOGUE)
    with caplog.at_level(logging.WARNING, logger="chuk_agents_executor.backend"):
        first = select("z-ai/glm-5.3-flash", "fireworks/serverless", "medium")
        second = select("z-ai/glm-5.3-flash", "fireworks/serverless", "medium")
        fine = select("z-ai/glm-5.3-flash", "fireworks/serverless", "high")
    assert first.reasoning_effort == "high"
    assert second.reasoning_effort == "high"
    assert fine.reasoning_effort == "high"
    warnings = [r.getMessage() for r in caplog.records if "not supported" in r.getMessage()]
    assert len(warnings) == 1
    assert "'medium'" in warnings[0] and "z-ai/glm-5.3-flash" in warnings[0]
    assert "low,high,max" in warnings[0] and "'high'" in warnings[0]
    for client in (first, second, fine):
        client.close()


def test_the_runs_row_records_the_effective_effort_after_a_clamp(tmp_path, caplog):
    """The row proves what the model really ran on, not what the app asked."""
    import logging

    from chuk_agents_runtime import StateStore

    class _Clamped(MockModelClient):
        reasoning_effort = "high"

    def factory():
        return _scripted_model("from-factory")

    def select(model, provider, reasoning_effort):
        client = _Clamped(
            [
                tool_call_response(("run_command", {"command": "true"})),
                "from-select",
            ]
        )
        return client

    executor, controller = _wire(tmp_path, model_factory=factory, model_select=select)
    with caplog.at_level(logging.INFO, logger="chuk_agents_executor.executor"):
        events = _run(
            executor,
            controller,
            "think",
            model="z-ai/glm-5.3-flash",
            provider="fireworks/serverless",
            reasoning_effort="medium",
        )
    assert events[-1]["type"] == "done"

    store = StateStore(str(tmp_path / "s.db"))
    try:
        row = store.latest_run("s")
    finally:
        store.close()
    assert row["reasoning_effort"] == "high"
    notes = [r.getMessage() for r in caplog.records if "not supported by the model" in r.getMessage()]
    assert len(notes) == 1
    assert "medium" in notes[0] and "high" in notes[0]
