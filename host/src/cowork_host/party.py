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


class HostParty:
    """Drives one relay connection: pairing initiator, then task bridge."""

    def __init__(
        self,
        *,
        url: str,
        pairing: Pairing,
        device_id: str,
        device_identity: Any,
        key_version: int,
        build_task_server: TaskServerBuilder,
        logger: Callable[[str], None] | None = None,
        open_timeout: float = 10.0,
    ) -> None:
        self._url = url
        self._pairing = pairing
        self._device_id = device_id
        self._device_identity = device_identity
        self._key_version = key_version
        self._build_task_server = build_task_server
        self._log = logger or (lambda _msg: None)
        self._open_timeout = open_timeout

        self._ws: Any | None = None
        self._ws_lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

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
        if self._task_server is not None:
            self._task_server.stop()
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
        return self._task_server

    def wait_paired(self, timeout: float | None = None) -> bool:
        return self._paired.wait(timeout)

    # -- run loop --------------------------------------------------------

    def _run(self) -> None:
        try:
            with ws_connect(self._url, open_timeout=self._open_timeout) as ws:
                self._ws = ws
                self._send(join_message(self._pairing.channel_id, ROLE_EXECUTOR))
                # Publish the commitment now. The relay holds it until the app joins.
                self._send(pairing_envelope(STEP_COMMIT, self._pairing.create_commit()))
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
            self._ws = None

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
        if kind == TYPE_PAIRING:
            self._handle_pairing(msg.get("data") or {})
        elif kind == TYPE_FRAME:
            frame_b64 = msg.get("frame")
            if isinstance(frame_b64, str):
                self._handle_frame(frame_b64)

    # -- pairing (initiator) --------------------------------------------

    def _handle_pairing(self, data: dict[str, Any]) -> None:
        pairing = self._pairing
        step = data.get("type")
        try:
            if step == "pubkey":
                reveal = pairing.on_pubkey(data)
                self._send(pairing_envelope(STEP_REVEAL, reveal))
            elif step == "confirm-d":
                confirm_c = pairing.on_confirm_d(data)
                self._send(pairing_envelope(STEP_CONFIRM_C, confirm_c))
                # Confirmed: reveal our device key, then approve the app's.
                device_c = pairing.create_device_key()
                self._send(pairing_envelope(STEP_DEVICE_C, device_c))
            elif step == "device-key":
                pairing.on_peer_device_key(data)
                if pairing.state is PairingState.COMPLETED:
                    self._on_paired()
            else:
                self._log(f"pairing: ignoring unexpected step {step!r}")
        except PairingError as exc:
            self._log(f"pairing aborted: {exc.rejection.value}")

    def _on_paired(self) -> None:
        channel_key = self._pairing.channel_key
        self._opener = CoworkFrameOpener(
            channel_key=channel_key,
            key_version=self._key_version,
            approved_devices=self._pairing.approved_devices,
        )
        self._sealer = CoworkFrameSealer(
            channel_key=channel_key,
            key_version=self._key_version,
            device_id=self._device_id,
            signing_identity=self._device_identity,  # host's own device identity
        )
        self._log(f"paired with app device {self._pairing.peer_device_id}")
        self._paired.set()

    # -- provisioning + serving -----------------------------------------

    def _handle_frame(self, frame_b64: str) -> None:
        if self._opener is None or self._sealer is None:
            self._log("frame received before pairing completed; dropping")
            return
        if not self._provisioned:
            self._provision(frame_b64)
            return
        assert self._task_server is not None
        self._task_server.submit(frame_b64)

    def _provision(self, frame_b64: str) -> None:
        # The first sealed frame after pairing is the account token (§15 step 7).
        try:
            plaintext = self._opener.open(base64.b64decode(frame_b64))
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
            self._task_server = self._build_task_server(
                self._opener, self._sealer, token, self
            )
            self._task_server.start()
        except Exception as exc:
            self._log(f"could not start task server: {type(exc).__name__}: {exc}")
            return
        self._provisioned = True
        self._log("token provisioned; ready to serve tasks")

    # -- outbound (used by the TaskServer result pump) -------------------

    def send_result_frame(self, frame_b64: str) -> None:
        """Emit one sealed result frame to the app over the relay."""
        self._send(frame_envelope(frame_b64))
