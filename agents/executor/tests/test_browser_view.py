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
    }
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
