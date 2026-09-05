"""Browser presence on the wire (Bead cowork-vzm, phase d).

The host knows whether the agent has a browser open — from the Playwright tool
calls it forwards and from what ``cowork-vnc-up`` counts on the display — and
tells the app: ``browser_view`` ``opened`` / ``closed`` once per change, and
``browser_open`` in every ``run_state``. The app shows its browser button only
while that says yes. No container, no real MCP server here: the tool-event
seam and the replay header are exercised directly.
"""

from __future__ import annotations

from cowork_agent import MockModelClient, StateStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor.protocol import browser_state_from_tool, run_state_payload

from wiring import paired_channel


# -- protocol ----------------------------------------------------------------


def test_browser_state_from_tool_reads_playwright_tools():
    nav = browser_state_from_tool("mcp__playwright__browser_navigate", {"url": "x"}, "completed")
    assert nav is True
    assert browser_state_from_tool("mcp__playwright__browser_close", {}, "completed") is False
    # A bare Playwright name (another server name, same tool scheme) counts too.
    assert browser_state_from_tool("mcp__other__browser_snapshot", {}, "completed") is True


def test_browser_state_from_tool_looks_through_tool_call():
    wrapped = {"name": "mcp__playwright__browser_click", "arguments": {"ref": "e1"}}
    assert browser_state_from_tool("tool_call", wrapped, "completed") is True
    closing = {"name": "mcp__playwright__browser_close"}
    assert browser_state_from_tool("tool_call", closing, "completed") is False
    assert browser_state_from_tool("tool_call", {"name": "run_command"}, "completed") is None
    assert browser_state_from_tool("tool_call", "not a dict", "completed") is None


def test_browser_state_from_tool_ignores_failures_and_other_tools():
    assert browser_state_from_tool("mcp__playwright__browser_navigate", {}, "error") is None
    assert browser_state_from_tool("mcp__playwright__browser_close", {}, "error") is None
    assert browser_state_from_tool("run_command", {"command": "ls"}, "completed") is None
    assert browser_state_from_tool("web_fetch", {}, "completed") is None
    assert browser_state_from_tool(None, {}, "completed") is None
    assert browser_state_from_tool("", {}, "completed") is None


def test_run_state_payload_carries_browser_open_only_when_given():
    assert "browser_open" not in run_state_payload("s", "idle")
    assert run_state_payload("s", "idle", browser_open=False)["browser_open"] is False
    assert run_state_payload("s", "running", run_id="r", browser_open=True)["browser_open"] is True


# -- executor ----------------------------------------------------------------


def _executor(tmp_path, db_path, channel, executor_ep) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="browser-presence",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=db_path,
        model_factory=lambda: MockModelClient(["done"]),
    )


def _tool(name: str, status: str = "completed", **arguments) -> dict:
    return {"name": name, "arguments": arguments, "status": status, "result": ""}


def _capture(executor: Executor) -> list[tuple[str, dict]]:
    events: list[tuple[str, dict]] = []
    executor._event = lambda rid, payload: events.append((rid, payload))  # type: ignore[method-assign]
    return events


def test_tool_events_flip_the_browser_state_once_and_before_the_tool_frame(tmp_path):
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, str(tmp_path / "state.db"), channel, executor_ep)
    events = _capture(executor)

    executor._on_tool_event("req-1", "thread-1", _tool("run_command", command="ls"))
    executor._on_tool_event("req-1", "thread-1", _tool("mcp__playwright__browser_navigate", url="x"))
    executor._on_tool_event("req-1", "thread-1", _tool("mcp__playwright__browser_snapshot"))
    executor._on_tool_event("req-1", "thread-1", _tool("mcp__playwright__browser_close", status="error"))
    executor._on_tool_event("req-2", "thread-1", _tool("mcp__playwright__browser_close"))

    kinds = [(rid, p["type"], p.get("status"), p.get("name")) for rid, p in events]
    assert kinds == [
        ("req-1", "tool", "completed", "run_command"),
        # opened lands BEFORE the navigate frame, exactly once for two browser tools
        ("req-1", "browser_view", "opened", None),
        ("req-1", "tool", "completed", "mcp__playwright__browser_navigate"),
        ("req-1", "tool", "completed", "mcp__playwright__browser_snapshot"),
        # a failed close proves nothing
        ("req-1", "tool", "error", "mcp__playwright__browser_close"),
        # the real close, on the stream that learned it
        ("req-2", "browser_view", "closed", None),
        ("req-2", "tool", "completed", "mcp__playwright__browser_close"),
    ]
    assert executor._browser_open is False


def test_run_state_reports_browser_open_and_stop_resets_it(tmp_path):
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    _capture(executor)
    store = StateStore(db_path)
    try:
        assert executor._run_state_for(store, "thread-1")["browser_open"] is False
        executor._on_tool_event("req-1", "thread-1", _tool("mcp__playwright__browser_navigate"))
        state = executor._run_state_for(store, "thread-1")
        assert state["state"] == "idle" and state["browser_open"] is True
        executor.stop()
        assert executor._run_state_for(store, "thread-1")["browser_open"] is False
    finally:
        store.close()


def test_replay_header_carries_browser_open_over_the_wire(tmp_path):
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        # The browser opened on some earlier run; the flag is process state.
        with executor._vnc_lock:
            executor._browser_open = True
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    state = events[0]
    assert state["type"] == "run_state"
    assert state["browser_open"] is True
