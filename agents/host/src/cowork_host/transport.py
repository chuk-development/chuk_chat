"""The party's pipe seam — one interface, two pipes.

:class:`~cowork_host.party.HostParty` drives the §15 ceremony and then serves
sealed frames. None of that depends on *how* the JSON messages reach the app, so
the socket is factored out to here:

- :class:`PartyTransport` opens a link and owns whatever hello that pipe needs.
- :class:`PartyLink` carries the *party protocol* messages of
  :mod:`cowork_host.protocol` as plain dicts, in both directions.

Two implementations exist:

- :class:`LocalRelayTransport` — the blind loopback relay (:mod:`cowork_host.relay`).
  Same-machine development only. Its hello is the ``join`` message.
- :class:`~cowork_host.cloud_relay.CloudRelayTransport` — the production pipe
  through ``api.chuk.chat``. Its hello is the relay ``auth`` handshake, and each
  party message rides inside one ``cowork_relay`` frame's opaque ``payload``.

The party never learns which one it is on. That is the whole point: the crypto,
the ceremony and the frame handling are identical on both, so only the pipe is
new (docs/PLAN_2026-09-09_CLOUD_PAIRING_TRANSPORT.md).
"""

from __future__ import annotations

import json
from typing import Any, Callable, Iterator, Protocol

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect as ws_connect

from .protocol import ROLE_EXECUTOR, join_message

# A controller lifecycle callback, ``(event, token)`` with ``event`` one of the
# relay's ``EVENT_JOIN`` / ``EVENT_LEAVE`` and ``token`` a per-connection
# identity. The loopback relay raises these itself (it sees both sockets); the
# cloud pipe derives them from the traffic it can see.
ControllerEvent = Callable[[str, int], None]


class PartyLink(Protocol):
    """One live pipe to the app, speaking party-protocol dicts."""

    def send(self, message: dict[str, Any]) -> None:
        """Hand one party message to the app. Never raises on a dead pipe."""

    def messages(self) -> Iterator[dict[str, Any]]:
        """Yield inbound party messages until the pipe closes."""

    def close(self) -> None:
        """Close the pipe. Idempotent."""


class PartyTransport(Protocol):
    """Opens a :class:`PartyLink`, hello included."""

    def open(self) -> PartyLink:
        """Connect and complete this pipe's own handshake. Raises on failure."""


class LocalRelayTransport:
    """The loopback pipe: a websocket to the blind relay, ``join`` as its hello.

    This is the developer path. It is never what a phone uses: the URL is a
    loopback address that nothing off this machine can route.
    """

    def __init__(
        self,
        *,
        url: str,
        channel_id: str,
        open_timeout: float = 10.0,
    ) -> None:
        self._url = url
        self._channel_id = channel_id
        self._open_timeout = open_timeout

    @property
    def url(self) -> str:
        return self._url

    def open(self) -> PartyLink:
        ws = ws_connect(self._url, open_timeout=self._open_timeout)
        link = _JsonWebSocketLink(ws)
        link.send(join_message(self._channel_id, ROLE_EXECUTOR))
        return link


class _JsonWebSocketLink:
    """A :class:`PartyLink` over a raw websocket carrying one JSON dict per
    message — exactly the bytes the blind relay has always forwarded."""

    def __init__(self, ws: Any) -> None:
        self._ws = ws

    def send(self, message: dict[str, Any]) -> None:
        try:
            self._ws.send(json.dumps(message, separators=(",", ":")))
        except (ConnectionClosed, RuntimeError):
            pass

    def messages(self) -> Iterator[dict[str, Any]]:
        try:
            for raw in self._ws:
                decoded = decode_message(raw)
                if decoded is not None:
                    yield decoded
        except ConnectionClosed:
            return

    def close(self) -> None:
        try:
            self._ws.close()
        except Exception:  # noqa: BLE001 - closing a dead socket is not an error
            pass


def decode_message(raw: Any) -> dict[str, Any] | None:
    """Parse one party message, or ``None`` when it is not a JSON object.

    Shared by both pipes so a malformed message is dropped identically on each.
    """
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", errors="replace")
    if not isinstance(raw, str):
        return None
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return None
    return data if isinstance(data, dict) else None
