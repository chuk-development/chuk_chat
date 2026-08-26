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

import itertools
import json
import threading
from typing import Any, Callable

from websockets.exceptions import ConnectionClosed
from websockets.sync.server import ServerConnection, serve

from .protocol import ROLE_CONTROLLER, ROLE_EXECUTOR, ROLES, TYPE_JOIN

# A peer lifecycle callback: ``(channel, role, event, token)`` where ``event`` is
# ``"join"`` or ``"leave"`` and ``token`` is a per-connection identity. The token
# lets a listener tell one controller connection from the next so a reconnect —
# even one whose ``leave`` and the next ``join`` race across threads — is never
# confused for the same session.
PeerEvent = Callable[[str, str, str, int], None]

EVENT_JOIN = "join"
EVENT_LEAVE = "leave"


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
        on_peer_event: PeerEvent | None = None,
    ) -> None:
        self._host = host
        self._port = port
        self._log = logger or (lambda _msg: None)
        self._on_peer_event = on_peer_event
        self._server = None
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._conn_ids = itertools.count(1)
        # channel_id -> {role -> connection}
        self._channels: dict[str, dict[str, ServerConnection]] = {}
        # channel_id -> {role -> per-connection token}
        self._tokens: dict[str, dict[str, int]] = {}
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
            self._tokens.clear()
            self._buffers.clear()

    def current_peer_token(self, channel: str, role: str) -> int | None:
        """The token of the connection currently holding ``role`` on ``channel``,
        or ``None`` if nobody holds it. Lets a late joiner (e.g. the host's own
        executor connection coming up) discover a peer that is already present."""
        with self._lock:
            return self._tokens.get(channel, {}).get(role)

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
        token = self._register(channel, role, ws)
        self._log(f"relay: {role} joined channel {channel}")
        self._emit(channel, role, EVENT_JOIN, token)
        try:
            for message in ws:  # blocks; yields each inbound message
                self._forward(channel, role, message)
        except ConnectionClosed:
            pass
        finally:
            if self._unregister(channel, role, ws):
                self._log(f"relay: {role} left channel {channel}")
                self._emit(channel, role, EVENT_LEAVE, token)

    def _register(self, channel: str, role: str, ws: ServerConnection) -> int:
        with self._lock:
            token = next(self._conn_ids)
            self._channels.setdefault(channel, {})[role] = ws
            self._tokens.setdefault(channel, {})[role] = token
            buffered = self._buffers.get(channel, {}).pop(role, [])
        # Flush outside the lock: sending can block.
        for message in buffered:
            _safe_send(ws, message)
        return token

    def _unregister(self, channel: str, role: str, ws: ServerConnection) -> bool:
        """Drop this connection if it still owns ``role``. Returns ``True`` when it
        did — i.e. this exact connection left and was not already superseded by a
        reconnect. A superseded connection returns ``False`` and stays silent, so a
        reconnect's ``leave`` never cancels the live session that replaced it."""
        with self._lock:
            peers = self._channels.get(channel)
            if peers is None or peers.get(role) is not ws:
                return False
            del peers[role]
            if not peers:
                del self._channels[channel]
            tokens = self._tokens.get(channel)
            if tokens is not None:
                tokens.pop(role, None)
                if not tokens:
                    del self._tokens[channel]
            # Drop anything still buffered for the departed role: it belongs to a
            # session that is over and must not leak into the next connection.
            role_buffers = self._buffers.get(channel)
            if role_buffers is not None:
                role_buffers.pop(role, None)
                if not role_buffers:
                    del self._buffers[channel]
            return True

    def _emit(self, channel: str, role: str, event: str, token: int) -> None:
        """Fire the peer-lifecycle callback, outside every lock. A listener
        failure must never take the relay down."""
        if self._on_peer_event is None:
            return
        try:
            self._on_peer_event(channel, role, event, token)
        except Exception as exc:  # noqa: BLE001 - a listener must not kill the relay
            self._log(f"relay: peer-event listener failed: {type(exc).__name__}: {exc}")

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
