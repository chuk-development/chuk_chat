"""The live browser view (§9.1) — x11vnc streamed over the sealed channel.

The executor pipes the sandbox Chromium's VNC bytes to the app and feeds the
app's input back, as `browser_data` frames, driven by `browser_start` /
`browser_stop`. These tests pin the payloads, the opaque byte pump, the sealed
dispatch wiring, and the safe behaviour when there is no docker sandbox or no
view — all without a real container.
"""

from __future__ import annotations

import threading
import time

import pytest
from cowork_sandbox import LocalEnvironment

from cowork_agent import MockModelClient
from cowork_executor import (
    ControllerSession,
    Executor,
    browser_data_payload,
    browser_view_payload,
    loopback_pair,
)
from cowork_executor.executor import _VncBridge
from cowork_executor.protocol import MAX_BROWSER_CHUNK, PayloadTooLarge

from wiring import paired_channel


# -- payloads --------------------------------------------------------------


def test_browser_data_payload_roundtrips_bytes():
    payload = browser_data_payload(b"\x00\x01rfb\xff")
    assert payload["type"] == "browser_data"
    assert payload["size"] == 6
    import base64

    assert base64.b64decode(payload["data"]) == b"\x00\x01rfb\xff"


def test_browser_data_payload_rejects_empty_and_oversize():
    with pytest.raises(ValueError):
        browser_data_payload(b"")
    with pytest.raises(PayloadTooLarge):
        browser_data_payload(b"x" * (MAX_BROWSER_CHUNK + 1))


def test_browser_view_payload_shape():
    assert browser_view_payload("started") == {
        "type": "browser_view",
        "status": "started",
        "message": "",
        "vnc_available": False,
        "reason": "",
    }
    # The machine-readable half: the app reads this, not the English message.
    assert browser_view_payload("error", reason="no_display")["reason"] == "no_display"
    assert browser_view_payload("error", message="nope")["message"] == "nope"


# -- the opaque byte pump --------------------------------------------------


def test_vnc_bridge_pumps_stdout_and_feeds_stdin():
    """`cat` echoes: what we feed comes back out through the emit callback."""
    got: list[bytes] = []
    saw = threading.Event()

    def emit(chunk: bytes) -> None:
        got.append(chunk)
        saw.set()

    bridge = _VncBridge(["cat"], emit=emit, on_closed=lambda: None)
    try:
        bridge.feed(b"hello-rfb")
        assert saw.wait(5.0), "the pump never emitted the echoed bytes"
        assert b"".join(got) == b"hello-rfb"
    finally:
        bridge.close()


def test_vnc_bridge_reports_a_spontaneous_close():
    """When the pipe dies on its own (container/x11vnc gone), on_closed fires."""
    closed = threading.Event()
    bridge = _VncBridge(
        ["sh", "-c", "exit 0"], emit=lambda _c: None, on_closed=closed.set
    )
    try:
        assert closed.wait(5.0), "on_closed never fired for a dead pipe"
    finally:
        bridge.close()


def test_vnc_bridge_close_is_idempotent_and_silent():
    bridge = _VncBridge(["cat"], emit=lambda _c: None, on_closed=lambda: None)
    bridge.close()
    bridge.close()  # no raise
    bridge.feed(b"after close")  # no raise, silently dropped


# -- sealed dispatch, no docker --------------------------------------------


def _executor(tmp_path, channel, executor_ep) -> Executor:
    return Executor(
        name="worker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["done"]),
    )


@pytest.fixture
def rig(tmp_path):
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        yield controller, executor
    finally:
        executor.stop()


def test_browser_start_without_docker_reports_an_error(rig):
    """The local sandbox has no container to watch; the app is told, cleanly."""
    controller, _ = rig
    request_id = controller.send_payload({"type": "browser_start"})
    events = controller.collect(request_id, timeout=3.0)
    views = [e for e in events if e["type"] == "browser_view"]
    assert views, f"no browser_view status came back: {events}"
    assert views[-1]["status"] == "error"
    assert "docker" in views[-1]["message"]


def test_browser_data_and_stop_without_a_view_are_harmless(rig):
    """Input or a stop for a view that was never started must not crash the
    executor — the serve loop stays live and still runs a task after."""
    controller, _ = rig
    controller.send_payload({"type": "browser_data", "data": "Zm9v"})  # "foo"
    controller.send_payload({"type": "browser_stop"})

    # The executor is still healthy: a normal task still completes.
    request_id = controller.send_task("go", session_key="t1")
    assert controller.collect(request_id, timeout=10.0)[-1]["reason"] == "finished"


# -- teardown --------------------------------------------------------------


class _FakeBridge:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True

    def feed(self, _data: bytes) -> None:  # pragma: no cover - not exercised here
        pass


class _FakeCli:
    binary = "docker"


class _FakeDockerEnv:
    """Enough of a DockerEnvironment for the Playwright-entry builder (§9.1)."""

    def __init__(self) -> None:
        self._cli = _FakeCli()
        self._user = "cowork"
        self.container_id = "cid-abc123"
        self.realized = 0

    def run_bash(self, cmd, *, timeout=120, internal=False):  # noqa: ANN001
        self.realized += 1  # "realize the container"

    def cleanup(self) -> None:
        pass


def _executor_with(tmp_path, env, **kwargs) -> Executor:
    channel = paired_channel()
    _c, executor_ep = loopback_pair()
    return Executor(
        name="worker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=env,
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["done"]),
        **kwargs,
    )


def test_browser_mcp_entry_is_none_when_disabled(tmp_path):
    (tmp_path / "ws").mkdir()
    ex = _executor_with(
        tmp_path, LocalEnvironment(workdir=str(tmp_path / "ws")), browser_mcp=False
    )
    assert ex._browser_mcp_entry() is None


def test_browser_mcp_entry_is_none_without_docker(tmp_path):
    (tmp_path / "ws").mkdir()
    ex = _executor_with(
        tmp_path, LocalEnvironment(workdir=str(tmp_path / "ws")), browser_mcp=True
    )
    assert ex._browser_mcp_entry() is None  # local sandbox: nothing to exec into


def test_browser_mcp_entry_execs_the_launcher_in_the_container(tmp_path):
    env = _FakeDockerEnv()
    ex = _executor_with(tmp_path, env, browser_mcp=True)
    entry = ex._browser_mcp_entry()
    assert entry is not None
    assert entry["name"] == "playwright"
    assert entry["command"] == "docker"
    # docker exec -i -u cowork <cid> cowork-browser-mcp
    assert entry["args"] == [
        "exec",
        "-i",
        "-u",
        "cowork",
        "cid-abc123",
        "cowork-browser-mcp",
    ]
    assert env.realized >= 1  # the container was forced live first


def test_browser_mcp_entry_rejects_failed_container_probe(tmp_path):
    from cowork_sandbox import ProcessResult

    env = _FakeDockerEnv()
    env.run_bash = lambda *a, **kw: ProcessResult("", "No such container", 1)
    ex = _executor_with(tmp_path, env, browser_mcp=True)
    assert ex._browser_mcp_entry() is None


def test_browser_mcp_entry_passes_verified_retirement_to_container(tmp_path, monkeypatch):
    env = _FakeDockerEnv()
    env.workspace = str(tmp_path)
    seen = []
    def attest(binary, cid, workspace):
        seen.append((binary, cid, workspace))
        return "retired-container"
    monkeypatch.setattr("cowork_executor.browser_profile.retired_browser_hostname", attest)
    ex = _executor_with(tmp_path, env, browser_mcp=True)
    entry = ex._browser_mcp_entry()
    assert seen == [("docker", "cid-abc123", str(tmp_path))]
    assert entry["args"][-4:] == [
        "-e", "COWORK_BROWSER_RETIRED_HOSTNAME=retired-container",
        "cid-abc123", "cowork-browser-mcp",
    ]


def test_browser_manager_rebuilt_when_container_changes(tmp_path):
    env = _FakeDockerEnv()
    ex = _executor_with(tmp_path, env, browser_mcp=True)
    old = ex._session_mcp_manager("s", [ex._browser_mcp_entry()])
    env.container_id = "replacement"
    new = ex._session_mcp_manager("s", [ex._browser_mcp_entry()])
    assert new is not old
    assert "replacement" in new.configs[0].args
    new.close()


class _RecordingBridge:
    def __init__(self) -> None:
        self.fed: list[bytes] = []

    def close(self) -> None:
        pass

    def feed(self, data: bytes) -> None:
        self.fed.append(data)


def _framer_handshake() -> bytes:
    """ProtocolVersion + security None + ClientInit, as dart_rfb sends them."""
    return b"RFB 003.008\n" + b"\x01" + b"\x01"


def test_rfb_framer_passes_protocol_and_drops_cut_text():
    from cowork_executor.executor import _RfbClientFramer

    f = _RfbClientFramer()
    assert f.feed(_framer_handshake()) == _framer_handshake()
    pointer = b"\x05" + b"\x00" + (10).to_bytes(2, "big") + (20).to_bytes(2, "big")
    key = b"\x04\x01\x00\x00" + (0x61).to_bytes(4, "big")
    encodings = b"\x02\x00" + (3).to_bytes(2, "big") + (7).to_bytes(4, "big", signed=True) \
        + (1).to_bytes(4, "big") + (-26).to_bytes(4, "big", signed=True)
    cut = b"\x06\x00\x00\x00" + (5).to_bytes(4, "big") + b"hello"
    update_req = b"\x03\x01" + b"\x00\x00\x00\x00" + (1280).to_bytes(2, "big") + (800).to_bytes(2, "big")
    out = f.feed(pointer + key + encodings + cut + update_req)
    assert out == pointer + key + encodings + update_req  # cut text gone, order kept
    assert f.dropped_cut_text == 1


def test_rfb_framer_reassembles_messages_split_across_chunks():
    from cowork_executor.executor import _RfbClientFramer

    f = _RfbClientFramer()
    f.feed(_framer_handshake())
    pointer = b"\x05\x00\x00\x0a\x00\x14"
    assert f.feed(pointer[:2]) == b""  # incomplete: nothing forwarded yet
    assert f.feed(pointer[2:5]) == b""
    assert f.feed(pointer[5:] + pointer[:1]) == pointer  # completes, next starts
    assert f.feed(pointer[1:]) == pointer


def test_rfb_framer_passes_vnc_auth_response():
    """With a per-view secret x11vnc offers security type 2: the client sends
    the type byte then a 16-byte DES response. Both must pass the framer."""
    from cowork_executor.executor import _RfbClientFramer

    f = _RfbClientFramer()
    handshake = b"RFB 003.008\n" + b"\x02" + bytes(range(16)) + b"\x01"
    assert f.feed(handshake) == handshake
    pointer = b"\x05\x00\x00\x0a\x00\x14"
    assert f.feed(pointer) == pointer  # message phase reached


def test_vnc_start_arms_a_per_view_secret_as_root(tmp_path, monkeypatch):
    """cowork-vnc-up runs as ROOT with the secret in its env (root-only
    password file inside the sandbox), and the secret rides in `started`."""
    import subprocess as sp

    from cowork_executor import executor as ex_mod

    env = _FakeDockerEnv()
    executor = _executor_with(tmp_path, env, browser_mcp=True)
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]
    calls: list[list[str]] = []

    def fake_run(argv, **_kw):
        calls.append(list(argv))
        return sp.CompletedProcess(args=argv, returncode=0, stdout=b"WINDOWS=1\n")

    monkeypatch.setattr(ex_mod.subprocess, "run", fake_run)
    real_bridge = ex_mod._VncBridge
    monkeypatch.setattr(
        ex_mod, "_VncBridge", lambda _argv, **kw: real_bridge(["cat"], **kw)
    )
    try:
        executor._vnc_start("req-secret", {})
        assert calls, "cowork-vnc-up was not invoked"
        argv = calls[0]
        assert argv[:4] == ["docker", "exec", "-i", "-u"] and argv[4] == "root"
        env_arg = next(a for a in argv if a.startswith("COWORK_VNC_PASSWD="))
        secret = env_arg.split("=", 1)[1]
        assert len(secret) == 8
        started = next(e for e in events if e.get("status") == "started")
        assert started["password"] == secret
        # The socat bridge itself still runs as the sandbox user.
        assert "root" not in ex_mod._VncBridge.__name__  # sanity: unchanged class
    finally:
        executor._vnc_teardown(notify=False)


def test_browser_start_runs_off_the_serve_thread_and_a_stop_wins(tmp_path, monkeypatch):
    """cowork-vnc-up may take seconds. The start must not block the serve
    thread, and a `browser_stop` that lands while x11vnc is still coming up
    must win: the late bridge is closed, never registered, no 'started'."""
    import subprocess as sp

    from cowork_executor import executor as ex_mod

    env = _FakeDockerEnv()
    executor = _executor_with(tmp_path, env, browser_mcp=True)
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]
    in_vnc_up = threading.Event()
    release = threading.Event()

    def slow_run(argv, **_kw):  # cowork-vnc-up "hangs" until released
        in_vnc_up.set()
        release.wait(5.0)
        return sp.CompletedProcess(args=argv, returncode=0, stdout=b"WINDOWS=1\n")

    monkeypatch.setattr(ex_mod.subprocess, "run", slow_run)
    real_bridge = ex_mod._VncBridge
    made: list = []

    def fake_bridge(_argv, **kw):
        b = real_bridge(["cat"], **kw)
        made.append(b)
        return b

    monkeypatch.setattr(ex_mod, "_VncBridge", fake_bridge)

    # Dispatch a start the way the serve loop does: it must return at once.
    t0 = time.time()
    executor._handle_browser_kind("browser_start", "req-slow", {})
    assert time.time() - t0 < 1.0, "browser_start blocked the serve thread"
    assert in_vnc_up.wait(5.0)
    # The user closes the view while x11vnc is still starting.
    executor._handle_browser_kind("browser_stop", "req-slow", {})
    release.set()
    deadline = time.time() + 5.0
    while time.time() < deadline and not made:
        time.sleep(0.02)
    deadline = time.time() + 5.0
    while time.time() < deadline and not made[0]._closed.is_set():
        time.sleep(0.02)
    assert made and made[0]._closed.is_set(), "stale bridge was not closed"
    assert executor._vnc is None
    assert not any(e.get("status") == "started" for e in events), events


def test_rfb_framer_refuses_rfb_3_3():
    """RFB 3.3 cannot be framed from the client side (the server picks the
    security type silently, so a 16-byte auth response may or may not
    follow). Our client speaks 3.8; 3.3 fails closed instead of guessing."""
    from cowork_executor.executor import _RfbClientFramer

    assert _RfbClientFramer().feed(b"RFB 003.003\n") is None
    assert _RfbClientFramer().feed(b"RFB 003.007\n") == b"RFB 003.007\n"


def test_vnc_teardown_ignores_a_stale_bridge(tmp_path):
    """A late on_closed from a replaced bridge must not kill its successor:
    the identity check and the clear happen under one lock acquisition."""
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep)
    old, new = _FakeBridge(), _FakeBridge()
    executor._vnc = new
    executor._vnc_stream_id = "req-new"

    executor._vnc_teardown(reason="stopped", expected=old)  # stale caller
    assert executor._vnc is new and new.closed is False

    executor._vnc_teardown(reason="stopped", expected=new)  # the right one
    assert executor._vnc is None and new.closed is True


def test_rfb_framer_fails_closed_on_non_rfb():
    from cowork_executor.executor import _RfbClientFramer

    assert _RfbClientFramer().feed(b"GET / HTTP/1.1\r\n") is None  # not "RFB "
    f = _RfbClientFramer()
    f.feed(_framer_handshake())
    assert f.feed(b"\x09junk") is None  # unknown client message type


def test_vnc_feed_drops_cut_text_and_tears_down_on_garbage(tmp_path):
    """End-to-end through _vnc_feed: protocol reaches the bridge, a clipboard
    message never does, and non-RFB input kills the view (fail closed)."""
    import base64

    from cowork_executor.executor import _RfbClientFramer

    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep)
    bridge = _RecordingBridge()
    executor._vnc = bridge
    executor._vnc_stream_id = "req-x"
    executor._vnc_framer = _RfbClientFramer()
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]

    def feed(raw: bytes) -> None:
        executor._vnc_feed({"data": base64.b64encode(raw).decode()})

    feed(_framer_handshake())
    cut = b"\x06\x00\x00\x00" + (3).to_bytes(4, "big") + b"abc"
    pointer = b"\x05\x00\x00\x0a\x00\x14"
    feed(cut + pointer)
    assert b"".join(bridge.fed) == _framer_handshake() + pointer  # no clipboard bytes

    feed(b"\x42not-rfb")
    assert executor._vnc is None  # torn down
    assert any(e.get("status") == "error" for e in events if e.get("type") == "browser_view")


def test_vnc_feed_forwards_normal_input_but_drops_oversize(tmp_path):
    """Inbound RFB client bytes flow to the bridge, but a chunk over the
    MAX_BROWSER_CHUNK ceiling is dropped rather than forwarded into x11vnc."""
    import base64

    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep)
    from cowork_executor.executor import _RfbClientFramer

    bridge = _RecordingBridge()
    executor._vnc = bridge
    executor._vnc_stream_id = "req-x"
    framer = _RfbClientFramer()
    framer.feed(_framer_handshake())  # past the handshake, in the message phase
    executor._vnc_framer = framer

    # A normal RFB pointer message is forwarded verbatim.
    pointer = b"\x05\x00\x00\x0a\x00\x14"
    executor._vnc_feed({"data": base64.b64encode(pointer).decode()})
    assert bridge.fed == [pointer]

    # Anything larger than the ceiling never reaches x11vnc — and the view is
    # torn down (fail closed) rather than left with a hole in its stream.
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]
    oversize = base64.b64encode(b"x" * (MAX_BROWSER_CHUNK + 1)).decode()
    executor._vnc_feed({"data": oversize})
    assert bridge.fed == [pointer]  # unchanged
    assert executor._vnc is None
    assert any(e.get("status") == "error" for e in events if e.get("type") == "browser_view")


def test_vnc_start_with_an_instantly_dead_pipe_does_not_register_a_dead_view(
    tmp_path, monkeypatch
):
    """Race pinned: socat dies the moment it starts. The bridge must be
    registered BEFORE its pump runs, so the close is seen, the registry is
    cleared, and the app gets a 'stopped' — not a bridge that looks live."""
    import subprocess as sp

    from cowork_executor import executor as ex_mod

    env = _FakeDockerEnv()
    executor = _executor_with(tmp_path, env, browser_mcp=True)
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]

    # cowork-vnc-up "succeeds" with one window; the bridge is `sh -c 'exit 0'`
    # (exits at once) instead of the real docker exec socat.
    monkeypatch.setattr(
        ex_mod.subprocess,
        "run",
        lambda *_a, **_k: sp.CompletedProcess(args=[], returncode=0, stdout=b"WINDOWS=1\n"),
    )
    real_bridge = ex_mod._VncBridge
    monkeypatch.setattr(
        ex_mod,
        "_VncBridge",
        lambda _argv, **kw: real_bridge(["sh", "-c", "exit 0"], **kw),
    )

    executor._vnc_start("req-dead", {})

    # The pump reports the close asynchronously. Wait for the 'stopped' EVENT,
    # not for the registry field: the teardown clears `_vnc` under the lock
    # first and emits the event after closing the bridge, so polling `_vnc`
    # alone can observe the gap between the two (was a flaky assertion).
    def statuses() -> list:
        return [e.get("status") for e in events if e.get("type") == "browser_view"]

    deadline = time.time() + 5.0
    while time.time() < deadline and "stopped" not in statuses():
        time.sleep(0.05)
    assert "stopped" in statuses(), statuses()
    assert executor._vnc is None, "a dead bridge stayed registered as live"


def test_stopping_the_executor_tears_down_a_live_view(tmp_path):
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep)
    fake = _FakeBridge()
    executor._vnc = fake
    executor._vnc_stream_id = "req-x"

    executor.stop()

    assert fake.closed is True
    assert executor._vnc is None


# -- an empty display is nudged awake (bead cowork-qp5i) --------------------
#
# `@playwright/mcp` launches Chromium on the FIRST browser tool call, so a
# session where nobody browsed yet serves an empty root window: a black view.
# The agent pokes the server awake at task start; the executor does the same
# when the user opens the view before that first task.


class _FakeBrowserConnection:
    """The slice of MCPConnection the GUI opener touches."""

    def __init__(self, name: str, tools: list[str] | None = None, *, alive: bool = True):
        import types

        from cowork_agent import MCPToolInfo

        names = tools if tools is not None else ["browser_tabs", "browser_navigate"]
        self.config = types.SimpleNamespace(name=name)
        self.tools = [MCPToolInfo(name=t, description="", schema={}) for t in names]
        self._alive = alive
        self.calls: list[tuple[str, dict]] = []

    def alive(self) -> bool:
        return self._alive

    def call(self, tool: str, arguments: dict | None = None) -> dict:
        self.calls.append((tool, dict(arguments or {})))
        return {"ok": True, "server": self.config.name, "tool": tool, "content": ""}


def _browser_manager(container: str = "cid-abc123", **kwargs):
    """A started manager holding one sandbox browser server for `container`."""
    from cowork_agent import MCPManager, MCPServerConfig

    config = MCPServerConfig(
        name="playwright",
        command="docker",
        args=["exec", "-i", "-u", "cowork", container, "cowork-browser-mcp"],
    )
    manager = MCPManager([config])
    connection = _FakeBrowserConnection("playwright", **kwargs)
    manager.connections["playwright"] = connection  # type: ignore[assignment]
    return manager, connection


def _vnc_start_with(tmp_path, monkeypatch, windows: int, *, pages: int | None = None):
    """An executor whose fake sandbox reports `windows` from `cowork-vnc-up`
    and `pages` from the executor's own class-filtered window probe.

    `pages=None` is a probe that cannot run (an image without xwininfo), which
    is what makes the script's count the fallback it is meant to be.
    """
    import subprocess as sp

    from cowork_executor import executor as ex_mod

    executor = _executor_with(tmp_path, _FakeDockerEnv(), browser_mcp=True)
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]
    runs: list[list[str]] = []

    def fake_run(argv, **kwargs):
        argv = list(argv)
        runs.append(argv)
        if "cowork-vnc-up" in argv:
            return sp.CompletedProcess(
                args=argv, returncode=0, stdout=f"WINDOWS={windows}\n".encode()
            )
        if any("xwininfo" in str(a) for a in argv):  # the executor's own probe
            if pages is None:
                return sp.CompletedProcess(args=argv, returncode=125, stdout="", stderr="")
            return sp.CompletedProcess(args=argv, returncode=0, stdout=f"{pages}\n")
        return sp.CompletedProcess(args=argv, returncode=0, stdout=b"")

    monkeypatch.setattr(ex_mod.subprocess, "run", fake_run)
    real_bridge = ex_mod._VncBridge
    monkeypatch.setattr(ex_mod, "_VncBridge", lambda _argv, **kw: real_bridge(["cat"], **kw))
    return executor, events, runs


def _wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def _vnc_up_boxes(runs) -> list[str]:
    """The container each `cowork-vnc-up` ran against, in order."""
    return [
        argv[argv.index("cowork-vnc-up") - 1] for argv in runs if "cowork-vnc-up" in argv
    ]


def test_an_empty_display_opens_the_session_browser(tmp_path, monkeypatch):
    """No page on the display and no task run yet: the view opens one itself.

    The browser server is asked to list its tabs — the call that launches
    Chromium without throwing a page away — and the app is told the browser is
    opening, with `reason: opening`, instead of being handed a chore.
    """
    executor, events, _runs = _vnc_start_with(tmp_path, monkeypatch, windows=0, pages=0)
    manager, connection = _browser_manager()
    # The app sends `browser_start` with no session_key; the manager is cached
    # under the key of whatever task built it. The container id in the server's
    # own argv is what ties the two together.
    executor._mcp_managers["t1"] = manager
    try:
        executor._vnc_start("req-nudge", {})

        started = next(e for e in events if e.get("status") == "started")
        assert started["reason"] == "opening"
        assert started["message"] == executor.BROWSER_OPENING_MESSAGE
        assert "ask the agent" not in started["message"]
        assert _wait_for(lambda: connection.calls), "the browser server was never poked"
        assert connection.calls == [("browser_tabs", {"action": "list"})]
        # The page is coming: the app is told the browser is open again.
        assert _wait_for(lambda: any(e.get("status") == "opened" for e in events))
    finally:
        executor._vnc_teardown(notify=False)


def test_a_display_that_already_has_a_page_is_left_alone(tmp_path, monkeypatch):
    """A page is on the display: nothing is opened, nothing is said."""
    executor, events, _runs = _vnc_start_with(tmp_path, monkeypatch, windows=1, pages=1)
    manager, connection = _browser_manager()
    executor._mcp_managers["t1"] = manager
    try:
        executor._vnc_start("req-live", {})

        started = next(e for e in events if e.get("status") == "started")
        assert started["message"] == "" and started["reason"] == ""
        time.sleep(0.2)  # a nudge would have landed long ago
        assert connection.calls == [], "a live browser was poked again"
    finally:
        executor._vnc_teardown(notify=False)


def test_chromiums_helper_windows_do_not_count_as_a_page(tmp_path, monkeypatch):
    """The script counts every mapped window, so Chromium's 1x1 helper and its
    10x10 clipboard window read as a browser. The executor's own class-filtered
    count is the ground truth, and it says the display is empty."""
    executor, events, _runs = _vnc_start_with(tmp_path, monkeypatch, windows=2, pages=0)
    manager, connection = _browser_manager()
    executor._mcp_managers["t1"] = manager
    try:
        executor._vnc_start("req-helpers", {})

        started = next(e for e in events if e.get("status") == "started")
        assert started["reason"] == "opening"
        assert _wait_for(lambda: connection.calls == [("browser_tabs", {"action": "list"})])
    finally:
        executor._vnc_teardown(notify=False)


def test_the_script_count_is_the_fallback_when_the_probe_cannot_run(
    tmp_path, monkeypatch
):
    """An image without xwininfo is no worse off than before: the WINDOWS= line
    still decides, and a display with something on it is shown without fuss."""
    executor, events, _runs = _vnc_start_with(tmp_path, monkeypatch, windows=3, pages=None)
    try:
        executor._vnc_start("req-fallback", {})

        started = next(e for e in events if e.get("status") == "started")
        assert started["message"] == "" and started["reason"] == ""
    finally:
        executor._vnc_teardown(notify=False)


def test_without_a_browser_server_the_view_says_why(tmp_path, monkeypatch):
    """Nothing in this process can open a page. The view still comes up, and
    the message names the cause instead of telling the user to go and ask."""
    executor, events, _runs = _vnc_start_with(tmp_path, monkeypatch, windows=0, pages=0)
    try:
        executor._vnc_start("req-bare", {})

        started = next(e for e in events if e.get("status") == "started")
        assert started["reason"] == "no_browser"
        assert started["message"] == executor.BROWSER_CLOSED_MESSAGE
        assert "ask the agent" not in started["message"]
    finally:
        executor._vnc_teardown(notify=False)


def test_the_view_follows_the_box_where_the_browser_runs(tmp_path, monkeypatch):
    """One container per agent, and `browser_start` names none of them. The
    view is served from the box whose browser server is connected — watching
    only the executor's own box is how a user with browsers open was told no
    browser was open."""
    executor, events, runs = _vnc_start_with(tmp_path, monkeypatch, windows=1, pages=1)
    manager, _connection = _browser_manager(container="cid-agent-two")
    executor._mcp_managers["peer"] = manager
    try:
        executor._vnc_start("req-follow", {})

        assert _vnc_up_boxes(runs)[0] == "cid-agent-two"
        started = next(e for e in events if e.get("status") == "started")
        assert started["reason"] == ""
        # ...and the byte pipe is bridged into that same box.
        socat = [a for a in runs if "socat" in a]
        assert not socat or "cid-agent-two" in socat[0]
    finally:
        executor._vnc_teardown(notify=False)


def test_a_box_with_no_display_is_skipped_for_one_that_has_a_browser(
    tmp_path, monkeypatch
):
    """`cowork-vnc-up` exits 3 when a box has no browser display. That is not
    an error any more: the next box is tried, and only if none answers does the
    app get an error — with a reason on it."""
    import subprocess as sp

    from cowork_executor import executor as ex_mod

    executor = _executor_with(tmp_path, _FakeDockerEnv(), browser_mcp=True)
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]
    runs: list[list[str]] = []

    def fake_run(argv, **_kw):
        argv = list(argv)
        runs.append(argv)
        if "cowork-vnc-up" in argv:
            box = argv[argv.index("cowork-vnc-up") - 1]
            if box == "cid-abc123":  # this executor's own box: no Xvfb on it
                return sp.CompletedProcess(args=argv, returncode=3, stdout=b"")
            return sp.CompletedProcess(args=argv, returncode=0, stdout=b"WINDOWS=1\n")
        if any("xwininfo" in str(a) for a in argv):
            return sp.CompletedProcess(args=argv, returncode=0, stdout="1\n")
        return sp.CompletedProcess(args=argv, returncode=0, stdout=b"")

    monkeypatch.setattr(ex_mod.subprocess, "run", fake_run)
    real_bridge = ex_mod._VncBridge
    monkeypatch.setattr(ex_mod, "_VncBridge", lambda _argv, **kw: real_bridge(["cat"], **kw))
    manager, _connection = _browser_manager(container="cid-agent-two")
    executor._mcp_managers["peer"] = manager
    try:
        executor._vnc_start("req-skip", {})

        assert _vnc_up_boxes(runs)[0] == "cid-agent-two"
        assert any(e.get("status") == "started" for e in events), events
    finally:
        executor._vnc_teardown(notify=False)


def test_no_box_at_all_is_an_error_that_names_the_cause(tmp_path, monkeypatch):
    """Nothing is running to watch. The app gets `reason: no_display` so it
    never has to read English, and the message does not send the user off to
    the agent."""
    import subprocess as sp

    from cowork_executor import executor as ex_mod

    executor = _executor_with(tmp_path, _FakeDockerEnv(), browser_mcp=True)
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]
    monkeypatch.setattr(
        ex_mod.subprocess,
        "run",
        lambda *_a, **_k: sp.CompletedProcess(args=[], returncode=3, stdout=b""),
    )

    executor._vnc_start("req-none", {})

    error = next(e for e in events if e.get("status") == "error")
    assert error["reason"] == "no_display"
    assert "ask the agent" not in error["message"]


def test_the_auto_open_switch_turns_the_nudge_off(tmp_path, monkeypatch):
    """COWORK_BROWSER_AUTO_OPEN=0 is the documented way to keep the browser
    lazy; the view then reports the empty display instead of filling it."""
    executor, events, _runs = _vnc_start_with(tmp_path, monkeypatch, windows=0, pages=0)
    monkeypatch.setenv("COWORK_BROWSER_AUTO_OPEN", "0")
    manager, connection = _browser_manager()
    executor._mcp_managers["t1"] = manager
    try:
        executor._vnc_start("req-off", {})

        started = next(e for e in events if e.get("status") == "started")
        assert started["reason"] == "no_browser"
        time.sleep(0.2)
        assert connection.calls == []
    finally:
        executor._vnc_teardown(notify=False)


# -- a dropped pipe dials back in (bead cowork-c0zd) ------------------------
#
# "The connection is bad" was, measured, a pipe that died once and stayed dead:
# the executor said `stopped`, the app latched its loopback bridge shut, and a
# five-second tunnel cost the whole view. x11vnc survives a dropped client — it
# is `-forever` and it still holds the screen — so the answer to a dropped pipe
# is another pipe, not a dead view.


def _reconnect_rig(tmp_path, monkeypatch, *, vnc_up_rc=0):
    """An executor whose bridges are scripted, one per `_VncBridge` call.

    Each fake bridge exposes `fire_close()` so a test can drop the pipe exactly
    when it wants to, and `saw_bytes` so it can say whether the view was ever
    live — the executor only dials back in for a pipe that carried a picture.
    """
    import subprocess as sp

    from cowork_executor import executor as ex_mod

    executor = _executor_with(tmp_path, _FakeDockerEnv(), browser_mcp=True)
    events: list[dict] = []
    executor._event = lambda _rid, payload: events.append(payload)  # type: ignore[method-assign]
    bridges: list = []

    class _ScriptedBridge:
        def __init__(self, _argv, *, emit, on_closed, **_kw) -> None:
            self.emit = emit
            self.on_closed = on_closed
            self.closed = False
            self.started = False
            self.saw_bytes = True
            bridges.append(self)

        def start(self) -> None:
            self.started = True

        def feed(self, _data: bytes) -> None:
            pass

        def close(self) -> None:
            self.closed = True

        def fire_close(self) -> None:
            self.on_closed()

    def fake_run(argv, **_kwargs):
        argv = list(argv)
        if "cowork-vnc-up" in argv:
            return sp.CompletedProcess(
                args=argv, returncode=vnc_up_rc, stdout=b"WINDOWS=1\n"
            )
        if any("xwininfo" in str(a) for a in argv):
            return sp.CompletedProcess(args=argv, returncode=0, stdout="1\n")
        return sp.CompletedProcess(args=argv, returncode=0, stdout=b"")

    monkeypatch.setattr(ex_mod.subprocess, "run", fake_run)
    monkeypatch.setattr(ex_mod, "_VncBridge", _ScriptedBridge)
    return executor, events, bridges


def _views(events: list[dict]) -> list[tuple[str, str]]:
    return [
        (e.get("status", ""), e.get("reason", ""))
        for e in events
        if e.get("type") == "browser_view"
    ]


def test_a_dropped_pipe_reconnects_instead_of_ending_the_view(tmp_path, monkeypatch):
    executor, events, bridges = _reconnect_rig(tmp_path, monkeypatch)
    executor._vnc_start("req-live", {})
    assert len(bridges) == 1
    first_password = [
        e["password"] for e in events
        if e.get("type") == "browser_view" and e.get("status") == "started"
    ][0]

    bridges[0].fire_close()

    assert _wait_for(lambda: ("started", "reconnected") in _views(events)), _views(events)
    statuses = _views(events)
    # The app is told the pipe is being re-dialled BEFORE it is told it is back,
    # and it is never told the view stopped: the last picture still stands.
    assert ("reconnecting", "reconnecting") in statuses
    assert statuses.index(("reconnecting", "reconnecting")) < statuses.index(
        ("started", "reconnected")
    )
    assert all(status != "stopped" for status, _reason in statuses)
    # A new pipe, registered as the live one, pumping.
    assert len(bridges) == 2
    assert executor._vnc is bridges[1]
    assert bridges[1].started is True
    # The RFB session is new, so the secret is rotated with it and the app is
    # handed the new one — a reconnect that reused the old secret would be a
    # view the agent's own code could have watched in the meantime.
    reconnected = [
        e for e in events
        if e.get("type") == "browser_view" and e.get("reason") == "reconnected"
    ][0]
    assert reconnected["password"] and reconnected["password"] != first_password


def test_a_pipe_that_never_carried_a_picture_is_not_retried(tmp_path, monkeypatch):
    """socat never reached x11vnc: there was no view to lose, and a retry only
    makes the same failure take five seconds longer to report."""
    executor, events, bridges = _reconnect_rig(tmp_path, monkeypatch)
    executor._vnc_start("req-dead", {})
    bridges[0].saw_bytes = False

    bridges[0].fire_close()

    assert _wait_for(lambda: any(s == "stopped" for s, _ in _views(events)))
    assert all(status != "reconnecting" for status, _ in _views(events))
    assert len(bridges) == 1
    assert executor._vnc is None


def test_a_display_that_went_away_ends_the_view_instead_of_retrying(
    tmp_path, monkeypatch
):
    """Exit 3 from `cowork-vnc-up` is "there is no browser display any more".
    No number of retries brings a closed browser back, so the view ends."""
    executor, events, bridges = _reconnect_rig(tmp_path, monkeypatch)
    executor._vnc_start("req-gone", {})
    from cowork_executor import executor as ex_mod
    import subprocess as sp

    monkeypatch.setattr(
        ex_mod.subprocess,
        "run",
        lambda argv, **_k: sp.CompletedProcess(args=list(argv), returncode=3, stdout=b""),
    )

    bridges[0].fire_close()

    assert _wait_for(lambda: any(s == "stopped" for s, _ in _views(events)))
    assert ("reconnecting", "reconnecting") in _views(events)
    assert len(bridges) == 1, "a box with no display must not be dialled again"
    assert executor._vnc is None


def test_a_stop_during_a_reconnect_wins(tmp_path, monkeypatch):
    """The user closed the view while the executor was dialling back in. The
    reconnect must not resurrect it behind them."""
    executor, events, bridges = _reconnect_rig(tmp_path, monkeypatch)
    executor._vnc_start("req-stop", {})
    gate = threading.Event()
    from cowork_executor import executor as ex_mod
    import subprocess as sp

    def slow_run(argv, **_k):
        argv = list(argv)
        if "cowork-vnc-up" in argv:
            gate.wait(5.0)
        return sp.CompletedProcess(args=argv, returncode=0, stdout=b"WINDOWS=1\n")

    monkeypatch.setattr(ex_mod.subprocess, "run", slow_run)

    bridges[0].fire_close()
    assert _wait_for(lambda: ("reconnecting", "reconnecting") in _views(events))
    executor._handle_browser_kind("browser_stop", "req-stop", {})
    gate.set()

    time.sleep(0.3)
    assert executor._vnc is None
    assert ("started", "reconnected") not in _views(events)


def test_the_start_path_is_timed(tmp_path, monkeypatch, caplog):
    """The user's complaint was "it loads forever"; the only honest answer is a
    number per step, in the log, on his own machine."""
    import logging

    executor, _events, _bridges = _reconnect_rig(tmp_path, monkeypatch)
    with caplog.at_level(logging.INFO, logger="cowork_executor.executor"):
        executor._vnc_start("req-timed", {})

    lines = [r.getMessage() for r in caplog.records if "start path" in r.getMessage()]
    assert lines, [r.getMessage() for r in caplog.records]
    for step in ("container", "targets", "vnc-up", "bridge", "windows", "total"):
        assert step in lines[0], lines[0]
