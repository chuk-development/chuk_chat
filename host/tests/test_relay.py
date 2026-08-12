"""The blind relay: it pairs two roles on a channel and forwards verbatim,
including messages published before the peer has joined."""

from __future__ import annotations

import json

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
