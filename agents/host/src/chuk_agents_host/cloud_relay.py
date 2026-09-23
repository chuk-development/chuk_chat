"""The cloud pipe — the host as an ``executor`` on ``api.chuk.chat``.

The production transport (docs/PLAN_2026-09-09_CLOUD_PAIRING_TRANSPORT.md). It
dials ``wss://api.chuk.chat/v2/relay/ws`` and carries **exactly** the messages
the blind loopback relay has always carried, one per ``cowork_relay`` frame:

    host -> {"type":"auth","role":"executor","device_id":"<uuid4>", ...}
    relay-> {"type":"auth_ok"}                       (or auth_error + close 1008)
    host -> {"req_id":"<hex>","type":"cowork_relay","payload":"<json string>"}
    relay-> {"req_id":...,"type":"cowork_relay","payload":"<json string>", ...}

``payload`` is the opaque blob the relay promises never to read. Here it is the
UTF-8 JSON of one party-protocol message (``join`` / ``pairing`` / ``frame`` —
:mod:`chuk_agents_host.protocol`), byte-identical to what goes over the loopback
relay. The §15 ceremony and the ``agents_frame`` seal are unchanged; only the
pipe is new, so a malicious relay still cannot MITM.

**Two credentials, in this order, once each.**

1. *First pairing.* The host has no account and must not need one, so it
   authenticates with nothing: ``{"type":"auth","role":"executor",
   "pairing_channel":"<256-bit url-safe id>","device_id":"<uuid4>"}``. The relay
   parks that socket on the pairing channel, where it can reach nobody until a
   logged-in app claims the channel. The channel id is the bearer capability —
   it is generated from a CSPRNG, it rides in the QR, and it is **never logged**.
2. *Ever after.* §15 step 7 hands the host the account token in the first sealed
   frame. It is persisted (:mod:`chuk_agents_host.account_store`) and every later
   connect is the ordinary authenticated handshake,
   ``{"type":"auth","token":"<supabase jwt>","role":"executor","device_id":...}``.
   The unauthenticated path runs **once per host, ever**: a stored token always
   wins over a pairing channel.

**The parked lifecycle.** A socket authenticated with a pairing channel is
*parked*: until a logged-in account claims that channel the relay lets it send
**only** ``{"type":"ping"}`` and refuses anything else with
``{"type":"error","code":"pairing_unclaimed"}``. So a parked link queues its
outbound party messages instead of spending them — the executor ``join`` hello is
the only one that can be waiting — and flushes them the moment the relay pushes
``{"type":"cowork_pair_bound"}``. That frame is the GO signal: from then on the
socket is an ordinary executor.

A channel nobody claims dies after five minutes:
``{"type":"cowork_pair_expired"}`` and ``close(1008)``. That is not a network
error and redialling the same channel would only be refused again, so it is
reported up to the host, which mints a **fresh** pairing channel and a fresh code
and prints them. A user who walked away comes back to a new code, not a dead
terminal.

**Controller presence.** The loopback relay sees both sockets and reports a
controller joining or leaving. The cloud relay tells an executor no such thing —
it is blind and it is the app's peer, not its supervisor. So presence is derived
from the traffic that is visible: the app's own ``join`` payload (the same first
message it sends on the loopback relay) means *attached*, and a
``controller_offline`` error for a frame we just sent means *gone*.

**Frame cap.** The relay refuses a frame over 1 MB with a correlatable
``cowork_error``. Chunking large payloads is work item 4 of the plan and is not
done here; a too-large frame is reported, never silently dropped.
"""

from __future__ import annotations

import base64
import json
import secrets
import threading
import uuid
from typing import Any, Callable, Iterator

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect as ws_connect

from .protocol import ROLE_CONTROLLER, ROLE_EXECUTOR, TYPE_JOIN, join_message
from .relay import EVENT_JOIN, EVENT_LEAVE
from .transport import ControllerEvent, PartyLink, decode_message

#: Where the relay lives when nothing says otherwise. A self-hosted backend is
#: pointed at with ``--relay-url`` (and rides in the pairing URI's ``r=``), so a
#: rebuild is never needed to move the deployment.
DEFAULT_RELAY_BASE_URL = "wss://api.chuk.chat"

#: The relay endpoint's path on that base. Owned by the API server's
#: ``routers/agents/agents_ws.py``.
RELAY_WS_PATH = "/v2/relay/ws"

#: Frame types the relay speaks (its side of the wire contract).
TYPE_AUTH = "auth"
TYPE_AUTH_OK = "auth_ok"
TYPE_AUTH_ERROR = "auth_error"
TYPE_AGENTS_RELAY = "cowork_relay"
TYPE_AGENTS_ERROR = "cowork_error"
TYPE_ERROR = "error"
TYPE_EXECUTOR_STATUS = "executor_status"
#: An authenticated account claimed the pairing channel. The GO signal: the
#: parked socket becomes an ordinary executor and queued frames may go out.
TYPE_PAIR_BOUND = "cowork_pair_bound"
#: Nobody claimed the channel in time. Followed by close(1008).
TYPE_PAIR_EXPIRED = "cowork_pair_expired"

#: The error code the relay answers with when the executor sends a frame and no
#: controller of that user is attached anywhere. Our one honest "the app left".
CODE_CONTROLLER_OFFLINE = "controller_offline"

#: The refusal a parked socket earns by sending anything but a ping. Seeing it is
#: a bug in this client, not a condition to handle — so it is logged loudly.
CODE_PAIRING_UNCLAIMED = "pairing_unclaimed"

#: How long before the code dies to say so. One minute is enough to re-run the
#: command, and not so early that the warning is noise.
EXPIRY_WARNING_LEAD_SECONDS = 60.0

#: Bytes of CSPRNG entropy behind a pairing channel id. 32 bytes = 256 bits,
#: url-safe base64 (43 chars, no padding). It is a bearer capability: whoever
#: holds it can talk to a host that is waiting to pair, so it is treated as key
#: material — never logged, never derived from anything guessable.
PAIRING_CHANNEL_BYTES = 32


class CloudRelayError(RuntimeError):
    """The relay refused the handshake, or the pipe could not be opened."""


class RelayAuthRejected(CloudRelayError):
    """The relay refused the account token this host offered.

    Carries the token that was refused so the caller can refresh exactly that
    one and redial at once. Without it a host with an aged-out token offers the
    same dead JWT on every backoff tick, forever: no controller can attach, and
    a controller is the other way a fresh token could arrive (bead cowork-fm8w).
    """

    def __init__(self, detail: str, *, token: str) -> None:
        super().__init__(f"relay refused the handshake: {detail}")
        self.detail = detail
        self.token = token


class PairingChannelExpired(CloudRelayError):
    """The pairing channel went unclaimed and the relay dropped it.

    Its own type because the answer is different from every other failure: the
    same channel must never be redialled, a new one must be minted first.
    """


def new_pairing_channel() -> str:
    """Mint a fresh pairing channel id: 256 CSPRNG bits, url-safe.

    Url-safe because it rides in a ``cowork://`` URI and a QR code; 256 bits
    because it is the only thing standing between a stranger and a host that is
    waiting to pair, and it is never rate-limited by a password prompt.
    """
    return base64.urlsafe_b64encode(secrets.token_bytes(PAIRING_CHANNEL_BYTES)).decode(
        "ascii"
    ).rstrip("=")


def relay_ws_url(base_url: str) -> str:
    """The full websocket URL for a relay base (``wss://api.chuk.chat``).

    ``http(s)://`` is accepted and upgraded, so a base copied out of a browser
    works; a base that already names the endpoint path is passed through.
    """
    base = (base_url or DEFAULT_RELAY_BASE_URL).strip().rstrip("/")
    if base.startswith("https://"):
        base = "wss://" + base[len("https://") :]
    elif base.startswith("http://"):
        base = "ws://" + base[len("http://") :]
    elif not base.startswith(("ws://", "wss://")):
        base = "wss://" + base
    if base.endswith(RELAY_WS_PATH):
        return base
    return base + RELAY_WS_PATH


def auth_frame(
    *,
    device_id: str,
    token: str | None = None,
    pairing_channel: str | None = None,
    role: str = ROLE_EXECUTOR,
) -> dict[str, Any]:
    """The handshake frame — a token when the host has an account, otherwise the
    pairing channel. Never both: an account token means pairing is over."""
    frame: dict[str, Any] = {"type": TYPE_AUTH, "role": role, "device_id": device_id}
    if token:
        frame["token"] = token
    elif pairing_channel:
        frame["pairing_channel"] = pairing_channel
    else:
        raise CloudRelayError(
            "no credential: the host has neither an account token nor a pairing "
            "channel, so it cannot open the relay"
        )
    return frame


def wrap_payload(message: dict[str, Any], req_id: str | None = None) -> dict[str, Any]:
    """Put one party message inside a ``cowork_relay`` frame.

    The executor sends no ``target_device_id``: its replies fan out to the
    controllers of its own account (or, while pairing, of the claimed channel).
    """
    return {
        "req_id": req_id or uuid.uuid4().hex,
        "type": TYPE_AGENTS_RELAY,
        "payload": json.dumps(message, separators=(",", ":")),
    }


def unwrap_payload(frame: dict[str, Any]) -> dict[str, Any] | None:
    """Take the party message back out of a ``cowork_relay`` frame.

    A JSON string is what this host sends and what it expects. A JSON object is
    accepted too: the payload is opaque to the relay either way, and being lenient
    on receive costs nothing while the app's side of the pipe is still landing.
    """
    return decode_message(frame.get("payload"))


def _close_quietly(ws: Any) -> None:
    """Close a socket that has already failed us. A close that fails is not news."""
    try:
        ws.close()
    except Exception:  # noqa: BLE001 - closing a dead socket is not an error
        pass


class CloudRelayTransport:
    """Opens an authenticated executor link to the cloud relay."""

    def __init__(
        self,
        *,
        device_id: str,
        channel_id: str = "",
        base_url: str = DEFAULT_RELAY_BASE_URL,
        token_provider: Callable[[], str | None] | None = None,
        pairing_channel_provider: Callable[[], str | None] | None = None,
        on_controller_event: ControllerEvent | None = None,
        on_pairing_expired: Callable[[], None] | None = None,
        logger: Callable[[str], None] | None = None,
        open_timeout: float = 15.0,
        connect: Callable[..., Any] = ws_connect,
    ) -> None:
        self._device_id = device_id
        self._channel_id = channel_id
        self._base_url = base_url
        self._token_provider = token_provider or (lambda: None)
        self._pairing_channel_provider = pairing_channel_provider or (lambda: None)
        self._on_controller_event = on_controller_event
        self._on_pairing_expired = on_pairing_expired
        self._log = logger or (lambda _msg: None)
        self._open_timeout = open_timeout
        self._connect = connect

    @property
    def url(self) -> str:
        return relay_ws_url(self._base_url)

    @property
    def device_id(self) -> str:
        return self._device_id

    def credential(self) -> tuple[str, str]:
        """``(kind, value)`` for this connect: ``("token", jwt)`` when an account
        token is stored, else ``("pairing_channel", id)``. A stored token always
        wins — the unauthenticated path is used once per host, ever."""
        token = self._token_provider()
        if isinstance(token, str) and token:
            return "token", token
        channel = self._pairing_channel_provider()
        if isinstance(channel, str) and channel:
            return "pairing_channel", channel
        raise CloudRelayError(
            "no account token and no pairing channel: nothing to authenticate with"
        )

    def open(self) -> PartyLink:
        kind, value = self.credential()
        frame = auth_frame(
            device_id=self._device_id,
            token=value if kind == "token" else None,
            pairing_channel=value if kind == "pairing_channel" else None,
        )
        url = self.url
        # The credential itself is never logged: one is a live account JWT, the
        # other is the pairing bearer capability.
        self._log(
            f"dialling the cloud relay at {url} as executor "
            f"({'account token' if kind == 'token' else 'pairing channel'})"
        )
        ws = self._connect(url, open_timeout=self._open_timeout)
        try:
            ws.send(json.dumps(frame, separators=(",", ":")))
            reply = decode_message(ws.recv(timeout=self._open_timeout))
        except (ConnectionClosed, TimeoutError, OSError) as exc:
            _close_quietly(ws)
            raise CloudRelayError(f"relay handshake failed: {exc}") from exc
        if reply is None or reply.get("type") != TYPE_AUTH_OK:
            detail = "no reply" if reply is None else str(reply.get("detail") or reply.get("type"))
            _close_quietly(ws)
            if kind == "token":
                raise RelayAuthRejected(detail, token=value)
            raise CloudRelayError(f"relay refused the handshake: {detail}")
        # ``auth_ok`` carries extra fields on the pairing path
        # (``mode``, ``expires_in``). Read what is useful, ignore the rest: the
        # server may grow the frame and this client must not care.
        parked = kind == "pairing_channel" or reply.get("mode") == "pairing"
        expires_in = reply.get("expires_in")
        if not isinstance(expires_in, (int, float)) or isinstance(expires_in, bool):
            expires_in = None
        if parked:
            self._log(
                "cloud relay parked this host on its pairing channel"
                + (f"; the code dies in {expires_in:g}s" if expires_in else "")
            )
        else:
            self._log("cloud relay accepted this host as an executor")
        link = CloudRelayLink(
            ws,
            on_controller_event=self._on_controller_event,
            on_pairing_expired=self._on_pairing_expired,
            logger=self._log,
            join_message=(
                join_message(self._channel_id, ROLE_EXECUTOR)
                if self._channel_id
                else None
            ),
            # A token socket is live at once; a parked one may send only pings
            # until the relay says an account claimed the channel.
            claimed=not parked,
            expires_in=expires_in if parked else None,
        )
        # The same hello the loopback relay gets, as the first payload: it tells a
        # controller already on the channel that the executor is here.
        link.send_join()
        return link


class CloudRelayLink:
    """A :class:`~chuk_agents_host.transport.PartyLink` over one relay socket.

    Wraps every outbound party message in a ``cowork_relay`` frame, unwraps every
    inbound one, and answers the relay's own control frames. Controller presence
    is derived here (see the module docstring).
    """

    def __init__(
        self,
        ws: Any,
        *,
        on_controller_event: ControllerEvent | None = None,
        on_pairing_expired: Callable[[], None] | None = None,
        logger: Callable[[str], None] | None = None,
        join_message: dict[str, Any] | None = None,
        claimed: bool = True,
        expires_in: float | None = None,
    ) -> None:
        # ``join_message`` here is the built hello dict, not the protocol helper
        # of the same name — the transport builds it and hands it over.
        self._ws = ws
        self._on_controller_event = on_controller_event
        self._on_pairing_expired = on_pairing_expired
        self._log = logger or (lambda _msg: None)
        self._join_message = join_message
        self._lock = threading.Lock()
        self._tokens = 0
        self._controller_token: int | None = None
        # Parked until an account claims the channel: everything but a ping is
        # refused, so outbound messages wait here rather than being spent.
        self._claimed = claimed
        self._pending: list[dict[str, Any]] = []
        self._expired = False
        self._warning: threading.Timer | None = None
        if not claimed and expires_in and expires_in > EXPIRY_WARNING_LEAD_SECONDS:
            self._warning = threading.Timer(
                expires_in - EXPIRY_WARNING_LEAD_SECONDS, self._warn_expiring
            )
            self._warning.daemon = True
            self._warning.start()

    def _warn_expiring(self) -> None:
        with self._lock:
            if self._claimed or self._expired:
                return
        self._log(
            f"this pairing code expires in about {EXPIRY_WARNING_LEAD_SECONDS:g}s; "
            "scan it now or a fresh one will be printed"
        )

    # -- outbound --------------------------------------------------------

    #: How many party messages a parked link holds before it starts dropping the
    #: oldest. In practice the queue holds one (the executor hello); the bound is
    #: only there so a bug cannot grow it without limit.
    MAX_PENDING = 32

    def send(self, message: dict[str, Any]) -> None:
        with self._lock:
            if not self._claimed:
                # A parked socket may send ONLY a ping. Holding the message is
                # what makes that constraint invisible to the party above.
                self._pending.append(message)
                del self._pending[: max(0, len(self._pending) - self.MAX_PENDING)]
                return
        self._send_wrapped(message)

    def _send_wrapped(self, message: dict[str, Any]) -> None:
        frame = wrap_payload(message)
        try:
            self._ws.send(json.dumps(frame, separators=(",", ":")))
        except (ConnectionClosed, RuntimeError):
            pass

    @property
    def claimed(self) -> bool:
        """False while the relay has this socket parked on an unclaimed channel."""
        with self._lock:
            return self._claimed

    @property
    def pending(self) -> list[dict[str, Any]]:
        """The party messages held back while parked (diagnostics and tests)."""
        with self._lock:
            return list(self._pending)

    def _on_bound(self) -> None:
        """An account claimed the channel: the socket is an ordinary executor now.

        Flush what was held, then treat it as a controller attaching. The app's
        own ``join`` payload still arrives and is still what carries the ceremony;
        this only makes sure the host is not waiting on it to start.
        """
        with self._lock:
            if self._claimed:
                return
            self._claimed = True
            pending, self._pending = self._pending, []
        self._cancel_warning()
        self._log("cloud relay: an account claimed the pairing channel")
        for message in pending:
            self._send_wrapped(message)
        self._controller_joined_if_absent()

    def _on_expired(self) -> None:
        """The channel died unclaimed. Never redial it — say so and let the host
        mint a new one."""
        with self._lock:
            if self._expired:
                return
            self._expired = True
            self._pending.clear()
        self._cancel_warning()
        self._log("the pairing code expired unused; minting a fresh one")
        if self._on_pairing_expired is None:
            return
        try:
            self._on_pairing_expired()
        except Exception as exc:  # noqa: BLE001 - a listener must not kill the pipe
            self._log(f"cloud relay: expiry listener failed: {exc}")

    def _cancel_warning(self) -> None:
        timer, self._warning = self._warning, None
        if timer is not None:
            timer.cancel()

    def send_join(self) -> None:
        """Send this pipe's executor hello, when the transport gave us one."""
        if self._join_message is not None:
            self.send(self._join_message)

    def close(self) -> None:
        self._cancel_warning()
        try:
            self._ws.close()
        except Exception:  # noqa: BLE001 - closing a dead socket is not an error
            pass

    # -- inbound ---------------------------------------------------------

    def messages(self) -> Iterator[dict[str, Any]]:
        try:
            for raw in self._ws:
                frame = decode_message(raw)
                if frame is None:
                    continue
                yield from self.handle_frame(frame)
        except ConnectionClosed:
            return

    def handle_frame(self, frame: dict[str, Any]) -> list[dict[str, Any]]:
        """One relay frame in, zero or one party messages out.

        Split out from :meth:`messages` so the routing rules are testable without
        a socket — the same reason the relay's own rules live apart from its
        endpoint.
        """
        kind = frame.get("type")
        if kind == TYPE_AGENTS_RELAY:
            message = unwrap_payload(frame)
            if message is None:
                self._log("cloud relay: dropped a frame with an unreadable payload")
                return []
            if self._is_controller_join(message):
                # Belt and braces with ``cowork_pair_bound``: whichever arrives
                # first opens the session, the second is a no-op. Two joins would
                # mean two commits from two fresh ceremonies, and the app would be
                # answering the one we already threw away.
                self._controller_joined_if_absent()
                return []
            # Traffic from a peer we never saw join still means one is there.
            self._controller_joined_if_absent()
            return [message]
        if kind == TYPE_PAIR_BOUND:
            self._on_bound()
            return []
        if kind == TYPE_PAIR_EXPIRED:
            self._on_expired()
            return []
        if kind in (TYPE_AGENTS_ERROR, TYPE_ERROR):
            self._on_error(frame)
            return []
        if kind == "ping":
            self.send_control({"type": "pong"})
            return []
        if kind in (TYPE_AUTH_OK, TYPE_EXECUTOR_STATUS, "pong", "cowork_presence"):
            return []
        if kind == TYPE_AUTH_ERROR:
            self._log(f"cloud relay ended the session: {frame.get('detail')}")
            return []
        self._log(f"cloud relay: ignoring frame type {kind!r}")
        return []

    def send_control(self, frame: dict[str, Any]) -> None:
        """Send a relay control frame verbatim (not wrapped in a payload)."""
        try:
            self._ws.send(json.dumps(frame, separators=(",", ":")))
        except (ConnectionClosed, RuntimeError):
            pass

    # -- controller presence ---------------------------------------------

    @property
    def controller_token(self) -> int | None:
        with self._lock:
            return self._controller_token

    def _is_controller_join(self, message: dict[str, Any]) -> bool:
        return (
            message.get("type") == TYPE_JOIN
            and message.get("role") == ROLE_CONTROLLER
        )

    def _controller_joined(self) -> None:
        with self._lock:
            self._tokens += 1
            token = self._tokens
            self._controller_token = token
        self._log("cloud relay: a controller is on the channel")
        self._emit(EVENT_JOIN, token)

    def _controller_joined_if_absent(self) -> None:
        with self._lock:
            present = self._controller_token is not None
        if not present:
            self._controller_joined()

    def _controller_left(self) -> None:
        with self._lock:
            token = self._controller_token
            self._controller_token = None
        if token is None:
            return
        self._log("cloud relay: no controller is attached any more")
        self._emit(EVENT_LEAVE, token)

    def _emit(self, event: str, token: int) -> None:
        if self._on_controller_event is None:
            return
        try:
            self._on_controller_event(event, token)
        except Exception as exc:  # noqa: BLE001 - a listener must not kill the pipe
            self._log(f"cloud relay: controller-event listener failed: {exc}")

    def _on_error(self, frame: dict[str, Any]) -> None:
        code = frame.get("code")
        if code == CODE_CONTROLLER_OFFLINE:
            self._controller_left()
            return
        if code == CODE_PAIRING_UNCLAIMED:
            # This client is supposed to make that impossible by queueing while
            # parked. If it happens, it is our bug and it must be loud.
            self._log(
                "cloud relay refused a frame sent while parked (pairing_unclaimed) "
                "— nothing but a ping may leave an unclaimed socket"
            )
            return
        # Never silently dropped: the sender must be able to act on a refusal.
        self._log(f"cloud relay refused a frame: {code}")
