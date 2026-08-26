"""Persistent host trust record — what makes a pairing survive restarts.

After the first §15 pairing completes, the host writes one JSON file
(``paired.json``) under its workspace holding everything it needs to reconnect
to the *same* app without a new code:

- the stable ``channel_id`` the app finds the host on,
- the established 32-byte channel key (base64), reused verbatim by the frame
  codec, and
- the peer (app) ``device_id`` + approved Ed25519 public key (base64).

The host's own long-term Ed25519 seed is **not** in here — it lives in
``host_device.key`` (see :mod:`cowork_host.identity`) and is loaded separately.
Splitting them keeps the private seed in its own ``0600`` file and this record
free of any secret the app does not already hold.

The file is written ``0600``: the channel key is symmetric key material.
"""

from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass
from pathlib import Path

from cowork_crypto import ApprovedDevices, public_key_from_base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

TRUST_VERSION = 1


@dataclass(frozen=True)
class HostTrust:
    """One persisted pairing: the stable channel, the channel key, and the app's
    approved device key. Everything the host needs to reconnect with no code."""

    channel_id: str
    channel_key: bytes
    peer_device_id: str
    peer_public_key: Ed25519PublicKey

    def approved_devices(self) -> ApprovedDevices:
        """A default-deny trust store holding exactly the paired app's key, ready
        to hand to a :class:`CoworkFrameOpener`."""
        store = ApprovedDevices.empty()
        store.approve(self.peer_device_id, self.peer_public_key)
        return store


class HostPairingStore:
    """Loads and saves the host's single :class:`HostTrust` as ``paired.json``."""

    def __init__(self, path: Path) -> None:
        self._path = Path(path)

    @property
    def path(self) -> Path:
        return self._path

    def load(self) -> HostTrust | None:
        """Return the stored trust, or ``None`` when there is none / it is
        unreadable. A corrupt or partial file is treated as *no pairing* (the
        host falls back to printing a fresh code) rather than crashing."""
        if not self._path.exists():
            return None
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            return None
        if not isinstance(data, dict) or data.get("version") != TRUST_VERSION:
            return None
        try:
            channel_id = data["channel_id"]
            channel_key = base64.b64decode(data["channel_key_b64"], validate=True)
            peer = data["peer"]
            peer_device_id = peer["device_id"]
            peer_public_key = public_key_from_base64(peer["ed25519_pub_b64"])
        except (KeyError, TypeError, ValueError):
            return None
        if not isinstance(channel_id, str) or not channel_id:
            return None
        if not isinstance(peer_device_id, str) or not peer_device_id:
            return None
        if len(channel_key) != 32:
            return None
        return HostTrust(
            channel_id=channel_id,
            channel_key=channel_key,
            peer_device_id=peer_device_id,
            peer_public_key=peer_public_key,
        )

    def save(self, trust: HostTrust) -> None:
        """Write the trust record atomically with ``0600`` permissions."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": TRUST_VERSION,
            "channel_id": trust.channel_id,
            "channel_key_b64": base64.b64encode(trust.channel_key).decode("ascii"),
            "peer": {
                "device_id": trust.peer_device_id,
                "ed25519_pub_b64": base64.b64encode(
                    trust.peer_public_key.public_bytes_raw()
                ).decode("ascii"),
            },
        }
        tmp = self._path.with_suffix(self._path.suffix + ".tmp")
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"))
        os.replace(tmp, self._path)

    def clear(self) -> bool:
        """Delete the stored trust (the "un-pair / forget" action). Returns True
        if a record was removed."""
        try:
            self._path.unlink()
            return True
        except FileNotFoundError:
            return False
