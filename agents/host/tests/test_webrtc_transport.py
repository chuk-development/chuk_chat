"""The WebRTC DataChannel transport (§14.1) — a real peer-to-peer pipe.

Two `WebRTCEndpoint`s negotiate over an in-memory signaling pair and exchange
bytes over an actual aiortc DataChannel (host candidates on loopback, no STUN/
TURN). These pin the pipe surface the host relies on — `send` / `recv(timeout)`
both ways — and the length-prefix chunking that carries a message far larger
than a single DataChannel frame.
"""

from __future__ import annotations

import queue
import threading

import pytest

from chuk_agents_host.webrtc_transport import (
    WebRTCEndpoint,
    WebRTCError,
    _Reassembler,
    ice_configuration,
)


# -- framing unit ----------------------------------------------------------


def test_reassembler_rebuilds_messages_across_chunk_boundaries():
    import struct

    a = b"first message"
    b = b"second, longer message body"
    stream = struct.pack(">I", len(a)) + a + struct.pack(">I", len(b)) + b

    r = _Reassembler()
    out: list[bytes] = []
    # Feed one byte at a time — the worst case for boundary handling.
    for i in range(len(stream)):
        out.extend(r.feed(stream[i : i + 1]))
    assert out == [a, b]


def test_reassembler_rejects_an_absurd_length():
    import struct

    r = _Reassembler()
    with pytest.raises(WebRTCError):
        r.feed(struct.pack(">I", 999_999_999))


def test_ice_configuration_maps_stun_and_turn():
    cfg = ice_configuration(
        [
            {"urls": "stun:stun.l.google.com:19302"},
            {"urls": ["turn:t:3478"], "username": "u", "credential": "p"},
        ]
    )
    assert len(cfg.iceServers) == 2
    assert cfg.iceServers[1].username == "u"


# -- a real DataChannel ----------------------------------------------------


def _crossed_signaling():
    """Two thread-safe signaling channels wired to each other."""
    a_to_b: queue.Queue = queue.Queue()
    b_to_a: queue.Queue = queue.Queue()

    def a_send(msg):
        a_to_b.put(msg)

    def a_recv(timeout):
        try:
            return b_to_a.get(timeout=timeout)
        except queue.Empty:
            return None

    def b_send(msg):
        b_to_a.put(msg)

    def b_recv(timeout):
        try:
            return a_to_b.get(timeout=timeout)
        except queue.Empty:
            return None

    return (a_send, a_recv), (b_send, b_recv)


def _connected_pair():
    (a_send, a_recv), (b_send, b_recv) = _crossed_signaling()
    offer = WebRTCEndpoint(role="offer", signal_send=a_send, signal_recv=a_recv)
    answer = WebRTCEndpoint(role="answer", signal_send=b_send, signal_recv=b_recv)

    errors: list[BaseException] = []

    def connect(ep):
        try:
            ep.connect(timeout=30.0)
        except BaseException as exc:  # noqa: BLE001 — surface to the test
            errors.append(exc)

    threads = [threading.Thread(target=connect, args=(ep,)) for ep in (offer, answer)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(35.0)
    if errors:
        offer.close()
        answer.close()
        raise errors[0]
    return offer, answer


def test_two_endpoints_exchange_messages_both_ways():
    offer, answer = _connected_pair()
    try:
        offer.send("hello from the offerer")
        assert answer.recv(timeout=10.0) == "hello from the offerer"

        answer.send("hi back from the answerer")
        assert offer.recv(timeout=10.0) == "hi back from the answerer"
    finally:
        offer.close()
        answer.close()


def test_a_large_message_is_chunked_and_reassembled():
    """A 1 MB payload is far past a single DataChannel frame — the transport must
    split and rejoin it losslessly (the `file` event case, §9)."""
    offer, answer = _connected_pair()
    try:
        big = "x" * (1024 * 1024) + "END"
        offer.send(big)
        got = answer.recv(timeout=20.0)
        assert got == big
        assert len(got) == len(big)
    finally:
        offer.close()
        answer.close()
