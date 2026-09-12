"""Browser presence on the wire (Bead cowork-vzm, phase d).

The host knows whether the agent has a browser open — from the Playwright tool
calls it forwards and from what ``cowork-vnc-up`` counts on the display — and
tells the app: ``browser_view`` ``opened`` / ``closed`` once per change, and
``browser_open`` in every ``run_state``. The app shows its browser button only
while that says yes. No container, no real MCP server here: the tool-event
seam and the replay header are exercised directly.
"""

from __future__ import annotations

from types import SimpleNamespace

from cowork_agent import MockModelClient, StateStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor import protocol
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
    assert run_state_payload("s", "running", browser_open=True)["vnc_available"] is False
    assert run_state_payload("s", "running", vnc_available=True)["vnc_available"] is True


def test_vnc_capability_requires_existing_sandbox_browser(tmp_path, monkeypatch):
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, str(tmp_path / "state.db"), channel, executor_ep)
    events = _capture(executor)
    executor._browser_open = True
    executor._browser_mcp = True
    assert executor._vnc_available("t") is False
    sandbox = SimpleNamespace(_cli=SimpleNamespace(binary="docker"), container_id="live")
    monkeypatch.setattr(executor, "_environment_for", lambda key: sandbox)
    monkeypatch.delenv(protocol.BROWSER_TARGET_ENV, raising=False)
    assert executor._vnc_available("t") is True
    executor._browser_open = False
    executor._on_tool_event("r", "t", _tool("mcp__playwright__browser_navigate"))
    assert events[0][1]["vnc_available"] is True
    monkeypatch.setenv(protocol.BROWSER_TARGET_ENV, "user_browser")
    assert executor._vnc_available("t") is False
    store = StateStore(str(tmp_path / "state.db"))
    try:
        assert executor._run_state_for(store, "t")["vnc_available"] is False
    finally:
        store.close()
    monkeypatch.delenv(protocol.BROWSER_TARGET_ENV, raising=False)
    sandbox.container_id = None
    assert executor._vnc_available("t") is False


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


# -- which browser: the sandbox, or the one the user already has open ---------
#
# Bead cowork-fa8. The add-on is a second target behind the same tool names, so
# nothing above this line has to change: the presence logic still matches on
# ``mcp__playwright__browser_*`` either way.


def test_browser_target_defaults_to_the_sandbox(monkeypatch):
    monkeypatch.delenv(protocol.BROWSER_TARGET_ENV, raising=False)
    assert protocol.browser_target() == protocol.SANDBOX_BROWSER


def test_browser_target_reads_the_environment(monkeypatch):
    monkeypatch.setenv(protocol.BROWSER_TARGET_ENV, "user_browser")
    assert protocol.browser_target() == protocol.USER_BROWSER


def test_an_unknown_target_still_runs_on_the_sandbox(monkeypatch):
    # A task from a newer app naming a target this executor never heard of must
    # still run, on the target it does have.
    monkeypatch.delenv(protocol.BROWSER_TARGET_ENV, raising=False)
    assert protocol.browser_target("holodeck") == protocol.SANDBOX_BROWSER
    assert protocol.browser_target("") == protocol.SANDBOX_BROWSER


def test_the_extension_entry_is_named_playwright():
    entry = protocol.extension_mcp_entry()
    assert entry is not None, "tools/cowork-extension-mcp ships with the repository"
    # The name is the whole compatibility seam: the agent builds tool names as
    # mcp__<server>__<tool>, and everything downstream matches on
    # mcp__playwright__browser_*.
    assert entry["name"] == "playwright"
    assert entry["args"][0].endswith("cowork_extension_mcp.py")
    assert browser_state_from_tool("mcp__playwright__browser_navigate", {}, "completed") is True


def test_a_missing_extension_server_is_reported_as_none(monkeypatch, tmp_path):
    monkeypatch.setenv(protocol.EXTENSION_MCP_ENV, str(tmp_path / "nope.py"))
    assert protocol.extension_mcp_script() is None
    assert protocol.extension_mcp_entry() is None


# -- the window probe (bead cowork-tf1u) --------------------------------------


def _browser_executor(tmp_path, monkeypatch):
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, str(tmp_path / "state.db"), channel, executor_ep)
    executor._browser_open = True
    executor._browser_mcp = True
    sandbox = SimpleNamespace(_cli=SimpleNamespace(binary="docker"), container_id="c1")
    monkeypatch.setattr(executor, "_environment_for", lambda key: sandbox)
    monkeypatch.delenv(protocol.BROWSER_TARGET_ENV, raising=False)
    return executor


def _probe(monkeypatch, *, code=0, out=""):
    calls: list[list[str]] = []

    def run(argv, **kwargs):
        calls.append(argv)
        return SimpleNamespace(returncode=code, stdout=out, stderr="")

    monkeypatch.setattr("cowork_executor.executor.subprocess.run", run)
    return calls


def test_a_display_with_no_browser_is_not_a_screen(tmp_path, monkeypatch):
    # The tool calls said the browser is open, but the MCP server took its
    # Chromium down with its own session. Offering the screen anyway is what
    # opened a black page.
    executor = _browser_executor(tmp_path, monkeypatch)
    _probe(monkeypatch, code=0, out="0\n")
    assert executor._vnc_available("t") is False


def test_a_browser_window_on_the_display_is_a_screen(tmp_path, monkeypatch):
    executor = _browser_executor(tmp_path, monkeypatch)
    _probe(monkeypatch, code=0, out="2\n")
    assert executor._vnc_available("t") is True


def test_a_probe_that_cannot_run_does_not_take_the_screen_away(tmp_path, monkeypatch):
    executor = _browser_executor(tmp_path, monkeypatch)
    _probe(monkeypatch, code=125, out="")
    assert executor._vnc_available("t") is True
    executor._browser_window_probe.clear()

    def boom(argv, **kwargs):
        raise OSError("docker gone")

    monkeypatch.setattr("cowork_executor.executor.subprocess.run", boom)
    assert executor._vnc_available("t") is True


def test_the_probe_runs_once_per_ttl(tmp_path, monkeypatch):
    executor = _browser_executor(tmp_path, monkeypatch)
    calls = _probe(monkeypatch, code=0, out="1\n")
    assert executor._vnc_available("t") is True
    assert executor._vnc_available("t") is True
    assert len(calls) == 1


def test_a_state_change_drops_the_cached_probe(tmp_path, monkeypatch):
    executor = _browser_executor(tmp_path, monkeypatch)
    _probe(monkeypatch, code=0, out="1\n")
    assert executor._vnc_available("t") is True
    executor._set_browser_open(False, "", "t")
    assert executor._browser_window_probe == {}
