"""Frame ser/deser + requestId correlation round-trip + handshake + auth header."""

from __future__ import annotations

from cowork_manager.relay import (
    CapabilityDescriptor,
    CorrelationMap,
    RelayBridge,
    build_upgrade_headers,
    decode_frames,
    encode_frame,
    make_error,
    make_request,
    make_response,
)


class FakeTransport:
    """Captures sent bytes so a test can inspect and reply."""

    def __init__(self) -> None:
        self.sent: list[bytes] = []

    def send(self, data: bytes) -> None:
        self.sent.append(data)


# -- framing ----------------------------------------------------------------


def test_encode_is_newline_delimited() -> None:
    data = encode_frame({"a": 1})
    assert data.endswith(b"\n")
    assert b"\n" not in data[:-1]


def test_decode_roundtrip_and_remainder() -> None:
    f1 = encode_frame(make_request("hello", {"x": 1}, "r1"))
    f2 = encode_frame(make_response("r1", {"ok": True}))
    # Concatenate two frames plus a partial third with no trailing newline.
    buffer = f1 + f2 + b'{"partial":'
    frames, remainder = decode_frames(buffer)
    assert len(frames) == 2
    assert frames[0]["method"] == "hello"
    assert frames[1]["result"] == {"ok": True}
    assert remainder == b'{"partial":'


def test_decode_skips_blank_lines() -> None:
    buffer = b"\n\n" + encode_frame({"type": "request", "requestId": "z"})
    frames, remainder = decode_frames(buffer)
    assert len(frames) == 1
    assert remainder == b""


def test_make_error_shape() -> None:
    frame = make_error("r9", 42, "boom", data={"k": "v"})
    assert frame["type"] == "response"
    assert frame["requestId"] == "r9"
    assert frame["error"] == {"code": 42, "message": "boom", "data": {"k": "v"}}


# -- auth header ------------------------------------------------------------


def test_build_upgrade_headers() -> None:
    headers = build_upgrade_headers("tok123", extra={"X-Device": "abc"})
    assert headers["Authorization"] == "Bearer tok123"
    assert headers["X-Device"] == "abc"


# -- capability handshake ---------------------------------------------------


def test_capability_descriptor_roundtrip() -> None:
    cap = CapabilityDescriptor(
        role="controller",
        name="chuk-cowork",
        version="0.1.0",
        renders=("chart", "map", "sandbox_artifact"),
    )
    frame = cap.to_handshake("h1")
    assert frame["method"] == "hello"
    assert frame["requestId"] == "h1"
    restored = CapabilityDescriptor.from_params(frame["params"])
    assert restored == cap


# -- correlation map --------------------------------------------------------


def test_correlation_map_matches_by_request_id() -> None:
    corr = CorrelationMap()
    req = make_request("do_work", {"n": 1}, "abc")
    corr.register(req)
    assert corr.pending_ids() == ["abc"]

    resp = make_response("abc", {"done": True})
    match = corr.resolve(resp)
    assert match is not None
    assert match.request.method == "do_work"
    assert match.result == {"done": True}
    assert match.ok is True
    assert len(corr) == 0  # consumed


def test_correlation_unknown_id_returns_none() -> None:
    corr = CorrelationMap()
    assert corr.resolve(make_response("ghost", 1)) is None


# -- bridge round-trip ------------------------------------------------------


def _bridge() -> tuple[RelayBridge, FakeTransport]:
    transport = FakeTransport()
    cap = CapabilityDescriptor(role="executor", name="mgr", version="0.1.0")
    ids = iter(["req-1", "req-2", "req-3"])
    bridge = RelayBridge(
        transport=transport, capabilities=cap, id_factory=lambda: next(ids)
    )
    return bridge, transport


def test_bridge_call_registers_and_feed_resolves() -> None:
    bridge, transport = _bridge()

    rid = bridge.call("run_task", {"prompt": "go"})
    assert rid == "req-1"
    # The request left over the transport, correctly framed.
    frames, _ = decode_frames(transport.sent[0])
    assert frames[0]["requestId"] == "req-1"
    assert frames[0]["method"] == "run_task"
    assert len(bridge.corr) == 1

    # The peer replies with the same requestId; feed resolves the correlation.
    reply = encode_frame(make_response("req-1", {"status": "ok"}))
    events = bridge.feed(reply)
    assert len(events) == 1
    kind, payload = events[0]
    assert kind == "response"
    assert payload.request.method == "run_task"
    assert payload.request.params == {"prompt": "go"}
    assert payload.result == {"status": "ok"}
    assert len(bridge.corr) == 0


def test_bridge_handles_partial_and_multiple_frames() -> None:
    bridge, transport = _bridge()
    bridge.call("a")
    bridge.call("b")

    r1 = encode_frame(make_response("req-1", 1))
    r2 = encode_frame(make_response("req-2", 2))
    # Split the byte stream mid-frame to exercise remainder buffering.
    stream = r1 + r2
    events = bridge.feed(stream[:10])
    events += bridge.feed(stream[10:])

    responses = [p for k, p in events if k == "response"]
    assert {r.request.method for r in responses} == {"a", "b"}


def test_bridge_inbound_request_and_orphan() -> None:
    bridge, transport = _bridge()

    inbound = encode_frame(make_request("ping", {}, "peer-1"))
    orphan = encode_frame(make_response("never-sent", 0))
    events = bridge.feed(inbound + orphan)

    kinds = [k for k, _ in events]
    assert kinds == ["request", "orphan"]

    # Bridge can respond to the inbound request.
    bridge.respond("peer-1", {"pong": True})
    frames, _ = decode_frames(transport.sent[-1])
    assert frames[0]["requestId"] == "peer-1"
    assert frames[0]["result"] == {"pong": True}


def test_bridge_handshake_is_registered() -> None:
    bridge, transport = _bridge()
    rid = bridge.handshake()
    assert rid == "req-1"
    frames, _ = decode_frames(transport.sent[0])
    assert frames[0]["method"] == "hello"
    assert frames[0]["params"]["role"] == "executor"
    # Handshake correlates like any other request.
    ack = encode_frame(make_response(rid, {"accepted": True}))
    events = bridge.feed(ack)
    assert events[0][0] == "response"
    assert events[0][1].result == {"accepted": True}
