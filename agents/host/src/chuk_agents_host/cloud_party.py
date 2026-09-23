"""One executor shared by independently authenticated cloud controllers."""

from __future__ import annotations

import base64
import json

from chuk_agents_crypto.frame import AgentsFrame
from chuk_agents_crypto.frame import AgentsFrameRejected, AgentsFrameRejection
from .controller_sessions import ControllerSessions
from .party import HostParty


class CloudHostParty(HostParty):
    def __init__(self, *, trust_provider, **kwargs):
        super().__init__(**kwargs)
        self._trust_provider = trust_provider
        self._controllers: ControllerSessions | None = None

    def on_controller_joined(self, token):
        # Once independently authenticated controllers are active, a relay
        # reconnect must not reset the executor or another controller's codec.
        if self._controllers is not None and self._controllers.sessions:
            return
        super().on_controller_joined(token)

    def _sessions(self) -> ControllerSessions:
        if self._controllers is None:
            trust = self._trust_provider()
            if trust is None:
                raise ValueError("host must be paired before account recovery")
            self._controllers = ControllerSessions(
                trust, self._device_identity, self._device_id
            )
        return self._controllers

    def _handle(self, message):
        kind = message.get("type")
        if kind not in ("controller_resume", "controller_proof", "controller_frame"):
            if self._controllers is not None and self._controllers.sessions:
                return
            # Existing first-pairing ceremony remains supported.
            return super()._handle(message)
        try:
            sessions = self._sessions()
            if kind == "controller_resume":
                self._send(sessions.challenge(message))
            elif kind == "controller_proof":
                ready = sessions.confirm(message)
                self._controller_present = True
                self._paired.set()
                self._send(ready)
            else:
                wire = message.get("frame")
                if not isinstance(wire, str):
                    return
                raw = base64.b64decode(wire, validate=True)
                frame = AgentsFrame.from_bytes(raw)
                # Authenticate here, then issue a private one-use ticket for the
                # existing executor input boundary. The shared executor's Stop,
                # approvals and run ownership work across all controllers.
                plaintext = sessions.open(frame)
                payload = json.loads(plaintext)
                if payload.get("type") == "controller_close":
                    with sessions.lock:
                        sessions.sessions.pop(frame.device_id, None)
                    self._controller_present = bool(sessions.sessions)
                    return
                if payload.get("type") == "account_authentication":
                    if self._task_server is None:
                        # Inbound frames have already been opened once; the
                        # executor receives a one-use in-process plaintext ticket.
                        self._opener = _OpenedFrames()
                        self._sealer = sessions
                        server = self._build_task_server(
                            self._opener, sessions, payload, self
                        )
                        server.start()
                        self._task_server = server
                    else:
                        if not isinstance(self._opener, _OpenedFrames):
                            self._opener = _OpenedFrames()
                            self._sealer = sessions
                            self._task_server.rebind(self._opener, sessions)
                        if self._on_reprovision is not None:
                            self._on_reprovision(payload)
                    self._provisioned = True
                    return
                if self._task_server is not None and isinstance(
                    self._opener, _OpenedFrames
                ):
                    ticket = self._opener.put(plaintext)
                    self._task_server.submit(ticket, controller_device=frame.device_id)
        except Exception as exc:
            # No keys, proof bytes, account fields or message contents in logs.
            self._log(f"controller session rejected: {type(exc).__name__}")

    def send_result_frame(self, frame_b64: str) -> None:
        self.send_routed_result(frame_b64, None)

    def send_routed_result(self, frame_b64: str, device: str | None) -> None:
        try:
            batch = json.loads(base64.b64decode(frame_b64))
        except (ValueError, UnicodeDecodeError):
            return super().send_result_frame(frame_b64)
        if "controller_frames" not in batch:
            return super().send_result_frame(frame_b64)
        for entry in batch["controller_frames"]:
            if device is None or batch["broadcast"] or entry["device_id"] == device:
                self._send(
                    {
                        "type": "controller_frame",
                        "connection": entry["connection"],
                        "frame": entry["frame"],
                    }
                )


class _OpenedFrames:
    """One-use process-local tickets after ControllerSessions verified a frame.

    These never travel over the network; only the private Executor loopback
    receives them. Random tickets prevent an external wire frame masquerading
    as already authenticated data.
    """

    def __init__(self):
        import threading

        self._lock = threading.Lock()
        self._pending = {}

    def put(self, plaintext):
        import secrets

        ticket = secrets.token_bytes(32)
        with self._lock:
            if len(self._pending) >= 1024:
                raise ValueError("executor input queue full")
            self._pending[ticket] = plaintext
        return base64.b64encode(ticket).decode()

    def open(self, raw):
        with self._lock:
            result = self._pending.pop(raw, None)
        if result is None:
            raise AgentsFrameRejected(AgentsFrameRejection.DEVICE_NOT_APPROVED)
        return result
