"""The user's own browser on the host side (docs/WIRE_CONTRACT.md, "The user's
own browser"; bead chuk_chat-rixw).

A fake add-on dials the broker's bridge socket exactly as
``tools/agents-browser-bridge`` does, and coworkers dial its client socket, some
through the real ``agents-extension-mcp`` code. No browser, no network.
"""

from __future__ import annotations

import json
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from chuk_agents_runtime import MockModelClient
from chuk_agents_runtime.action_policy import BROWSER_ACT, ActionPolicy
from chuk_agents_runtime.takeover import current_tab_url
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import Executor, loopback_pair
from chuk_agents_executor import protocol
from chuk_agents_executor import user_browser as ub
from chuk_agents_executor.protocol import run_state_payload

from wiring import paired_channel

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "agents-extension-mcp"))
import agents_extension_mcp as mcp  # noqa: E402


# -- fakes -----------------------------------------------------------------------


class FakeAddon:
    """The add-on behind the bridge: answers every command, records frames."""

    def __init__(self, path: Path, *, tabs=None, driving=None) -> None:
        self.frames: list[dict] = []
        self.tabs = tabs or []
        self.driving = driving
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.connect(str(path))
        self.send({"type": "browser_attach", "attached": True, "browser": "chrome",
                   "version": "0.2.0", "engine": "cdp", "features": {"trusted_input": True}})
        threading.Thread(target=self._read, daemon=True).start()

    def send(self, frame: dict) -> None:
        self.conn.sendall(json.dumps(frame).encode() + b"\n")

    def _read(self) -> None:
        buffer = b""
        while True:
            try:
                chunk = self.conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                frame = json.loads(line)
                self.frames.append(frame)
                if frame.get("type") == "browser_cmd":
                    self.send(self.answer(frame))

    def answer(self, frame: dict) -> dict:
        if frame["op"] == "browser_tabs" and frame["args"].get("action") == "list":
            data = {"driving": self.driving, "tabs": self.tabs}
        else:
            data = {"op": frame["op"]}
        return {"type": "browser_result", "cmd_id": frame["cmd_id"], "ok": True, "data": data}

    def ops(self) -> list[str]:
        return [f["op"] for f in self.frames if f.get("type") == "browser_cmd"]

    def close(self) -> None:
        self.conn.shutdown(socket.SHUT_RDWR)
        self.conn.close()


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def paths():
    # Short paths: a unix socket path has a 108-byte limit.
    base = Path(tempfile.mkdtemp(prefix="ub"))
    return base / "bridge.sock", base / "broker.sock"


@pytest.fixture
def broker(paths):
    clock = Clock()
    broker = ub.BrowserBroker(*paths, idle_release=60, clock=clock).start()
    broker.clock = clock  # type: ignore[attr-defined]
    yield broker
    broker.close()


def wait_for(predicate, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return False


def addon(broker, **kw) -> FakeAddon:
    fake = FakeAddon(broker.bridge_path, **kw)
    assert wait_for(lambda: broker.status()["connected"] and broker.status()["browser"] == "chrome")
    return fake


def client(broker, session: str) -> mcp.BrokerClient:
    return mcp.BrokerClient(broker.client_path, session)


# -- the broker --------------------------------------------------------------------


def test_status_says_what_is_there_and_never_a_page(broker):
    status = broker.status()
    assert status["host_listening"] is True and status["connected"] is False
    fake = addon(broker)
    status = broker.status()
    assert status == {
        "host_listening": True,
        "connected": True,
        "browser": "chrome",
        "version": "0.2.0",
        "trusted_input": True,
        "holder": None,
        "stopped": False,
    }
    fake.close()
    assert wait_for(lambda: broker.status()["connected"] is False)


def test_sockets_are_private(broker):
    for path in (broker.bridge_path, broker.client_path):
        assert path.stat().st_mode & 0o777 == 0o600
    assert broker.bridge_path.parent.stat().st_mode & 0o777 == 0o700


def test_a_live_broker_is_never_robbed_of_its_socket(broker):
    with pytest.raises(ub.BrokerBusy):
        ub.BrowserBroker(broker.bridge_path, broker.client_path).start()
    assert broker.bridge_path.exists()


def test_a_dead_socket_from_an_earlier_host_is_replaced(paths):
    for path in paths:  # a host that died without cleaning up leaves these
        path.parent.mkdir(parents=True, exist_ok=True)
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        dead.bind(str(path))
        dead.close()
        assert path.exists()
    second = ub.BrowserBroker(*paths).start()
    try:
        assert second.running
    finally:
        second.close()


def test_without_the_addon_the_coworker_is_told_what_to_ask_for(broker):
    with pytest.raises(RuntimeError, match="add-on is not connected"):
        client(broker, "a").call("browser_snapshot", {})


def test_one_coworker_holds_the_browser_and_reading_takes_nothing(broker):
    fake = addon(broker)
    a, b = client(broker, "agent-a"), client(broker, "agent-b")
    assert a.call("browser_navigate", {"url": "https://example.com"}) == {"op": "browser_navigate"}
    assert broker.status()["holder"] == "agent-a"
    with pytest.raises(RuntimeError, match="in use by another coworker"):
        b.call("browser_click", {"ref": "e1"})
    # The tab list is a read: it works for anyone and takes nothing.
    b.call("browser_tabs", {"action": "list"})
    assert broker.status()["holder"] == "agent-a"
    a.call("browser_close", {})
    assert wait_for(lambda: broker.status()["holder"] is None)
    b.call("browser_click", {"ref": "e1"})
    assert broker.status()["holder"] == "agent-b"
    # The add-on lets go of agent-a's tab before agent-b's first step.
    assert fake.ops() == [
        "browser_navigate", "browser_tabs", "browser_close", "browser_close", "browser_click",
    ]


def test_after_a_handoff_the_next_coworker_never_works_in_that_tab(broker):
    fake = addon(broker)
    a, b = client(broker, "agent-a"), client(broker, "agent-b")
    a.call("browser_snapshot", {})
    a.call("browser_handoff", {"reason": "sign in"})
    assert wait_for(lambda: broker.status()["holder"] is None)
    a.call("browser_snapshot", {})  # the same coworker carries on in its tab
    a.call("browser_close", {})
    assert wait_for(lambda: broker.status()["holder"] is None)
    b.call("browser_snapshot", {})
    assert fake.ops() == [
        "browser_snapshot", "browser_handoff", "browser_snapshot", "browser_close",
        "browser_close", "browser_snapshot",
    ]


def test_an_idle_holder_lets_go_and_its_tab_is_released(broker):
    fake = addon(broker)
    a, b = client(broker, "agent-a"), client(broker, "agent-b")
    a.call("browser_snapshot", {})
    broker.clock.now += 61
    b.call("browser_snapshot", {})
    assert broker.status()["holder"] == "agent-b"
    # The add-on was told to let go of agent-a's tab before agent-b's command.
    assert fake.ops() == ["browser_snapshot", "browser_close", "browser_snapshot"]


def test_a_coworker_that_goes_away_lets_go(broker):
    addon(broker)
    a = client(broker, "agent-a")
    a.call("browser_snapshot", {})
    a.conn.shutdown(socket.SHUT_RDWR)
    a.conn.close()
    assert wait_for(lambda: broker.status()["holder"] is None)


def test_the_users_stop_stops_the_run_and_every_command(broker):
    fake = addon(broker)
    stopped: list[str] = []
    broker.add_stop_listener(stopped.append)
    a, b = client(broker, "agent-a"), client(broker, "agent-b")
    a.call("browser_navigate", {"url": "https://shop.example"})
    fake.send({"type": "browser_stop", "reason": "page"})
    assert wait_for(lambda: broker.status()["stopped"])
    assert stopped == ["agent-a"]
    assert broker.status()["holder"] is None
    for who in (a, b):
        with pytest.raises(RuntimeError, match="pressed Stop"):
            who.call("browser_snapshot", {})
    # An automation does not lift the user's Stop; a task the user sent does.
    broker.begin_run("agent-a", by_user=False)
    assert broker.status()["stopped"] is True
    broker.begin_run("agent-a", by_user=True)
    assert broker.status()["stopped"] is False
    assert wait_for(lambda: any(f.get("type") == "browser_resume" for f in fake.frames))
    a.call("browser_snapshot", {})


def test_allow_again_in_the_browser_lifts_the_stop(broker):
    fake = addon(broker)
    fake.send({"type": "browser_stop"})
    assert wait_for(lambda: broker.status()["stopped"])
    fake.send({"type": "browser_resume"})
    assert wait_for(lambda: not broker.status()["stopped"])


def test_a_browser_that_was_stopped_before_the_host_came_says_so(broker):
    fake = FakeAddon.__new__(FakeAddon)
    fake.frames, fake.tabs, fake.driving = [], [], None
    fake.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    fake.conn.connect(str(broker.bridge_path))
    fake.send({"type": "browser_attach", "browser": "chrome", "stopped": True})
    assert wait_for(lambda: broker.status()["stopped"])


def test_change_listeners_hear_attach_and_holder(broker):
    seen: list[dict] = []
    broker.add_change_listener(seen.append)
    addon(broker)
    client(broker, "agent-a").call("browser_snapshot", {})
    assert wait_for(lambda: any(s["holder"] == "agent-a" for s in seen))
    assert any(s["connected"] for s in seen)


# -- what the coworker reads ---------------------------------------------------------


TABS = [
    {"id": 41, "title": "Inbox (3)", "url": "https://mail.example.org/u/0/?token=SECRET#inbox", "active": True},
    {"id": 42, "title": "Pull [#7]", "url": "https://github.com/acme/app/pull/7?diff=split", "active": False},
]


def test_the_tab_list_reads_like_playwright_and_hides_other_tabs_queries(broker):
    addon(broker, tabs=TABS, driving=42)
    response = mcp.handle(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "browser_tabs", "arguments": {"action": "list"}}},
        client(broker, "agent-a"),
    )
    text = response["result"]["content"][0]["text"]
    assert "SECRET" not in text, "a tab the coworker does not hold shows no query"
    assert "- 41: [Inbox (3)](https://mail.example.org/u/0/)" in text
    assert "- 42: (current) [Pull (#7)](https://github.com/acme/app/pull/7?diff=split)" in text
    # The host's site reader understands it unchanged.
    assert current_tab_url(text) == "https://github.com/acme/app/pull/7?diff=split"
    assert ub.tab_url_from_list(text, 41) == "https://mail.example.org/u/0/"
    assert ub.tab_url_from_list(text, 99) is None


def test_site_for_names_the_site_a_call_acts_on():
    text = mcp.tabs_text({"driving": None, "tabs": TABS})
    assert ub.site_for("browser_navigate", {"url": "https://www.Example.com/x"}, lambda: text) == "www.example.com"
    assert ub.site_for("browser_tabs", {"action": "select", "tabId": 41}, lambda: text) == "mail.example.org"
    assert ub.site_for("browser_tabs", {"action": "select", "tabId": 7}, lambda: text) == ""
    assert ub.site_for("browser_click", {"ref": "e1"}, lambda: text) is None


def test_native_host_status_reads_the_registration(tmp_path):
    bridge = tmp_path / "bridge.py"
    bridge.write_text("#")
    chrome = tmp_path / "chrome"
    chrome.mkdir()
    (chrome / "dev.chuk.cowork.json").write_text(json.dumps({
        "name": "dev.chuk.cowork", "path": str(bridge),
        "allowed_origins": ["chrome-extension://gchdfokldhdgbjmdcjmkeapcknekogmm/"],
    }))
    missing = tmp_path / "brave"
    status = ub.native_host_status({"chrome": str(chrome), "brave": str(missing)})
    assert status == {
        "installed": True,
        "browsers": ["chrome"],
        "extension_ids": ["gchdfokldhdgbjmdcjmkeapcknekogmm"],
    }
    bridge.unlink()  # a registration that points nowhere does not count
    assert ub.native_host_status({"chrome": str(chrome)})["installed"] is False


def test_socket_dir_is_the_private_runtime_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    assert ub.socket_dir() == tmp_path / "chuk-agents"
    assert mcp.socket_dir() == tmp_path / "chuk-agents", "the MCP server must agree"
    monkeypatch.delenv("XDG_RUNTIME_DIR")
    assert ub.socket_dir().name == ".agents"


# -- the executor --------------------------------------------------------------------


def _executor(tmp_path, *, hook=None) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    return Executor(
        name="user-browser",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["unused"]),
        action_approvals=hook,
    )


class _Hook:
    def __init__(self, policy: ActionPolicy) -> None:
        self.policy = policy

    def policy_for(self, _key):
        return self.policy

    def remember(self, *_a, **_k):
        pass


_NO_KILL = SimpleNamespace(interrupted=lambda: False, estop_engaged=lambda: False)


def test_the_executor_binds_the_user_browser_policy(tmp_path, monkeypatch):
    executor = _executor(tmp_path, hook=_Hook(ActionPolicy()))
    monkeypatch.setattr(executor, "_uses_user_browser", lambda key: True)
    binding = executor._action_approvals_binding("r1", _NO_KILL, "agent-a")
    assert binding.user_browser is True and binding.site_for is not None
    assert binding.current().evaluate(BROWSER_ACT, "github.com") == "ask"
    monkeypatch.setattr(executor, "_uses_user_browser", lambda key: False)
    sandbox = executor._action_approvals_binding("r1", _NO_KILL, "agent-a")
    assert sandbox.user_browser is False and sandbox.site_for is None
    assert sandbox.current().evaluate(BROWSER_ACT, "github.com") == "allow"


def test_the_user_browser_asks_even_on_a_host_without_a_policy_store(tmp_path, monkeypatch):
    executor = _executor(tmp_path, hook=None)
    monkeypatch.setattr(executor, "_uses_user_browser", lambda key: False)
    assert executor._action_approvals_binding("r1", _NO_KILL, "s") is None
    monkeypatch.setattr(executor, "_uses_user_browser", lambda key: True)
    binding = executor._action_approvals_binding("r1", _NO_KILL, "s")
    assert binding is not None
    assert binding.current().evaluate(BROWSER_ACT, "x.example") == "ask"


def test_a_stop_in_the_browser_stops_that_coworkers_run(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    hits: list[str] = []
    runs = [
        SimpleNamespace(session_key="agent-a", request_id="r-a", kill=SimpleNamespace(interrupt=lambda: hits.append("a"))),
        SimpleNamespace(session_key="agent-b", request_id="r-b", kill=SimpleNamespace(interrupt=lambda: hits.append("b"))),
    ]
    monkeypatch.setattr(executor, "_live_runs", lambda: runs)
    executor._on_user_browser_stop("agent-a")
    assert hits == ["a"]


def test_run_state_names_the_browser(tmp_path, monkeypatch):
    from chuk_agents_runtime import StateStore

    executor = _executor(tmp_path)
    store = StateStore(str(tmp_path / "state.db"))
    try:
        monkeypatch.setattr(executor, "_uses_user_browser", lambda key: key == "agent-a")
        assert executor._run_state_for(store, "agent-a")["browser_target"] == "user_browser"
        assert executor._run_state_for(store, "agent-b")["browser_target"] == "sandbox"
    finally:
        store.close()
    assert "browser_target" not in run_state_payload("s", "idle")
    assert "browser_target" not in run_state_payload("s", "idle", browser_target="holodeck")


def test_the_extension_entry_names_its_coworker():
    entry = protocol.extension_mcp_entry("agent-a")
    assert entry is not None
    assert entry["env"] == {"AGENTS_BROWSER_SESSION": "agent-a"}
    assert "env" not in protocol.extension_mcp_entry()


def test_the_mcp_server_picks_the_broker_when_the_host_runs(broker, monkeypatch):
    monkeypatch.setenv("AGENTS_BROWSER_BROKER_SOCKET", str(broker.client_path))
    monkeypatch.setenv("AGENTS_BROWSER_SESSION", "agent-z")
    chosen = mcp.connect([])
    assert isinstance(chosen, mcp.BrokerClient) and chosen.session == "agent-z"


# -- the whole chain, as processes -------------------------------------------------


def test_chrome_bridge_broker_and_mcp_server_as_real_processes(broker):
    """Chrome's native-messaging framing on one end, the agent's MCP stdio on
    the other, the host's broker in the middle."""
    import os
    import struct
    import subprocess

    env = {
        **os.environ,
        "AGENTS_BRIDGE_SOCKET": str(broker.bridge_path),
        "AGENTS_BROWSER_BROKER_SOCKET": str(broker.client_path),
        "AGENTS_BROWSER_SESSION": "agent-a",
    }
    bridge = subprocess.Popen(
        [sys.executable, str(ROOT / "tools" / "agents-browser-bridge" / "agents_browser_bridge.py")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
    )
    server = subprocess.Popen(
        [sys.executable, str(ROOT / "tools" / "agents-extension-mcp" / "agents_extension_mcp.py")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True,
    )
    try:
        def chrome_write(payload):
            body = json.dumps(payload).encode()
            bridge.stdin.write(struct.pack("<I", len(body)) + body)
            bridge.stdin.flush()

        def chrome_read():
            (length,) = struct.unpack("<I", bridge.stdout.read(4))
            return json.loads(bridge.stdout.read(length))

        assert chrome_read()["type"] == "bridge_ready"
        chrome_write({"type": "browser_attach", "browser": "chrome", "version": "0.2.0"})
        assert wait_for(lambda: broker.status()["connected"])

        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                       "params": {"name": "browser_snapshot", "arguments": {}}}) + "\n")
        server.stdin.flush()
        command = chrome_read()
        assert command["type"] == "browser_cmd" and command["op"] == "browser_snapshot"
        chrome_write({"type": "browser_result", "cmd_id": command["cmd_id"], "ok": True,
                      "data": {"url": "https://example.com", "nodes": []}})
        answer = json.loads(server.stdout.readline())
        assert json.loads(answer["result"]["content"][0]["text"])["url"] == "https://example.com"
        assert broker.status()["holder"] == "agent-a"

        # The user's Stop travels back up the same chain.
        chrome_write({"type": "browser_stop", "reason": "page"})
        assert wait_for(lambda: broker.status()["stopped"])
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                       "params": {"name": "browser_click", "arguments": {"ref": "e1"}}}) + "\n")
        server.stdin.flush()
        refused = json.loads(server.stdout.readline())
        assert refused["result"]["isError"] is True
        assert "pressed Stop" in refused["result"]["content"][0]["text"]
    finally:
        for proc in (bridge, server):
            proc.kill()
            proc.wait(5)
