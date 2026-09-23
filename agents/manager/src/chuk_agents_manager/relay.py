"""Relay bridge — the frame contract (§14).

The relay is a blind proxy of encrypted frames between controller and executor.
This module implements the *frame contract* the Manager speaks over it, as pure
(de)serialization plus a correlation map — no network. The transport is injected
(a ``Transport`` protocol), so the same logic runs over a real WebSocket, a
loopback pipe, or a test double.

Contract (Hermes ``gateway/relay/``, §14):

- **newline-delimited JSON frames**, one JSON object per line,
- **JSON-RPC-shaped** dispatch (``method`` / ``params`` / ``result`` / ``error``),
- correlated by **``requestId``**,
- a **capability-descriptor handshake** (the peer declares what it can render),
- **Bearer-token auth on the WS upgrade** (a header, not a frame).
"""

from __future__ import annotations

import itertools
import json
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

PROTOCOL_VERSION = "1"


# --------------------------------------------------------------------------
# Frame (de)serialization
# --------------------------------------------------------------------------


def encode_frame(frame: dict[str, Any]) -> bytes:
    """Serialize one frame to a newline-terminated JSON line (UTF-8)."""
    return (json.dumps(frame, separators=(",", ":"), ensure_ascii=False) + "\n").encode(
        "utf-8"
    )


def decode_frames(buffer: bytes) -> tuple[list[dict[str, Any]], bytes]:
    """Split a byte buffer into complete frames plus a trailing remainder.

    Newline-delimited framing means a read may end mid-line; the remainder is
    returned so the caller can prepend it to the next read. Blank lines are
    skipped.
    """
    frames: list[dict[str, Any]] = []
    *lines, remainder = buffer.split(b"\n")
    for line in lines:
        if not line.strip():
            continue
        frames.append(json.loads(line.decode("utf-8")))
    return frames, remainder


def make_request(
    method: str, params: dict[str, Any] | None = None, request_id: str = ""
) -> dict[str, Any]:
    """Build a request frame."""
    return {
        "v": PROTOCOL_VERSION,
        "type": "request",
        "requestId": request_id,
        "method": method,
        "params": params or {},
    }


def make_response(request_id: str, result: Any) -> dict[str, Any]:
    """Build a success response frame correlated to ``request_id``."""
    return {
        "v": PROTOCOL_VERSION,
        "type": "response",
        "requestId": request_id,
        "result": result,
    }


def make_error(
    request_id: str, code: int, message: str, data: Any = None
) -> dict[str, Any]:
    """Build an error response frame correlated to ``request_id``."""
    error: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {
        "v": PROTOCOL_VERSION,
        "type": "response",
        "requestId": request_id,
        "error": error,
    }


def build_upgrade_headers(
    token: str, extra: dict[str, str] | None = None
) -> dict[str, str]:
    """Construct the HTTP headers for the WebSocket upgrade.

    Auth is a Bearer token on the upgrade (§14), never a frame — the relay
    authenticates the connection before any frame flows.
    """
    headers = {"Authorization": f"Bearer {token}"}
    if extra:
        headers.update(extra)
    return headers


# --------------------------------------------------------------------------
# Capability handshake
# --------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class CapabilityDescriptor:
    """What a peer declares it can do at handshake time (§14, §16).

    ``renders`` is the controller's render surface (e.g. ``chart``, ``map``,
    ``sandbox_artifact``); ``role`` distinguishes controller from executor;
    ``protocol`` pins the frame-contract version.
    """

    role: str
    name: str
    version: str
    renders: tuple[str, ...] = ()
    protocol: str = PROTOCOL_VERSION

    def to_params(self) -> dict[str, Any]:
        return {
            "role": self.role,
            "name": self.name,
            "version": self.version,
            "renders": list(self.renders),
            "protocol": self.protocol,
        }

    def to_handshake(self, request_id: str) -> dict[str, Any]:
        """The handshake as a ``hello`` request frame."""
        return make_request("hello", self.to_params(), request_id)

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> "CapabilityDescriptor":
        return cls(
            role=params["role"],
            name=params["name"],
            version=params["version"],
            renders=tuple(params.get("renders", ())),
            protocol=params.get("protocol", PROTOCOL_VERSION),
        )


# --------------------------------------------------------------------------
# Correlation map
# --------------------------------------------------------------------------


@dataclass
class Pending:
    """A sent request awaiting its response."""

    request_id: str
    method: str
    params: dict[str, Any]


@dataclass
class Correlation:
    """A matched request/response pair."""

    request: Pending
    response: dict[str, Any]

    @property
    def result(self) -> Any:
        return self.response.get("result")

    @property
    def error(self) -> dict[str, Any] | None:
        return self.response.get("error")

    @property
    def ok(self) -> bool:
        return "error" not in self.response


class CorrelationMap:
    """Tracks in-flight requests by ``requestId`` and resolves responses.

    Pure bookkeeping — no futures, no threads — so it round-trips deterministically
    in tests and composes with any transport.
    """

    def __init__(self) -> None:
        self._pending: dict[str, Pending] = {}

    def register(self, frame: dict[str, Any]) -> None:
        """Record an outgoing request frame as pending."""
        rid = frame["requestId"]
        self._pending[rid] = Pending(
            request_id=rid,
            method=frame.get("method", ""),
            params=frame.get("params", {}),
        )

    def resolve(self, frame: dict[str, Any]) -> Correlation | None:
        """Match a response frame to its pending request; ``None`` if unknown."""
        rid = frame.get("requestId")
        if rid is None:
            return None
        pending = self._pending.pop(rid, None)
        if pending is None:
            return None
        return Correlation(request=pending, response=frame)

    def pending_ids(self) -> list[str]:
        return list(self._pending.keys())

    def __len__(self) -> int:
        return len(self._pending)


# --------------------------------------------------------------------------
# Transport seam + bridge
# --------------------------------------------------------------------------


@runtime_checkable
class Transport(Protocol):
    """The one seam the bridge dials through (§14).

    A real transport wraps the relay WebSocket; the bridge never forks its logic
    per transport. ``send`` writes encoded frame bytes.
    """

    def send(self, data: bytes) -> None: ...


@dataclass
class RelayBridge:
    """Drives the frame contract over an injected transport.

    Sending a request registers it in the correlation map; feeding inbound bytes
    decodes frames and resolves matching responses. ``id_factory`` is injectable
    so request ids are deterministic in tests.
    """

    transport: Transport
    capabilities: CapabilityDescriptor
    id_factory: Callable[[], str] | None = None
    corr: CorrelationMap = field(default_factory=CorrelationMap)
    _counter: itertools.count = field(
        default_factory=lambda: itertools.count(1), init=False, repr=False
    )
    _rx: bytes = field(default=b"", init=False, repr=False)

    def _next_id(self) -> str:
        if self.id_factory is not None:
            return self.id_factory()
        return f"req-{next(self._counter)}"

    def handshake(self) -> str:
        """Send the capability handshake; return its ``requestId``."""
        rid = self._next_id()
        frame = self.capabilities.to_handshake(rid)
        self.corr.register(frame)
        self.transport.send(encode_frame(frame))
        return rid

    def call(self, method: str, params: dict[str, Any] | None = None) -> str:
        """Send a request; return its ``requestId`` for later correlation."""
        rid = self._next_id()
        frame = make_request(method, params, rid)
        self.corr.register(frame)
        self.transport.send(encode_frame(frame))
        return rid

    def respond(self, request_id: str, result: Any) -> None:
        """Send a success response for an inbound request."""
        self.transport.send(encode_frame(make_response(request_id, result)))

    def feed(self, data: bytes) -> list[tuple[str, Any]]:
        """Ingest inbound bytes; return a list of ``(kind, payload)`` events.

        ``kind`` is one of:

        - ``"response"`` -> payload is a :class:`Correlation` (matched request),
        - ``"orphan"``   -> payload is a response frame with no known request,
        - ``"request"``  -> payload is an inbound request frame to dispatch.
        """
        self._rx += data
        frames, self._rx = decode_frames(self._rx)
        events: list[tuple[str, Any]] = []
        for frame in frames:
            if frame.get("type") == "response":
                match = self.corr.resolve(frame)
                if match is not None:
                    events.append(("response", match))
                else:
                    events.append(("orphan", frame))
            else:
                events.append(("request", frame))
        return events
