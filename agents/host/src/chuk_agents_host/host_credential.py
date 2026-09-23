"""The host's own account credential: which session it holds, and how it heals.

Why this exists
===============
The host used to run on the **app's** Supabase session: the
``account_authentication`` frame carried the app's access token and refresh
token. Supabase rotates refresh tokens, so app and host shared one
refresh-token family and whoever refreshed second was refused. After a host
sat offline for three days its ``account.json`` held a dead refresh token. The
relay refused the handshake, so no app could reach the host to hand it a new
token. Nothing but a new pairing could end that, and a new pairing must never
be necessary.

Two changes end it:

1. **An independent session.** The host asks the attached app for a session of
   its own (``host_session_request``). The app mints one through the API
   (``POST /v2/agents/host-session``) and sends it in an ordinary
   ``account_authentication`` frame marked ``"session_kind": "host"``. That
   session is a separate sign-in with its own refresh-token family, so the host
   refreshes it whenever it likes and never touches the app's session again.
   A frame without the mark (an old app, or a new app that sends only its
   access token) never replaces a live independent session.

2. **A heal path for a dead credential.** When GoTrue refuses the refresh
   token, the host stops offering the dead token and parks on the relay's
   pairing door under a *heal channel*: a 256-bit value derived from the
   channel key both paired sides already hold (:func:`derive_heal_channel`).
   A paired app computes the same value and claims it with its own account
   JWT. From that moment the socket is an ordinary executor of that account,
   and the app re-provisions the host over the existing end-to-end channel.

Threat model of the heal path
=============================
The relay stays blind and gains no new power:

* The heal channel is a bearer capability for **one parked socket** and
  nothing else, exactly like a first-pairing channel. It is derived with HMAC
  from the channel key, so seeing it reveals nothing about that key.
* Whoever claims the socket (the relay itself, or anybody who learned the
  value) only gets a route to the host. Every message the host acts on must
  still pass the controller-session handshake: a signature by the paired app's
  device key and a MAC by the channel key. The first-pairing ceremony is not
  open either, because a host with stored trust has no pairing code.
* A new account token only arrives inside a sealed frame from the paired app.
  The relay cannot mint, read or replace it.
* The worst a hostile relay can do is what it can always do: drop traffic.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
from dataclasses import dataclass
from typing import Any

#: The mark the app puts on an independent host session, and the value the
#: host keeps in ``account.json``.
KIND_HOST = "host"
#: A session that is the app's own (an old app sends its pair as before).
KIND_APP = "app"
#: A frame with an access token and no refresh token (a new app that does not
#: share its refresh token any more). Enough to work for an hour, never stored.
KIND_ACCESS_ONLY = "access_only"

#: Host -> app: "mint me a session of my own". A new frame type, so an old app
#: ignores it instead of answering it with its own session in a loop.
TYPE_HOST_SESSION_REQUEST = "host_session_request"

#: GoTrue answers a refresh token it will never accept again with one of these.
#: A 5xx, a 429 or a network error is transient and is NOT a dead credential.
DEAD_REFRESH_STATUSES = frozenset({400, 401, 403})

#: Domain label for the heal channel. Bump the version only for a breaking
#: change: the app derives the same value (``agents_heal_channel.dart``).
_HEAL_CHANNEL_LABEL = b"cowork/host/heal-channel/v1/"


def derive_heal_channel(channel_key: bytes, channel_id: str) -> str:
    """The relay pairing channel a paired host parks on when its credential died.

    HMAC-SHA256 over the channel id, keyed by the 32-byte channel key, in
    url-safe base64 without padding: 43 characters, 256 bits, which is exactly
    what the relay requires of a pairing channel.
    """
    if len(channel_key) != 32:
        raise ValueError("channel key must be 32 bytes")
    if not channel_id:
        raise ValueError("channel id must not be empty")
    mac = hmac.new(
        channel_key, _HEAL_CHANNEL_LABEL + channel_id.encode("utf-8"), hashlib.sha256
    ).digest()
    return base64.urlsafe_b64encode(mac).decode("ascii").rstrip("=")


def refresh_is_dead(exc: BaseException) -> bool:
    """True when ``exc`` says GoTrue refused the refresh token for good."""
    status = getattr(exc, "status", None)
    return isinstance(status, int) and status in DEAD_REFRESH_STATUSES


def frame_kind(payload: Any) -> str | None:
    """What credential an ``account_authentication`` payload carries."""
    if not isinstance(payload, dict):
        return None
    access = payload.get("access_token")
    refresh = payload.get("refresh_token")
    has_access = isinstance(access, str) and bool(access)
    has_refresh = isinstance(refresh, str) and bool(refresh)
    if not has_access:
        return None
    if has_refresh and payload.get("session_kind") == KIND_HOST:
        return KIND_HOST
    if has_refresh:
        return KIND_APP
    return KIND_ACCESS_ONLY


@dataclass(frozen=True)
class ProvisionDecision:
    """What one ``account_authentication`` frame does to the host's credential.

    ``adopt``: replace the live session's tokens with the frame's.
    ``kind``: the kind of credential the host holds afterwards.
    ``persist``: write the frame's pair to ``account.json``.
    ``want_host_session``: ask the app for an independent session.
    """

    adopt: bool
    kind: str
    persist: bool
    want_host_session: bool


def decide(payload: Any, *, current_kind: str | None, dead: bool) -> ProvisionDecision:
    """Decide what a provision frame does, given what the host holds now.

    The one rule that ends the rotation war: a live independent session is
    never replaced by anything but another independent session. The app's own
    refresh token is then never stored, never spent, and never rotated away
    under the app.
    """
    kind = frame_kind(payload)
    if kind == KIND_HOST:
        return ProvisionDecision(adopt=True, kind=KIND_HOST, persist=True,
                                 want_host_session=False)
    holding_live_host = current_kind == KIND_HOST and not dead
    if holding_live_host:
        return ProvisionDecision(adopt=False, kind=KIND_HOST, persist=False,
                                 want_host_session=False)
    if kind == KIND_APP:
        # An old app: keep the old behaviour so it still works, and ask for an
        # independent session in case the app is new enough to mint one.
        return ProvisionDecision(adopt=True, kind=KIND_APP, persist=True,
                                 want_host_session=True)
    if kind == KIND_ACCESS_ONLY:
        return ProvisionDecision(adopt=True, kind=KIND_ACCESS_ONLY, persist=False,
                                 want_host_session=True)
    return ProvisionDecision(adopt=False, kind=current_kind or KIND_APP,
                             persist=False, want_host_session=False)


def stored_kind(token: dict[str, Any] | None) -> str | None:
    """The kind of the token in ``account.json``; an unmarked one is the app's."""
    if not isinstance(token, dict):
        return None
    return KIND_HOST if token.get("session_kind") == KIND_HOST else KIND_APP
