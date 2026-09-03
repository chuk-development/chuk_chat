"""The live browser view (§9.1) — x11vnc streamed over the sealed channel.

The executor pipes the sandbox Chromium's VNC bytes to the app and feeds the
app's input back, as `browser_data` frames, driven by `browser_start` /
`browser_stop`. These tests pin the payloads, the opaque byte pump, the sealed
dispatch wiring, and the safe behaviour when there is no docker sandbox or no
view — all without a real container.
"""

from __future__ import annotations

import threading

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
