"""The time between a task frame and the loop (bead chuk_chat-4xc5).

A first task after a host restart spent ~9 s before ``task_received`` and the
trace could not say where. Pinned here:

- the executor's own preparation is traced inside the run's scope:
  ``task_accepted`` -> ``model_ready`` -> ``mcp_ready`` -> ``runtime_built`` ->
  ``task_received``, one run id, one ``agent_run`` span;
- one log line per run sums it up;
- forwarded MCP servers leave their tool list next to the state database, and
  the next executor (a host restart) offers those tools at once and dials in
  the background instead of before the first model call.
"""

from __future__ import annotations

import json
import logging
import sys
import time
from pathlib import Path

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_runtime.telemetry import OTelTracer, set_tracer
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.executor import MCP_TOOLS_CACHE_FILE
from chuk_agents_executor.protocol import task_payload

from wiring import paired_channel

FAKE_STDIO = str(Path(__file__).parent / "fake_mcp_stdio.py")


def _servers() -> list[dict]:
    return [
        {
            "name": "fake",
            "command": sys.executable,
            "args": [FAKE_STDIO],
            "auth": "none",
            "connect_timeout": 30.0,
            "call_timeout": 30.0,
        }
    ]


def _pair(tmp_path, factory, **kwargs):
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="ex",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=factory,
        **kwargs,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def _spans(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def test_the_preparation_is_traced_inside_the_run(tmp_path, caplog):
    trace = tmp_path / "trace.jsonl"
    tracer = OTelTracer(trace)
    previous = set_tracer(tracer)
    finished: list[dict] = []
    executor, controller = _pair(
        tmp_path, lambda: MockModelClient(["hello"]), on_run_finished=finished.append
    )
    executor.start()
    try:
        with caplog.at_level(logging.INFO, logger="chuk_agents_executor.executor"):
            request_id = controller.send_payload(task_payload("hi", "thread-1"))
            events = controller.collect(request_id, timeout=30.0)
        assert events[-1]["type"] == "done"
    finally:
        executor.stop()
        set_tracer(previous)
        tracer.close()

    spans = _spans(trace)
    phases = [s for s in spans if "run_id" in s.get("attributes", {})]
    names = [s["name"] for s in phases]
    order = ["task_accepted", "model_ready", "mcp_ready", "runtime_built", "task_received"]
    for name in order:
        assert name in names, names
    assert [n for n in names if n in order] == order
    run_ids = {s["attributes"]["run_id"] for s in phases if s["name"] in order}
    assert len(run_ids) == 1 and "" not in run_ids
    # One run span holds the preparation too.
    runs = [s for s in spans if s["name"] == "agent_run"]
    assert len(runs) == 1
    accepted = next(s for s in phases if s["name"] == "task_accepted")
    assert accepted["parent_id"] == runs[0]["span_id"]
    assert runs[0]["start"] <= next(s for s in phases if s["name"] == "model_ready")["start"]
    for name in order[:4]:
        span = next(s for s in phases if s["name"] == name)
        assert span["attributes"]["ms"] >= 0
    # And one line per run in the log.
    lines = [r.getMessage() for r in caplog.records if "timing: pre-run" in r.getMessage()]
    assert len(lines) == 1
    assert "mcp" in lines[0] and "| loop:" in lines[0] and "finished" in lines[0]
    # The host gets the same line with the run summary (it logs it).
    deadline = time.monotonic() + 5
    while not finished and time.monotonic() < deadline:
        time.sleep(0.01)
    assert finished and finished[0]["timing"] == lines[0]
    assert "hi" not in finished[0]["timing"].split("timing:")[1]


def test_a_restarted_executor_does_not_wait_for_a_known_connector(tmp_path):
    def factory() -> MockModelClient:
        return MockModelClient(
            [tool_call_response(("mcp__fake__shout", {"text": "via mcp"})), "done"]
        )

    # First host life: the connector is dialed and waited for (nothing known).
    executor, controller = _pair(tmp_path, factory)
    executor.start()
    try:
        request_id = controller.send_payload(
            task_payload("use the tool", "thread-1", mcp_servers=_servers())
        )
        events = controller.collect(request_id, timeout=60.0)
        assert events[-1]["type"] == "done"
    finally:
        executor.stop()
    cache = tmp_path / MCP_TOOLS_CACHE_FILE
    stored = json.loads(cache.read_text(encoding="utf-8"))
    assert [t["name"] for rows in stored.values() for t in rows] == ["shout"]
    assert "fake" not in cache.read_text(encoding="utf-8")  # keys are hashes

    # Second host life: the cached tool list is offered at once, the
    # handshake runs in the background, and the model's call still works.
    executor, controller = _pair(tmp_path, factory)
    manager = executor._session_mcp_manager("thread-2", _servers())
    assert manager is not None
    started = time.monotonic()
    assert manager.start() == {"fake": True}
    assert time.monotonic() - started < 0.5
    assert manager.is_alive("fake")
    assert manager.call("fake", "shout", {"text": "hi"})["content"] == "HI"
    executor._close_mcp_managers()

    executor, controller = _pair(tmp_path, factory)
    executor.start()
    try:
        request_id = controller.send_payload(
            task_payload("use the tool", "thread-3", mcp_servers=_servers())
        )
        events = controller.collect(request_id, timeout=60.0)
        assert events[-1]["type"] == "done"
        tool_events = [e for e in events if e.get("type") == "tool"]
        assert any("VIA MCP" in json.dumps(e) for e in tool_events), tool_events
    finally:
        executor.stop()
