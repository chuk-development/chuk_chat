"""CoWork local host.

Runs the whole platform on one machine with no production relay: a blind
localhost relay, an agent roster, the pairing initiator, and the real executor
under the manager's supervisor.

- :class:`LocalHost` — the top-level wiring (relay + roster + pairing + serving).
- :class:`LocalRelay` — the blind localhost WebSocket relay (developer path).
- :class:`CloudRelayTransport` — the production pipe: this host as an
  ``executor`` on ``api.chuk.chat``, pairing channel first, account token after.
- :class:`HostParty` — the pairing initiator + task bridge (the app's counterpart).
- :class:`TaskServer` — runs the supervised :class:`~cowork_executor.Executor`.
- ``protocol`` — the local relay wire (join / pairing / frame envelopes).
"""

from __future__ import annotations

from .account_store import AccountStore
from .cloud_relay import (
    DEFAULT_RELAY_BASE_URL,
    CloudRelayLink,
    CloudRelayTransport,
    new_pairing_channel,
    relay_ws_url,
)
from .host import KEY_VERSION, TRANSPORT_CLOUD, TRANSPORT_LOCAL, LocalHost
from .identity import HOST_DEVICE_ID, load_or_create_identity
from .party import HostParty
from .protocol import (
    ROLE_CONTROLLER,
    ROLE_EXECUTOR,
    frame_envelope,
    join_message,
    pairing_envelope,
)
from .pairing_uri import pairing_uri, qr_lines, qr_text
from .relay import LocalRelay
from .serve import TaskServer
from .room_service import RoomService, dispatch_room_frame
from .transport import LocalRelayTransport, PartyLink, PartyTransport

__all__ = [
    "AccountStore",
    "CloudRelayLink",
    "CloudRelayTransport",
    "DEFAULT_RELAY_BASE_URL",
    "LocalRelayTransport",
    "PartyLink",
    "PartyTransport",
    "TRANSPORT_CLOUD",
    "TRANSPORT_LOCAL",
    "new_pairing_channel",
    "pairing_uri",
    "qr_lines",
    "qr_text",
    "relay_ws_url",
    "RoomService",
    "dispatch_room_frame",
    "HOST_DEVICE_ID",
    "HostParty",
    "KEY_VERSION",
    "LocalHost",
    "LocalRelay",
    "ROLE_CONTROLLER",
    "ROLE_EXECUTOR",
    "TaskServer",
    "frame_envelope",
    "join_message",
    "load_or_create_identity",
    "pairing_envelope",
]
