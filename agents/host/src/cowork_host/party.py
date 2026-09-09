"""The host party — the pairing initiator and the app's counterpart.

This is the host's own end of the pipe. It opens a
:class:`~cowork_host.transport.PartyTransport` (the blind loopback relay for
same-machine development, the cloud relay in production), drives the §15 pairing
ceremony as the **initiator**, and then serves tasks:

1. **pair** — publish the commitment, reveal ``A`` after the joiner's ``B``,
   confirm keys, exchange device keys. On success it holds the channel key and
   the app's approved device key.
2. **provision** — open the first sealed frame (``account_authentication``),
   build the model factory from the token, and start the :class:`TaskServer`.
3. **serve** — forward every later sealed frame to the Executor and stream its
   sealed results back to the app.

Nothing below knows which pipe it is on. The transport owns the connection and
whatever hello it needs (``join`` on the loopback relay, the ``auth`` handshake
plus ``cowork_relay`` wrapping on the cloud one) and hands this class plain
party-protocol dicts in both directions. That is what made the cloud transport a
new file rather than a rewrite of this one.

Only the token frame is opened here (at ``seq`` 0); the shared
:class:`~cowork_crypto.CoworkFrameOpener` is then handed to the Executor, which
opens task frames itself (``seq`` 1+). One opener, no frame opened twice, replay
protection intact.
"""

from __future__ import annotations

import base64
import json
import threading
from typing import Any, Callable

from cowork_crypto import (
    ApprovedDevices,
    CoworkFrameOpener,
    CoworkFrameRejected,
    CoworkFrameSealer,
    Pairing,
    PairingError,
    PairingState,
    ReconnectError,
    ReconnectHandshake,
)
from .protocol import (
    STEP_COMMIT,
    STEP_CONFIRM_C,
    STEP_DEVICE_C,
    STEP_RECONNECT_CONFIRM,
    STEP_RECONNECT_HELLO,
    STEP_REVEAL,
    TYPE_FRAME,
    TYPE_PAIRING,
    frame_envelope,
    pairing_envelope,
)
from .serve import TaskServer
from .transport import PartyLink, PartyTransport

# Builds a TaskServer once the token is provisioned. Given the shared opener,
# sealer, and the decoded token dict, it wires and returns a ready TaskServer.
TaskServerBuilder = Callable[
    [CoworkFrameOpener, CoworkFrameSealer, dict, "HostParty"], TaskServer
]

# Mints a fresh pairing *initiator* session — new ephemeral keys and a new
# expiry — for the host's printed code. Called once per controller connection so
# an interrupted attempt never leaves the next one facing an expired session.
# Returns ``None`` when the code has already been CONSUMED by a successful
# pairing (single use); the party then offers no ceremony at all.
PairingFactory = Callable[[], "Pairing | None"]

# Reports the token of a controller already on the channel, or ``None``. Lets the
# party pick up a controller that connected before its own executor link came up.
ControllerToken = Callable[[], int | None]

# Mints a fresh reconnect *initiator* session from the persisted trust, together
# with the stored channel key and the approved-device set (holding the paired
# app's key) that will build the frame codec once the handshake authenticates.
# Returns ``None`` when there is no stored pairing (so the party pairs afresh).
ReconnectFactory = Callable[
    [], "tuple[ReconnectHandshake, bytes, ApprovedDevices] | None"
]

# Called with a freshly COMPLETED pairing so the host can persist the trust
# record (channel key + the app's approved device key) for later reconnects.
PairEstablished = Callable[[Pairing], None]


class HostParty:
    """Drives the host's executor link: a fresh pairing initiator per controller
    connection, then the task bridge for that session.

    The executor connection lives for the whole host lifetime. Each controller
    connection gets its own pairing session: on connect the party mints a fresh
    :class:`Pairing` (reusing the stable code) and publishes its commit; on
    disconnect it tears the session down so the next controller pairs cleanly.
    """

    def __init__(
        self,
        *,
        transport: PartyTransport,
        channel_id: str,
        pairing_factory: PairingFactory,
        device_id: str,
        device_identity: Any,
        key_version: int,
        build_task_server: TaskServerBuilder,
        logger: Callable[[str], None] | None = None,
        controller_token: ControllerToken | None = None,
        # A pipe that can vanish (the cloud one) redials with capped backoff; the
        # loopback relay lives in this process, so it does not.
        reconnect: bool = False,
        backoff_seconds: tuple[float, ...] = (1.0, 2.0, 5.0, 10.0, 20.0, 30.0),
        reconnect_factory: ReconnectFactory | None = None,
        on_pair_established: PairEstablished | None = None,
        on_reprovision: Callable[[dict], None] | None = None,
    ) -> None:
        self._transport = transport
        self._reconnect_pipe = reconnect
        self._backoff = backoff_seconds or (5.0,)
        # docs/WIRE_CONTRACT.md: called with the token of a later account frame
        # so the host refreshes its session in place (the task server outlives
        # the socket, so it is never rebuilt for a new token).
        self._on_reprovision = on_reprovision
        # Result frames sent while no controller was attached are dropped, not
        # buffered. Counted for diagnostics.
        self.frames_dropped_while_away = 0
        self._channel_id = channel_id
        self._pairing_factory = pairing_factory
        self._reconnect_factory = reconnect_factory
        self._on_pair_established = on_pair_established
        self._device_id = device_id
        self._device_identity = device_identity
        self._key_version = key_version
        self._build_task_server = build_task_server
        self._log = logger or (lambda _msg: None)
        self._controller_token = controller_token

        self._link: PartyLink | None = None
        self._link_lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

        # Everything below is per-session state, guarded by ``_session_lock``.
        # It is mutated from the relay's peer-event threads (a controller joining
        # or leaving) and read from this party's own run loop, so all access is
        # serialised.
        self._session_lock = threading.Lock()
        self._ws_ready = False
        # The controller connection we intend to pair with, and the one we have
        # actually published a commit for. Tracking both — by per-connection
        # token — makes a reconnect deterministic even if a stale ``leave`` and
        # the fresh ``join`` arrive out of order across threads.
        self._active_token: int | None = None
        self._started_token: int | None = None
        self._pairing: Pairing | None = None
        # Reconnect session (used instead of ``_pairing`` when a stored trust
        # record exists): the handshake plus the stored channel key + approved
        # devices that build the frame codec once it authenticates.
        self._reconnect: ReconnectHandshake | None = None
        self._reconnect_channel_key: bytes | None = None
        self._reconnect_approved: ApprovedDevices | None = None
        self._opener: CoworkFrameOpener | None = None
        self._sealer: CoworkFrameSealer | None = None
        self._task_server: TaskServer | None = None
        self._provisioned = False
        self._paired = threading.Event()
        # True while a controller socket is connected. Read by the result pump
        # (drop while away) and by the host's notifier (tell the user another
        # way when a run ends with nobody watching).
        self._controller_present = False

    # -- lifecycle -------------------------------------------------------

    def start(self) -> None:
        self._thread = threading.Thread(
            target=self._run, name="cowork-host-party", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._session_lock:
            task_server = self._task_server
            self._task_server = None
        if task_server is not None:
            task_server.stop()
        with self._link_lock:
            link = self._link
        if link is not None:
            link.close()
        if self._thread is not None:
            self._thread.join(timeout=3.0)
            self._thread = None

    @property
    def task_server(self) -> TaskServer | None:
        with self._session_lock:
            return self._task_server

    def wait_paired(self, timeout: float | None = None) -> bool:
        with self._session_lock:
            event = self._paired
        return event.wait(timeout)

    # -- controller lifecycle (driven by the relay's peer events) --------

    @property
    def controller_attached(self) -> bool:
        """True while a controller socket is connected to this channel. The
        notifier reads it: a run that ends with no controller attached is one
        the user must be told about some other way."""
        with self._session_lock:
            return self._controller_present

    def on_controller_joined(self, token: int) -> None:
        """A controller connected. Remember it and start a session if we can."""
        with self._session_lock:
            self._active_token = token
            self._controller_present = True
        self._maybe_start_session()

    def on_controller_left(self, token: int) -> None:
        """The controller for ``token`` dropped. Reset the pairing session so the
        next one pairs cleanly — but NOT the task server: a run belongs to this
        host process, not to the socket (docs/WIRE_CONTRACT.md). It keeps going,
        keeps writing the transcript, and is replayable from any device. A stale
        leave from a superseded connection is ignored."""
        with self._session_lock:
            if self._active_token != token:
                return
            self._active_token = None
            self._started_token = None
            self._controller_present = False
            # The codec is NOT cleared here. The leave arrives on the relay's
            # thread while frames from that same socket (a token, the task it
            # sent just before closing) can still be queued for this party's
            # run loop; clearing the codec now would drop them as "before
            # pairing" and lose the task. The next controller's join resets
            # the whole session in ``_maybe_start_session`` anyway.
        self._log("controller disconnected; runs keep going, results are held in the store")

    def _reset_session_locked(self) -> TaskServer | None:
        """Clear per-session (codec + pairing) state. The task server is NOT
        part of a session any more: it lives for the host process and is only
        stopped by :meth:`stop`. Returns None; kept for the callers' shape."""
        self._pairing = None
        self._reconnect = None
        self._reconnect_channel_key = None
        self._reconnect_approved = None
        self._opener = None
        # The task server and host-originated senders outlive the socket and
        # share this sealer. Keep their sequence monotonic for the same stored
        # channel key; a new pairing replaces it in _on_paired.
        # The next token frame re-provisions the long-lived task server
        # (rebinds its codec, refreshes the account session in place).
        self._provisioned = False
        self._paired = threading.Event()
        return None

    def _maybe_start_session(self) -> None:
        """Open a fresh session for the pending controller, once — but only when
        the executor link is up and we have not already started for it.

        If a stored trust record exists, this is a **reconnect**: publish a signed
        ``reconnect-hello`` (no code). Otherwise it is a **first pairing**:
        publish the commitment as before."""
        old_task_server = None
        step = None
        envelope = None
        with self._session_lock:
            token = self._active_token
            if not self._ws_ready or token is None or self._started_token == token:
                return
            old_task_server = self._reset_session_locked()
            reconnect_ctx = (
                self._reconnect_factory() if self._reconnect_factory is not None else None
            )
            if reconnect_ctx is not None:
                handshake, channel_key, approved = reconnect_ctx
                self._reconnect = handshake
                self._reconnect_channel_key = channel_key
                self._reconnect_approved = approved
                step, envelope = STEP_RECONNECT_HELLO, handshake.create_hello()
                self._started_token = token
                log = "controller connected; sending a reconnect hello (no code)"
            else:
                pairing = self._pairing_factory()
                self._started_token = token
                if pairing is None:
                    # The code has been used already and no trust is stored: this
                    # host has nothing to offer. Stay silent — never re-open a
                    # consumed code — and let the controller time out.
                    log = (
                        "controller connected but this host has no pairing code "
                        "left (it was already used) and no stored trust; "
                        "re-pair with `cowork-host --pair`"
                    )
                else:
                    self._pairing = pairing
                    step, envelope = STEP_COMMIT, pairing.create_commit()
                    log = "controller connected; publishing a fresh pairing commit"
        if old_task_server is not None:
            old_task_server.stop()
        self._log(log)
        if step is None or envelope is None:
            return
        self._send(pairing_envelope(step, envelope))

    # -- run loop --------------------------------------------------------

    def _run(self) -> None:
        """Hold the pipe open for this host's lifetime.

        One attempt for a pipe that cannot come back (the in-process loopback
        relay); an endless redial with capped backoff for one that can (the cloud
        relay: a dropped connection, a rotated token, a restarted API replica).
        The session state is reset on every drop, so the next controller pairs or
        reconnects cleanly — runs keep going regardless, they belong to the
        process and not to the socket."""
        attempt = 0
        while not self._stop.is_set():
            connected = self._run_once()
            if not self._reconnect_pipe or self._stop.is_set():
                return
            attempt = 0 if connected else attempt + 1
            delay = self._backoff[min(attempt, len(self._backoff) - 1)]
            self._log(f"pipe down; redialling in {delay:g}s")
            if self._stop.wait(delay):
                return

    def _run_once(self) -> bool:
        """One connect + pump. Returns True when the pipe was actually open, so
        the caller can tell a dropped connection from one that never came up."""
        connected = False
        try:
            link = self._transport.open()
        except Exception as exc:  # noqa: BLE001 - a refused dial is ordinary
            self._log(f"could not open the pipe: {type(exc).__name__}: {exc}")
            return False
        try:
            with self._link_lock:
                self._link = link
            connected = True
            self._on_ws_ready()
            self._log("waiting for the app to pair...")
            for message in link.messages():
                if self._stop.is_set():
                    break
                self._handle(message)
        except Exception as exc:  # never crash the process on a party failure
            self._log(f"party stopped: {type(exc).__name__}: {exc}")
        finally:
            with self._session_lock:
                self._ws_ready = False
                self._started_token = None
                self._controller_present = False
            with self._link_lock:
                self._link = None
            link.close()
        return connected

    def _on_ws_ready(self) -> None:
        """The executor link is up. If a controller is already waiting on the
        channel, adopt it now; otherwise a later ``join`` event will."""
        with self._session_lock:
            self._ws_ready = True
        token = self._controller_token() if self._controller_token else None
        if token is not None:
            self.on_controller_joined(token)

    def _send(self, obj: dict[str, Any]) -> None:
        with self._link_lock:
            link = self._link
        if link is not None:
            link.send(obj)

    def _handle(self, msg: dict[str, Any]) -> None:
        """One inbound party message, already decoded by the pipe."""
        if not isinstance(msg, dict):
            return
        kind = msg.get("type")
        self._log(f"recv msg type={kind!r}")
        if kind == TYPE_PAIRING:
            self._handle_pairing(msg.get("data") or {})
        elif kind == TYPE_FRAME:
            frame_b64 = msg.get("frame")
            if isinstance(frame_b64, str):
                self._handle_frame(frame_b64)

    # -- pairing (initiator) --------------------------------------------

    def _handle_pairing(self, data: dict[str, Any]) -> None:
        with self._session_lock:
            pairing = self._pairing
            reconnect = self._reconnect
        if reconnect is not None:
            self._handle_reconnect(reconnect, data)
            return
        if pairing is None:
            # A pairing message arrived with no live session (e.g. the controller
            # dropped between frames). Nothing to drive; ignore it.
            return
        step = data.get("type")
        self._log(f"pairing step in: {step!r} (state={pairing.state.value})")
        try:
            if step == "pubkey":
                reveal = pairing.on_pubkey(data)
                self._send(pairing_envelope(STEP_REVEAL, reveal))
                self._log("pairing: sent reveal")
            elif step == "confirm-d":
                confirm_c = pairing.on_confirm_d(data)
                self._send(pairing_envelope(STEP_CONFIRM_C, confirm_c))
                # Confirmed: reveal our device key, then approve the app's.
                device_c = pairing.create_device_key()
                self._send(pairing_envelope(STEP_DEVICE_C, device_c))
            elif step == "device-key":
                pairing.on_peer_device_key(data)
                if pairing.state is PairingState.COMPLETED:
                    self._on_paired(pairing)
            else:
                self._log(f"pairing: ignoring unexpected step {step!r}")
        except PairingError as exc:
            self._log(f"pairing aborted: {exc.rejection.value}")
        except Exception as exc:  # noqa: BLE001 - diagnostic logging
            self._log(f"pairing UNEXPECTED error: {type(exc).__name__}: {exc}")

    def _handle_reconnect(
        self, handshake: ReconnectHandshake, data: dict[str, Any]
    ) -> None:
        """Drive the initiator side of the code-free reconnect. The host sent the
        hello in :meth:`_maybe_start_session`; here it verifies the app's response
        against the stored key and, on success, resumes the sealed channel."""
        step = data.get("type")
        self._log(f"reconnect step in: {step!r} (state={handshake.state.value})")
        try:
            if step == "reconnect-response":
                confirm = handshake.on_response(data)
                self._send(pairing_envelope(STEP_RECONNECT_CONFIRM, confirm))
                if handshake.authenticated:
                    self._on_reconnected(handshake)
            else:
                self._log(f"reconnect: ignoring unexpected step {step!r}")
        except ReconnectError as exc:
            self._log(f"reconnect aborted: {exc.rejection.value}")
        except Exception as exc:  # noqa: BLE001 - diagnostic logging
            self._log(f"reconnect UNEXPECTED error: {type(exc).__name__}: {exc}")

    def _on_paired(self, pairing: Pairing) -> None:
        channel_key = pairing.channel_key
        opener = CoworkFrameOpener(
            channel_key=channel_key,
            key_version=self._key_version,
            approved_devices=pairing.approved_devices,
        )
        sealer = CoworkFrameSealer(
            channel_key=channel_key,
            key_version=self._key_version,
            device_id=self._device_id,
            signing_identity=self._device_identity,  # host's own device identity
        )
        with self._session_lock:
            if self._pairing is not pairing:
                return  # a newer controller superseded this session mid-flight
            self._opener = opener
            self._sealer = sealer
            self._paired.set()
        self._log(f"paired with app device {pairing.peer_device_id}")
        # Persist the trust record so the next connection reconnects with no code.
        if self._on_pair_established is not None:
            try:
                self._on_pair_established(pairing)
            except Exception as exc:  # noqa: BLE001 - persistence must not crash the party
                self._log(f"could not persist pairing: {type(exc).__name__}: {exc}")

    def _on_reconnected(self, handshake: ReconnectHandshake) -> None:
        """Reset inbound state, retaining the shared outbound sequence for the
        stored channel key and all senders that outlived the socket."""
        with self._session_lock:
            if self._reconnect is not handshake:
                return  # superseded mid-flight
            channel_key = self._reconnect_channel_key
            approved = self._reconnect_approved
        if channel_key is None or approved is None:
            self._log("reconnect authenticated but stored trust was missing")
            return
        opener = CoworkFrameOpener(
            channel_key=channel_key,
            key_version=self._key_version,
            approved_devices=approved,
        )
        sealer = self._sealer or CoworkFrameSealer(
            channel_key=channel_key,
            key_version=self._key_version,
            device_id=self._device_id,
            signing_identity=self._device_identity,
        )
        with self._session_lock:
            if self._reconnect is not handshake:
                return
            self._opener = opener
            self._sealer = sealer
            self._paired.set()
        self._log(f"reconnected with app device {handshake.peer_device_id}")

    # -- provisioning + serving -----------------------------------------

    def _handle_frame(self, frame_b64: str) -> None:
        with self._session_lock:
            opener = self._opener
            sealer = self._sealer
            provisioned = self._provisioned
            task_server = self._task_server
        if opener is None or sealer is None:
            self._log("frame received before pairing completed; dropping")
            return
        if not provisioned:
            self._provision(frame_b64, opener, sealer)
            return
        if task_server is not None:
            task_server.submit(frame_b64)

    def _provision(
        self,
        frame_b64: str,
        opener: CoworkFrameOpener,
        sealer: CoworkFrameSealer,
    ) -> None:
        # The first sealed frame after pairing is the account token (§15 step 7).
        try:
            plaintext = opener.open(base64.b64decode(frame_b64))
        except (CoworkFrameRejected, ValueError) as exc:
            self._log(f"token frame rejected: {exc}")
            return
        try:
            token = json.loads(plaintext)
        except (ValueError, TypeError):
            self._log("token frame was not valid JSON")
            return
        if not isinstance(token, dict) or token.get("type") != "account_authentication":
            self._log(
                f"expected account_authentication, got {token.get('type')!r}"
            )
            return

        with self._session_lock:
            existing = self._task_server
        if existing is not None:
            # Re-provision (docs/WIRE_CONTRACT.md): the task server outlived the
            # previous socket. Give it this session's codec and refresh the
            # account tokens in place; queued and running work is untouched.
            try:
                existing.rebind(opener, sealer)
            except Exception as exc:
                self._log(f"could not rebind the task server: {type(exc).__name__}: {exc}")
                return
            reprovision = getattr(self, "_on_reprovision", None)
            if reprovision is not None:
                try:
                    reprovision(token)
                except Exception as exc:  # noqa: BLE001 — a refresh must not drop the session
                    self._log(f"re-provision hook failed: {type(exc).__name__}: {exc}")
            with self._session_lock:
                if self._opener is opener:
                    self._provisioned = True
            self._log("token re-provisioned; task server rebound to the new session")
            return

        try:
            task_server = self._build_task_server(opener, sealer, token, self)
            task_server.start()
        except Exception as exc:
            self._log(f"could not start task server: {type(exc).__name__}: {exc}")
            return
        # Only adopt it if this session is still current; otherwise discard it.
        stale = False
        with self._session_lock:
            if self._opener is opener and not self._provisioned:
                self._task_server = task_server
                self._provisioned = True
            else:
                stale = True
        if stale:
            task_server.stop()
            return
        self._log("token provisioned; ready to serve tasks")

    # -- outbound (used by the TaskServer result pump) -------------------

    def send_result_frame(self, frame_b64: str) -> None:
        """Emit one sealed result frame to the app over the relay.

        Dropped, not buffered, while no controller is attached: the relay would
        otherwise hold every frame of a long run for a peer that may never come
        back, and a late flush would fail the app's replay window anyway. The
        transcript is in the store; the app replays it on reconnect."""
        with self._session_lock:
            present = self._controller_present
        if not present:
            self.frames_dropped_while_away += 1
            return
        self._send(frame_envelope(frame_b64))
