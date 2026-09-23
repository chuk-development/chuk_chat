"""The run trace: the switch, the file, the phases and the secret rule.

Nothing sleeps — the tracer takes its clocks as parameters.
"""

from __future__ import annotations

import json
import logging

import pytest
from websockets.exceptions import ConnectionClosed

from chuk_agents_runtime import trace as trace_mod
from chuk_agents_runtime.trace import (
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

from test_backend_timing import AUTH_OK, DONE, FakeClock, FakeSocket, _client


@pytest.fixture(autouse=True)
def _restore_tracer():
    previous = get_tracer()
    yield
    set_tracer(previous)


def _lines(path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


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


# -- the phases the model client contributes --------------------------------


def test_a_model_call_emits_the_transport_phases(tmp_path):
    clock = FakeClock()
    tracer = JsonlTracer(tmp_path / "t.jsonl", clock=clock)
    set_tracer(tracer)
    socket = FakeSocket(
        clock,
        [
            AUTH_OK,
            (2.0, {"kind": "reasoning", "data": "hm"}),
            (1.0, {"kind": "content", "data": "ok"}),
            (5.0, {"kind": "content", "data": "!"}),
            (0.1, {"kind": "usage", "data": {"prompt_tokens": 9, "total_tokens": 11}}),
            DONE,
        ],
    )
    client = _client(clock, [socket], token_gap_ms=3000.0)

    with run_scope("run-1", "sess"):
        client.complete([{"role": "user", "content": "q"}])

    phases = [line["phase"] for line in _lines(tmp_path / "t.jsonl")]
    for expected in (
        "connect_start", "connect_open", "auth_ok", "request_sent",
        "first_frame", "first_reasoning", "first_content", "token_gap",
        "usage", "stream_closed", "model_call",
    ):
        assert expected in phases, expected

    by_phase = {line["phase"]: line for line in _lines(tmp_path / "t.jsonl")}
    assert by_phase["first_frame"]["ms"] == pytest.approx(2000.0)
    assert by_phase["first_content"]["ms"] == pytest.approx(3000.0)
    assert by_phase["token_gap"]["ms"] == pytest.approx(5000.0)
    assert by_phase["usage"]["prompt_tokens"] == 9
    assert by_phase["model_call"]["first_token_ms"] == pytest.approx(2000.0)
    assert by_phase["model_call"]["attempts"] == 1


def test_a_thrown_away_attempt_gets_its_own_retry_line(tmp_path):
    clock = FakeClock()
    tracer = JsonlTracer(tmp_path / "t.jsonl", clock=clock)
    set_tracer(tracer)
    dropped = FakeSocket(clock, [AUTH_OK, (9.0, ConnectionClosed(None, None))])
    healthy = FakeSocket(clock, [AUTH_OK, (1.0, {"kind": "content", "data": "ok"}), DONE])
    client = _client(clock, [dropped, healthy])

    with run_scope("run-2", "sess"):
        client.complete([{"role": "user", "content": "q"}])

    retries = [line for line in _lines(tmp_path / "t.jsonl") if line["phase"] == "retry"]
    assert len(retries) == 1
    assert retries[0]["reason"] == "connection_closed"
    assert retries[0]["dead_ms"] == pytest.approx(9000.0)
    assert retries[0]["attempt"] == 2
    # The prompt is sent — and paid for — a second time; the estimate is the
    # only figure we have for what that cost.
    assert retries[0]["prompt_tokens_est"] > 0


def test_tracing_off_writes_nothing_and_costs_no_field(tmp_path, caplog):
    clock = FakeClock()
    set_tracer(None)
    socket = FakeSocket(clock, [AUTH_OK, (1.0, {"kind": "content", "data": "ok"}), DONE])
    client = _client(clock, [socket])

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
        "echo", "echo", {"type": "object", "properties": {}}, lambda: "done"
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
    from chuk_agents_runtime.trace_report import attribution, read_lines, waterfall

    path = tmp_path / "agent-trace.jsonl"
    set_tracer(JsonlTracer(path))
    store = StateStore(str(tmp_path / "loop.db"))
    registry = ToolRegistry()
    registry.register(
        "echo", "echo", {"type": "object", "properties": {}}, lambda: "done"
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
