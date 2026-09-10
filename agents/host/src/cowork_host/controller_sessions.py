"""Independent, authenticated controller sessions for one paired host.

The encrypted account pairing is a recovery capability. A new account device
must prove possession of that capability AND its own signing key, against a
fresh host challenge. No private device key is copied between installations.
Each connection derives its own traffic key, so reconnecting one controller
cannot reset another controller's replay guard or read its previous frames.
"""

from __future__ import annotations

import base64
import hmac
import json
import secrets
import threading
import time
from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cowork_crypto import ApprovedDevices, CoworkFrameOpener, CoworkFrameSealer
from cowork_crypto.frame import CoworkFrame, CoworkFrameRejected, CoworkFrameRejection


def b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def unb64(value: str, length: int) -> bytes:
    result = base64.b64decode(value, validate=True)
    if len(result) != length:
        raise ValueError("invalid proof length")
    return result


def transcript(channel: str, device: str, public: str, client: str, host: str) -> bytes:
    return json.dumps(
        [channel, device, public, client, host],
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode()


def mac(key: bytes, label: str, message: bytes) -> bytes:
    return hmac.digest(key, label.encode() + message, "sha256")


@dataclass
class Session:
    connection: str
    opener: CoworkFrameOpener
    sealer: CoworkFrameSealer


@dataclass
class OutboundBatch:
    frames: list[dict]
    broadcast: bool

    def to_bytes(self) -> bytes:
        # In-process carrier only. send_result_frame unwraps this before the
        # relay; every enclosed frame is already signed and encrypted.
        return json.dumps(
            {"controller_frames": self.frames, "broadcast": self.broadcast}
        ).encode()


class ControllerSessions:
    def __init__(self, trust, identity, host_device_id: str):
        self.trust = trust
        self.identity = identity
        self.host_device_id = host_device_id
        self.pending: dict[str, tuple[float, dict, bytes]] = {}
        self.sessions: dict[str, Session] = {}
        self.lock = threading.RLock()

    def challenge(self, message: dict) -> dict:
        if message.get("channel") != self.trust.channel_id:
            raise ValueError("wrong channel")
        device = message["device_id"]
        if not isinstance(device, str) or not 1 <= len(device) <= 128:
            raise ValueError("invalid device")
        public = message["public_key"]
        client = message["client_nonce"]
        unb64(public, 32)
        unb64(client, 32)
        host = b64(secrets.token_bytes(32))
        connection = secrets.token_hex(16)
        signed = transcript(self.trust.channel_id, device, public, client, host)
        with self.lock:
            now = time.monotonic()
            self.pending = {k: v for k, v in self.pending.items() if now - v[0] < 30}
            if len(self.pending) >= 32:
                raise ValueError("too many pending controllers")
            self.pending[connection] = (now, dict(message), signed)
        return {
            "type": "controller_challenge",
            "device_id": device,
            "client_nonce": client,
            "host_nonce": host,
            "connection": connection,
            "signature": b64(self.identity.sign(b"cowork/controller/host/" + signed)),
        }

    def confirm(self, message: dict) -> dict:
        connection = message["connection"]
        with self.lock:
            pending = self.pending.pop(connection, None)
            if pending is None or time.monotonic() - pending[0] >= 30:
                raise ValueError("expired challenge")
            _, request, signed = pending
            proof = unb64(message["proof"], 32)
            if not hmac.compare_digest(
                proof, mac(self.trust.channel_key, "cowork/controller/approve/", signed)
            ):
                raise ValueError("invalid recovery capability")
            key = Ed25519PublicKey.from_public_bytes(unb64(request["public_key"], 32))
            key.verify(
                unb64(message["signature"], 64), b"cowork/controller/device/" + signed
            )
            device = request["device_id"]
            if device not in self.sessions and len(self.sessions) >= 16:
                raise ValueError("too many controllers")
            traffic_key = mac(
                self.trust.channel_key, "cowork/controller/traffic/", signed
            )
            approved = ApprovedDevices.empty()
            approved.approve(device, key)
            self.sessions[device] = Session(
                connection,
                CoworkFrameOpener(
                    channel_key=traffic_key, key_version=1, approved_devices=approved
                ),
                CoworkFrameSealer(
                    channel_key=traffic_key,
                    key_version=1,
                    device_id=self.host_device_id,
                    signing_identity=self.identity,
                ),
            )
        return {
            "type": "controller_ready",
            "connection": connection,
            "proof": b64(mac(traffic_key, "cowork/controller/ready/", signed)),
        }

    def open(self, frame) -> bytes:
        parsed = CoworkFrame.from_bytes(frame) if isinstance(frame, bytes) else frame
        with self.lock:
            session = self.sessions.get(parsed.device_id)
            if session is None:
                raise CoworkFrameRejected(CoworkFrameRejection.DEVICE_NOT_APPROVED)
            return session.opener.open(parsed)

    def seal(self, plaintext: bytes) -> OutboundBatch:
        payload = json.loads(plaintext)
        with self.lock:
            frames = [
                {
                    "device_id": device,
                    "connection": session.connection,
                    "frame": b64(session.sealer.seal(plaintext).to_bytes()),
                }
                for device, session in self.sessions.items()
            ]
        return OutboundBatch(frames, payload.get("type") == "agent_list")
