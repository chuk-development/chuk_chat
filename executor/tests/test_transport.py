"""Task 3: the loopback transport carries relay frames both ways."""

from __future__ import annotations

from cowork_manager import Transport, decode_frames, encode_frame, make_request

from cowork_executor import LoopbackEndpoint, loopback_pair


def test_endpoints_are_transports():
    controller, executor = loopback_pair()
    assert isinstance(controller, Transport)
    assert isinstance(executor, Transport)


def test_bytes_flow_both_directions():
    controller, executor = loopback_pair()

    controller.send(encode_frame(make_request("ping", {"n": 1}, "r1")))
    got = executor.recv(timeout=1.0)
    frames, remainder = decode_frames(got)
    assert remainder == b""
    assert frames[0]["method"] == "ping"
    assert frames[0]["requestId"] == "r1"

    executor.send(encode_frame(make_request("pong", {}, "r2")))
    back, _ = decode_frames(controller.recv(timeout=1.0))
    assert back[0]["method"] == "pong"


def test_recv_times_out_to_none():
    controller, _ = loopback_pair()
    assert controller.recv(timeout=0.05) is None


def test_isinstance_endpoint():
    controller, _ = loopback_pair()
    assert isinstance(controller, LoopbackEndpoint)
