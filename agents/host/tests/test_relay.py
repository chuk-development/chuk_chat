"""The blind relay: it pairs two roles on a channel and forwards verbatim,
including messages published before the peer has joined."""

from __future__ import annotations

import json
import threading
import time

import pytest
from websockets.sync.client import connect

from cowork_host import LocalRelay
from cowork_host.protocol import frame_envelope, join_message


@pytest.fixture()
def relay():
    r = LocalRelay("127.0.0.1", 0)
    r.start()
    try:
        yield r
    finally:
        r.stop()


def _url(relay: LocalRelay) -> str:
    return f"ws://127.0.0.1:{relay.port}"


def test_forwards_both_directions(relay):
    with connect(_url(relay)) as exec_ws, connect(_url(relay)) as ctrl_ws:
        exec_ws.send(json.dumps(join_message("chan-1", "executor")))
        ctrl_ws.send(json.dumps(join_message("chan-1", "controller")))

        exec_ws.send(json.dumps(frame_envelope("from-executor")))
        got = json.loads(ctrl_ws.recv(timeout=3))
        assert got == {"type": "frame", "frame": "from-executor"}

        ctrl_ws.send(json.dumps(frame_envelope("from-controller")))
        back = json.loads(exec_ws.recv(timeout=3))
        assert back == {"type": "frame", "frame": "from-controller"}


def test_buffers_until_peer_joins(relay):
    """The initiator publishes before the joiner connects; the relay holds it and
    flushes on join — exactly what pairing needs (commit shown, then code typed)."""
    with connect(_url(relay)) as exec_ws:
        exec_ws.send(json.dumps(join_message("chan-2", "executor")))
        # No controller yet: this must be buffered, not dropped.
        exec_ws.send(json.dumps(frame_envelope("early-commit")))

        with connect(_url(relay)) as ctrl_ws:
            ctrl_ws.send(json.dumps(join_message("chan-2", "controller")))
            got = json.loads(ctrl_ws.recv(timeout=3))
            assert got["frame"] == "early-commit"


def test_channels_are_isolated(relay):
    with connect(_url(relay)) as a_exec, connect(_url(relay)) as a_ctrl, connect(
        _url(relay)
    ) as b_ctrl:
        a_exec.send(json.dumps(join_message("A", "executor")))
        a_ctrl.send(json.dumps(join_message("A", "controller")))
        b_ctrl.send(json.dumps(join_message("B", "controller")))

        a_exec.send(json.dumps(frame_envelope("only-for-A")))
        got = json.loads(a_ctrl.recv(timeout=3))
        assert got["frame"] == "only-for-A"

        # The B controller must not receive anything meant for channel A.
        with pytest.raises(TimeoutError):
            b_ctrl.recv(timeout=1)


# -- peer lifecycle events (join/leave + per-connection token) ---------------


def _wait_for(predicate, timeout: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return False


class _EventLog:
    """Thread-safe record of the relay's peer-lifecycle callbacks."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.events: list[tuple[str, str, str, int]] = []

    def __call__(self, channel: str, role: str, event: str, token: int) -> None:
        with self._lock:
            self.events.append((channel, role, event, token))

    def snapshot(self) -> list[tuple[str, str, str, int]]:
        with self._lock:
            return list(self.events)


def test_emits_join_and_leave_with_a_stable_token():
    log = _EventLog()
    r = LocalRelay("127.0.0.1", 0, on_peer_event=log)
    r.start()
    url = _url(r)
    try:
        with connect(url) as ctrl_ws:
            ctrl_ws.send(json.dumps(join_message("chan-ev", "controller")))
            assert _wait_for(lambda: len(log.snapshot()) >= 1)
            joins = [e for e in log.snapshot() if e[2] == "join"]
            assert joins == [("chan-ev", "controller", "join", joins[0][3])]
            token = joins[0][3]
            # The live token is queryable while the connection is up.
            assert r.current_peer_token("chan-ev", "controller") == token
        # Closing the socket fires exactly one matching leave with the same token.
        assert _wait_for(
            lambda: ("chan-ev", "controller", "leave", token) in log.snapshot()
        )
        assert r.current_peer_token("chan-ev", "controller") is None
    finally:
        r.stop()


def test_reconnect_gets_a_fresh_token_and_no_stale_leave():
    """Two sequential controller connections get distinct tokens, and the first
    connection's leave never masquerades as the second's."""
    log = _EventLog()
    r = LocalRelay("127.0.0.1", 0, on_peer_event=log)
    r.start()
    url = _url(r)
    try:
        with connect(url) as first:
            first.send(json.dumps(join_message("chan-rc", "controller")))
            assert _wait_for(lambda: any(e[2] == "join" for e in log.snapshot()))
        assert _wait_for(lambda: any(e[2] == "leave" for e in log.snapshot()))

        with connect(url) as second:
            second.send(json.dumps(join_message("chan-rc", "controller")))
            assert _wait_for(
                lambda: len([e for e in log.snapshot() if e[2] == "join"]) >= 2
            )
            joins = [e for e in log.snapshot() if e[2] == "join"]
            assert joins[0][3] != joins[1][3], "reconnect reused the old token"
    finally:
        r.stop()


def test_buffer_is_cleared_when_the_target_leaves(relay):
    """A message buffered for a peer that then disconnects must not leak to the
    next connection that takes the same role."""
    with connect(_url(relay)) as exec_ws:
        exec_ws.send(json.dumps(join_message("chan-buf", "executor")))
        # Buffered for a controller that never arrives.
        exec_ws.send(json.dumps(frame_envelope("stale")))

        # A controller connects and leaves without reading — the stale frame is
        # flushed to it, then its buffer entry is gone.
        with connect(_url(relay)) as ctrl_a:
            ctrl_a.send(json.dumps(join_message("chan-buf", "controller")))
            got = json.loads(ctrl_a.recv(timeout=3))
            assert got["frame"] == "stale"

        # A second controller joins later and must receive nothing stale.
        with connect(_url(relay)) as ctrl_b:
            ctrl_b.send(json.dumps(join_message("chan-buf", "controller")))
            with pytest.raises(TimeoutError):
                ctrl_b.recv(timeout=1)
