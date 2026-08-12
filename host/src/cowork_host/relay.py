"""The blind localhost relay.

A ``websockets`` server on ``127.0.0.1:<port>`` that just routes JSON messages
verbatim between two parties on the same channel. It is **blind**: it inspects
only the first ``join`` message (to learn the channel + role) and never reads the
content of anything it forwards afterward. This is the local stand-in for the
production relay, and the Dart app talks to it identically.

Ordering is handled with a tiny per-channel buffer: the pairing *initiator*
publishes its ``commit`` before the *joiner* has connected (that is the whole
point of a pairing code — it is shown, then typed later). Messages for a peer
that has not joined yet are held and flushed the instant it does. The relay still
never looks inside them.
"""

from __future__ import annotations

import json
import threading
from typing import Any, Callable

from websockets.exceptions import ConnectionClosed
from websockets.sync.server import ServerConnection, serve

from .protocol import ROLE_CONTROLLER, ROLE_EXECUTOR, ROLES, TYPE_JOIN


def _peer_role(role: str) -> str:
    return ROLE_CONTROLLER if role == ROLE_EXECUTOR else ROLE_EXECUTOR


class LocalRelay:
    """A blind two-party-per-channel message relay over localhost WebSocket."""

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 8787,
        *,
        logger: Callable[[str], None] | None = None,
    ) -> None:
        self._host = host
        self._port = port
        self._log = logger or (lambda _msg: None)
        self._server = None
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        # channel_id -> {role -> connection}
        self._channels: dict[str, dict[str, ServerConnection]] = {}
        # channel_id -> {target_role -> [raw messages held until it joins]}
        self._buffers: dict[str, dict[str, list[Any]]] = {}

    # -- lifecycle -------------------------------------------------------

    def start(self) -> None:
        """Bind the socket and serve in a background daemon thread."""
        self._server = serve(self._handle, self._host, self._port)
        self._thread = threading.Thread(
            target=self._server.serve_forever, name="cowork-relay", daemon=True
        )
        self._thread.start()

    @property
    def port(self) -> int:
        """The bound TCP port (resolves an ephemeral ``port=0`` after start)."""
        if self._server is not None:
            return self._server.socket.getsockname()[1]
        return self._port

    def stop(self) -> None:
        """Shut the relay down and drop all channels."""
        if self._server is not None:
            self._server.shutdown()
            self._server = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        with self._lock:
            self._channels.clear()
            self._buffers.clear()

    # -- connection handler ----------------------------------------------

    def _handle(self, ws: ServerConnection) -> None:
        """One connection: read its join, then forward everything, blind."""
        try:
            raw_join = ws.recv()
        except (ConnectionClosed, TimeoutError):
            return
        join = _parse_join(raw_join)
        if join is None:
            self._log("relay: dropped a connection with no valid join")
            return
        channel, role = join
        self._register(channel, role, ws)
        self._log(f"relay: {role} joined channel {channel}")
        try:
            for message in ws:  # blocks; yields each inbound message
                self._forward(channel, role, message)
        except ConnectionClosed:
            pass
        finally:
            self._unregister(channel, role, ws)
            self._log(f"relay: {role} left channel {channel}")

    def _register(self, channel: str, role: str, ws: ServerConnection) -> None:
        with self._lock:
            self._channels.setdefault(channel, {})[role] = ws
            buffered = self._buffers.get(channel, {}).pop(role, [])
        # Flush outside the lock: sending can block.
        for message in buffered:
            _safe_send(ws, message)

    def _unregister(self, channel: str, role: str, ws: ServerConnection) -> None:
        with self._lock:
            peers = self._channels.get(channel)
            if peers is not None and peers.get(role) is ws:
                del peers[role]
                if not peers:
                    del self._channels[channel]

    def _forward(self, channel: str, role: str, message: Any) -> None:
        """Hand ``message`` to the peer verbatim, or buffer it until the peer joins."""
        peer_role = _peer_role(role)
        with self._lock:
            peer = self._channels.get(channel, {}).get(peer_role)
            if peer is None:
                self._buffers.setdefault(channel, {}).setdefault(
                    peer_role, []
                ).append(message)
                return
        _safe_send(peer, message)


def _parse_join(raw: Any) -> tuple[str, str] | None:
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict) or data.get("type") != TYPE_JOIN:
        return None
    channel = data.get("channel")
    role = data.get("role")
    if not isinstance(channel, str) or not channel or role not in ROLES:
        return None
    return channel, role


def _safe_send(ws: ServerConnection, message: Any) -> None:
    try:
        ws.send(message)
    except (ConnectionClosed, RuntimeError):
        pass
