"""The run trace: the switch, the file, the phases and the secret rule.

Nothing sleeps — the tracer takes its clocks as parameters.
"""

from __future__ import annotations

import json
import logging

import pytest

from chuk_agents_runtime import telemetry as trace_mod
from chuk_agents_runtime.telemetry import (
    DEFAULT_MAX_BYTES,
    NULL_TRACER,
    JsonlTracer,
    NullTracer,
    TraceSettings,
    configure_tracing,
    current_scope,
    get_tracer,
    run_scope,
    set_round,
    set_tracer,
    trace_dir_for,
)




class FakeClock:
    """A monotonic clock the test moves by hand."""

    def __init__(self, start: float = 1000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds

@pytest.fixture(autouse=True)
def _restore_tracer():
    previous = get_tracer()
    yield
    set_tracer(previous)


def _lines(path) -> list[dict]:
    """The phase lines of the trace (each an OTel span in the file)."""
    from chuk_agents_runtime.telemetry_report import read_lines

    return read_lines(path)


# -- the switch -------------------------------------------------------------


def test_tracing_is_off_by_default():
    assert isinstance(NULL_TRACER, NullTracer)
    assert NULL_TRACER.enabled is False


def test_an_off_switch_creates_no_file(tmp_path):
    tracer = configure_tracing(TraceSettings(enabled=False), workspace=tmp_path)

    assert tracer is NULL_TRACER
    assert get_tracer() is NULL_TRACER
    assert not (tmp_path / "trace").exists()


def test_the_switch_reads_the_environment(monkeypatch):
    monkeypatch.delenv("AGENTS_TRACE", raising=False)
    assert TraceSettings.from_env().enabled is False

    monkeypatch.setenv("AGENTS_TRACE", "1")
    monkeypatch.setenv("AGENTS_TRACE_CONTENT", "1")
    monkeypatch.setenv("AGENTS_TRACE_MAX_BYTES", "4096")
    settings = TraceSettings.from_env()
    assert settings.enabled is True
    assert settings.content is True
    assert settings.max_bytes == 4096

    monkeypatch.setenv("AGENTS_TRACE", "off")
    assert TraceSettings.from_env().enabled is False
    # An explicit flag still wins over an unset environment.
    assert TraceSettings.from_env(enabled=True).enabled is True


def test_traces_land_under_the_workspace(tmp_path):
    assert trace_dir_for(tmp_path) == tmp_path / "trace"
    tracer = configure_tracing(TraceSettings(enabled=True), workspace=tmp_path)
    assert tracer.path == tmp_path / "trace" / "agent-trace.jsonl"
    assert TraceSettings().max_bytes == DEFAULT_MAX_BYTES


# -- the line shape ---------------------------------------------------------


def test_every_line_carries_identity_a_clock_and_a_delta(tmp_path):
    clock = FakeClock()
    tracer = JsonlTracer(tmp_path / "t.jsonl", clock=clock, wall=lambda: 1_700_000_000.0)

    with run_scope("run-abc", "session-1"):
        tracer.emit("task_received", prompt_chars=3)
        clock.advance(2.5)
        set_round(1)
        tracer.emit("round_start", iteration=1)

    first, second = _lines(tmp_path / "t.jsonl")
    for line in (first, second):
        assert set(line) >= {"t", "wall", "run_id", "session_key", "round", "phase", "dt_ms"}
        assert line["run_id"] == "run-abc"
        assert line["session_key"] == "session-1"
        assert line["wall"] == 1_700_000_000.0
    assert first["round"] == 0
    assert second["round"] == 1
    assert first["dt_ms"] == 0.0
    assert second["dt_ms"] == pytest.approx(2500.0)


def test_the_delta_is_per_run_so_two_runs_cannot_corrupt_each_other(tmp_path):
    clock = FakeClock()
    tracer = JsonlTracer(tmp_path / "t.jsonl", clock=clock)

    with run_scope("a", "s"):
        tracer.emit("round_start")
    clock.advance(100.0)
    with run_scope("b", "s"):
        tracer.emit("round_start")
    clock.advance(1.0)
    with run_scope("a", "s"):
        tracer.emit("round_start")

    lines = _lines(tmp_path / "t.jsonl")
    assert lines[2]["run_id"] == "a"
    assert lines[2]["dt_ms"] == pytest.approx(101_000.0)


def test_the_scope_is_restored_so_a_child_run_cannot_leak_its_id(tmp_path):
    with run_scope("parent", "s"):
        with run_scope("child", "s"):
            assert current_scope().run_id == "child"
        assert current_scope().run_id == "parent"
    assert current_scope().run_id == ""


# -- rotation ---------------------------------------------------------------


def test_the_file_rotates_at_the_cap_so_a_long_running_host_cannot_fill_the_disk(tmp_path):
    path = tmp_path / "t.jsonl"
    tracer = JsonlTracer(path, max_bytes=400, backups=2)

    with run_scope("r", "s"):
        for index in range(40):
            tracer.emit("round_start", iteration=index, padding="x" * 50)

    assert path.stat().st_size <= 400
    assert (path.parent / "t.jsonl.1").exists()
    assert (path.parent / "t.jsonl.2").exists()
    # Bounded: nothing past the backup count survives.
    assert not (path.parent / "t.jsonl.3").exists()


# -- secrets ----------------------------------------------------------------


def test_content_is_off_by_default(tmp_path):
    tracer = JsonlTracer(tmp_path / "t.jsonl")
    assert tracer.content_enabled is False
    assert tracer.text("sk-live-supersecret") is None


def test_content_without_a_scrubber_is_still_refused(tmp_path):
    tracer = JsonlTracer(tmp_path / "t.jsonl", content=True)

    assert tracer.content_enabled is False
    assert tracer.text("sk-live-supersecret") is None


def test_content_passes_through_the_scrubber(tmp_path):
    tracer = JsonlTracer(
        tmp_path / "t.jsonl",
        content=True,
        scrubber=lambda text: text.replace("sk-live-supersecret", "***"),
    )

    assert tracer.content_enabled is True
    assert tracer.text("token is sk-live-supersecret ok") == "token is *** ok"


def test_a_raising_scrubber_writes_nothing_rather_than_raw_text(tmp_path):
    def broken(_text: str) -> str:
        raise RuntimeError("boom")

    tracer = JsonlTracer(tmp_path / "t.jsonl", content=True, scrubber=broken)

    assert tracer.text("sk-live-supersecret") is None


def test_a_none_field_is_dropped_from_the_line(tmp_path):
    tracer = JsonlTracer(tmp_path / "t.jsonl")
    with run_scope("r", "s"):
        tracer.emit("task_received", text=None, prompt_chars=4)

    line = _lines(tmp_path / "t.jsonl")[0]
    assert "text" not in line
    assert line["prompt_chars"] == 4


def test_an_unwritable_trace_never_takes_a_run_down(tmp_path):
    tracer = JsonlTracer(tmp_path / "t.jsonl")
    tracer._path = tmp_path / "missing-dir" / "deeper" / "t.jsonl"  # noqa: SLF001

    with run_scope("r", "s"):
        tracer.emit("round_start")  # must not raise


# -- the phases the model contributes ----------------------------------------


def test_a_streamed_model_request_emits_its_first_token_and_model_call(tmp_path):
    """The loop's streamed request writes the lines ``trace_report`` splits a
    turn with: first byte (provider wait), the tokens, the call, the usage."""
    from chuk_agents_runtime.loop import AgentLoop
    from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model
    from chuk_agents_runtime.registry import ToolRegistry
    from chuk_agents_runtime.state import StateStore
    import httpx2

    from pai_fakes import FakeChatEndpoint, FakeSession, text_turn

    set_tracer(JsonlTracer(tmp_path / "t.jsonl"))
    endpoint = FakeChatEndpoint([text_turn(["o", "k"], reasoning_parts=["hm"])])
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )
    loop = AgentLoop(model, ToolRegistry(), StateStore(str(tmp_path / "s.db")), model_settings=settings)
    with run_scope("run-1", "sess"):
        loop.run("sess", "q")

    by_phase = {line["phase"]: line for line in _lines(tmp_path / "t.jsonl")}
    for expected in ("first_reasoning", "first_content", "model_call", "usage"):
        assert expected in by_phase, expected
    call = by_phase["model_call"]
    assert call["attempts"] == 1
    assert call["first_frame_ms"] is not None and call["first_token_ms"] is not None
    assert call["prompt_tokens"] == 10
    assert by_phase["usage"]["total_tokens"] == 15


def test_a_housekeeping_retry_gets_its_own_retry_line(tmp_path):
    from test_backend import MockRoute, _client, _gotrue_transport, _session, completion

    set_tracer(JsonlTracer(tmp_path / "t.jsonl"))
    route = MockRoute(lambda body: completion("ok"), valid_tokens={"fresh-token"})
    http, _ = _gotrue_transport(new_token="fresh-token")
    try:
        with run_scope("run-2", "sess"):
            _client(route, _session(token="expired", http_client=http)).complete(
                [{"role": "user", "content": "q"}]
            )
    finally:
        http.close()
    lines = _lines(tmp_path / "t.jsonl")
    retries = [line for line in lines if line["phase"] == "retry"]
    assert len(retries) == 1
    assert retries[0]["reason"] == "auth_rejected"
    assert retries[0]["attempt"] == 2
    assert len([line for line in lines if line["phase"] == "model_call"]) == 1


def test_tracing_off_writes_nothing_and_costs_no_field(tmp_path, caplog):
    from test_backend import MockRoute, _client, _session, completion

    set_tracer(None)
    client = _client(MockRoute(lambda body: completion("ok")), _session())
    with caplog.at_level(logging.INFO, logger="chuk_agents_runtime.backend"):
        response = client.complete([{"role": "user", "content": "q"}])

    assert response.text == "ok"
    assert not list(tmp_path.iterdir())
    # The info line is NOT part of the switch: it is always on, so a host with
    # tracing off still says how long each model call took.
    assert any(r.getMessage().startswith("model call") for r in caplog.records)


def test_the_loop_emits_the_phases_that_tile_a_whole_turn(tmp_path):
    """The trace has to cover the WHOLE path, not just the model call: a memory
    recall that costs 74 s is invisible otherwise."""
    from chuk_agents_runtime.loop import AgentLoop
    from chuk_agents_runtime.model import MockModelClient, tool_call_response
    from chuk_agents_runtime.registry import ToolRegistry
    from chuk_agents_runtime.state import StateStore

    tracer = JsonlTracer(tmp_path / "t.jsonl")
    set_tracer(tracer)
    store = StateStore(str(tmp_path / "loop.db"))
    registry = ToolRegistry()
    registry.register(
        "echo", {"type": "object", "properties": {}}, lambda: "done"
    )
    loop = AgentLoop(
        MockModelClient([tool_call_response(("echo", {})), "finished"]),
        registry,
        store,
        max_iterations=5,
        recall_provider=lambda prompt: [{"role": "user", "content": "recalled"}],
    )

    with run_scope("run-loop", "sess"):
        loop.run("sess", "go")
    store.close()

    lines = _lines(tmp_path / "t.jsonl")
    phases = [line["phase"] for line in lines]
    for expected in (
        "task_received", "memory_recall_start", "memory_recall_end",
        "round_start", "history_loaded", "ladder_pass", "payload_prepared",
        "tool_start", "tool_end", "run_finished",
    ):
        assert expected in phases, expected

    by_phase = {line["phase"]: line for line in lines}
    assert by_phase["memory_recall_end"]["messages"] == 1
    assert by_phase["tool_end"]["tool"] == "echo"
    assert by_phase["tool_end"]["ok"] is True
    assert by_phase["payload_prepared"]["prompt_tokens_est"] > 0
    finished = by_phase["run_finished"]
    assert finished["reason"] == "finished"
    assert finished["model_calls"] == 2
    # The rounds are numbered, so a waterfall can group by them.
    assert {line["round"] for line in lines} >= {0, 1, 2}


def test_the_loop_writes_no_message_text_while_content_tracing_is_off(tmp_path):
    from chuk_agents_runtime.loop import AgentLoop
    from chuk_agents_runtime.model import MockModelClient
    from chuk_agents_runtime.registry import ToolRegistry
    from chuk_agents_runtime.state import StateStore

    set_tracer(JsonlTracer(tmp_path / "t.jsonl"))
    store = StateStore(str(tmp_path / "loop.db"))
    loop = AgentLoop(MockModelClient(["done"]), ToolRegistry(), store, max_iterations=3)

    with run_scope("run-x", "sess"):
        loop.run("sess", "my api key is sk-live-supersecret")
    store.close()

    blob = (tmp_path / "t.jsonl").read_text()
    assert "sk-live-supersecret" not in blob
    assert "my api key" not in blob
    # Structure is still there: the size of the prompt, not its text.
    assert '"prompt_chars"' in blob


def test_the_reader_renders_a_real_trace(tmp_path):
    """End-to-end: what the loop writes is what ``cowork-host trace`` reads."""
    from chuk_agents_runtime.loop import AgentLoop
    from chuk_agents_runtime.model import MockModelClient, tool_call_response
    from chuk_agents_runtime.registry import ToolRegistry
    from chuk_agents_runtime.state import StateStore
    from chuk_agents_runtime.telemetry_report import attribution, read_lines, waterfall

    path = tmp_path / "agent-trace.jsonl"
    set_tracer(JsonlTracer(path))
    store = StateStore(str(tmp_path / "loop.db"))
    registry = ToolRegistry()
    registry.register(
        "echo", {"type": "object", "properties": {}}, lambda: "done"
    )
    loop = AgentLoop(
        MockModelClient([tool_call_response(("echo", {})), "finished"]),
        registry,
        store,
        max_iterations=5,
    )
    with run_scope("run-reader", "sess"):
        loop.run("sess", "go")
    store.close()

    lines = read_lines(path, run_id="run-read")
    assert lines and all(line["run_id"] == "run-reader" for line in lines)
    buckets = attribution(lines)
    assert buckets["unattributed"] >= 0
    report = waterfall(lines)
    assert "run-reader" in report
    assert "round 1" in report
    assert all(len(row) <= 100 for row in report.splitlines())


def test_the_module_global_is_the_one_switch():
    assert get_tracer() is trace_mod.get_tracer()
    previous = set_tracer(NULL_TRACER)
    assert get_tracer() is NULL_TRACER
    set_tracer(previous)


def test_a_run_is_one_otel_trace_with_the_agents_spans_nested(tmp_path):
    """The file holds OpenTelemetry spans: one ``agent_run`` per run, every
    phase a child of it, and Pydantic AI's own spans in the same trace."""
    from chuk_agents_runtime.loop import AgentLoop
    from chuk_agents_runtime.model import MockModelClient, tool_call_response
    from chuk_agents_runtime.pai.wiring import instrumentation_capabilities
    from chuk_agents_runtime.registry import ToolRegistry
    from chuk_agents_runtime.state import StateStore

    path = tmp_path / "agent-trace.jsonl"
    set_tracer(JsonlTracer(path))
    registry = ToolRegistry()
    registry.register("echo", {"type": "object", "properties": {}}, lambda: "done")
    loop = AgentLoop(
        MockModelClient([tool_call_response(("echo", {})), "finished"]),
        registry,
        StateStore(str(tmp_path / "s.db")),
        capabilities=instrumentation_capabilities(),
    )
    with run_scope("run-otel", "sess"):
        loop.run("sess", "go")

    spans = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    runs = [s for s in spans if s["name"] == "agent_run"]
    assert len(runs) == 1 and runs[0]["attributes"]["run_id"] == "run-otel"
    run_span = runs[0]
    assert {s["trace_id"] for s in spans} == {run_span["trace_id"]}
    phases = [s for s in spans if "dt_ms" in s["attributes"]]
    assert {"task_received", "round_start", "tool_end", "run_finished"} <= {s["name"] for s in phases}
    assert all(s["parent_id"] == run_span["span_id"] for s in phases)
    names = {s["name"] for s in spans}
    assert any(n.startswith("invoke_agent") or n == "agent run" for n in names), names
    assert any(n.startswith("chat") for n in names), names
    assert any(n.startswith("execute_tool") or n == "running tool" for n in names), names
