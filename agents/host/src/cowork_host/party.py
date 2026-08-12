"""The host party — the pairing initiator and the app's counterpart.

This is the host's own end of the local relay. It connects to the blind relay as
the ``executor`` role, drives the §15 pairing ceremony as the **initiator**, and
then serves tasks:

1. **pair** — publish the commitment, reveal ``A`` after the joiner's ``B``,
   confirm keys, exchange device keys. On success it holds the channel key and
   the app's approved device key.
2. **provision** — open the first sealed frame (``account_authentication``),
   build the model factory from the token, and start the :class:`TaskServer`.
3. **serve** — forward every later sealed frame to the Executor and stream its
   sealed results back to the app.

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
    CoworkFrameOpener,
    CoworkFrameRejected,
    CoworkFrameSealer,
    Pairing,
    PairingError,
    PairingState,
)
from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect as ws_connect

from .protocol import (
    ROLE_EXECUTOR,
    STEP_COMMIT,
    STEP_CONFIRM_C,
    STEP_DEVICE_C,
    STEP_REVEAL,
    TYPE_FRAME,
    TYPE_PAIRING,
    frame_envelope,
    join_message,
    pairing_envelope,
)
from .serve import TaskServer

# Builds a TaskServer once the token is provisioned. Given the shared opener,
# sealer, and the decoded token dict, it wires and returns a ready TaskServer.
TaskServerBuilder = Callable[
    [CoworkFrameOpener, CoworkFrameSealer, dict, "HostParty"], TaskServer
]

# Mints a fresh pairing *initiator* session — new ephemeral keys and a new
# expiry, but the SAME printed channel id + digits. Called once per controller
# connection so every pairing attempt (including a reconnect) is valid and
# unconsumed, while the code the user reads off the screen never changes.
PairingFactory = Callable[[], Pairing]

# Reports the token of a controller already on the channel, or ``None``. Lets the
# party pick up a controller that connected before its own executor link came up.
ControllerToken = Callable[[], int | None]


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
        url: str,
        channel_id: str,
        pairing_factory: PairingFactory,
        device_id: str,
        device_identity: Any,
        key_version: int,
        build_task_server: TaskServerBuilder,
        logger: Callable[[str], None] | None = None,
        open_timeout: float = 10.0,
        controller_token: ControllerToken | None = None,
    ) -> None:
        self._url = url
        self._channel_id = channel_id
        self._pairing_factory = pairing_factory
        self._device_id = device_id
        self._device_identity = device_identity
        self._key_version = key_version
        self._build_task_server = build_task_server
        self._log = logger or (lambda _msg: None)
        self._open_timeout = open_timeout
        self._controller_token = controller_token

        self._ws: Any | None = None
        self._ws_lock = threading.Lock()
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
        self._opener: CoworkFrameOpener | None = None
        self._sealer: CoworkFrameSealer | None = None
        self._task_server: TaskServer | None = None
        self._provisioned = False
        self._paired = threading.Event()

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
        with self._ws_lock:
            if self._ws is not None:
                try:
                    self._ws.close()
                except Exception:
                    pass
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

    def on_controller_joined(self, token: int) -> None:
        """A controller connected. Remember it and start a session if we can."""
        with self._session_lock:
            self._active_token = token
        self._maybe_start_session()

    def on_controller_left(self, token: int) -> None:
        """The controller for ``token`` dropped. Reset so the next one pairs
        cleanly. A stale leave from a superseded connection is ignored."""
        task_server = None
        with self._session_lock:
            if self._active_token != token:
                return
            self._active_token = None
            self._started_token = None
            task_server = self._reset_session_locked()
        if task_server is not None:
            task_server.stop()
        self._log("controller disconnected; pairing session reset")

    def _reset_session_locked(self) -> TaskServer | None:
        """Clear per-session state. Returns any task server to stop OUTSIDE the
        lock (stopping it can block on the supervisor)."""
        task_server = self._task_server
        self._task_server = None
        self._pairing = None
        self._opener = None
        self._sealer = None
        self._provisioned = False
        self._paired = threading.Event()
        return task_server

    def _maybe_start_session(self) -> None:
        """Publish a fresh commit for the pending controller, once — but only when
        the executor link is up and we have not already committed for it."""
        old_task_server = None
        commit = None
        with self._session_lock:
            token = self._active_token
            if not self._ws_ready or token is None or self._started_token == token:
                return
            old_task_server = self._reset_session_locked()
            pairing = self._pairing_factory()
            self._pairing = pairing
            commit = pairing.create_commit()
            self._started_token = token
        if old_task_server is not None:
            old_task_server.stop()
        self._log("controller connected; publishing a fresh pairing commit")
        self._send(pairing_envelope(STEP_COMMIT, commit))

    # -- run loop --------------------------------------------------------

    def _run(self) -> None:
        try:
            with ws_connect(self._url, open_timeout=self._open_timeout) as ws:
                with self._ws_lock:
                    self._ws = ws
                self._send(join_message(self._channel_id, ROLE_EXECUTOR))
                self._on_ws_ready()
                self._log("waiting for the app to pair...")
                for raw in ws:
                    if self._stop.is_set():
                        break
                    self._handle(raw)
        except ConnectionClosed:
            pass
        except Exception as exc:  # never crash the process on a party failure
            self._log(f"party stopped: {type(exc).__name__}: {exc}")
        finally:
            with self._session_lock:
                self._ws_ready = False
                self._started_token = None
            with self._ws_lock:
                self._ws = None

    def _on_ws_ready(self) -> None:
        """The executor link is up. If a controller is already waiting on the
        channel, adopt it now; otherwise a later ``join`` event will."""
        with self._session_lock:
            self._ws_ready = True
        token = self._controller_token() if self._controller_token else None
        if token is not None:
            self.on_controller_joined(token)

    def _send(self, obj: dict[str, Any]) -> None:
        with self._ws_lock:
            if self._ws is not None:
                self._ws.send(json.dumps(obj, separators=(",", ":")))

    def _handle(self, raw: Any) -> None:
        try:
            msg = json.loads(raw)
        except (ValueError, TypeError):
            return
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
        """Emit one sealed result frame to the app over the relay."""
        self._send(frame_envelope(frame_b64))
