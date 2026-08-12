"""The executor's **local** set of device public keys it will accept frames
from — the CoWork trust boundary. Python twin of ``CoworkApprovedDevices``.

A device's approval state also lives in Supabase, which is *not* end-to-end
encrypted: the backend can read it and, if compromised, write it. So the
server's copy is a UX convenience and a first-line filter, and **this** — a set
of keys the executor recorded itself, after a local human approval — is what
actually authorises a frame.

Default deny: an empty store rejects every frame. There is no fallback to "the
server says this device is fine".

Mirrors ``cowork_approved_devices.dart``.
"""

from __future__ import annotations

import base64
import hmac

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from .device_keys import PUBLIC_KEY_LENGTH, public_key_from_base64


class ApprovedDevices:
    def __init__(self, approved: dict[str, Ed25519PublicKey] | None = None):
        self._approved: dict[str, Ed25519PublicKey] = dict(approved or {})

    @classmethod
    def empty(cls) -> ApprovedDevices:
        """An empty store. Rejects everything until something is approved."""
        return cls()

    @classmethod
    def from_base64_map(cls, entries: dict[str, str]) -> ApprovedDevices:
        """Restore a store from persisted ``deviceId -> base64 public key``
        entries. Raises ``ValueError`` if any entry is not a valid Ed25519 key,
        rather than silently dropping it. Mirrors ``fromBase64Map``."""
        approved = {
            device_id: public_key_from_base64(encoded)
            for device_id, encoded in entries.items()
        }
        return cls(approved)

    @property
    def is_empty(self) -> bool:
        return len(self._approved) == 0

    def __len__(self) -> int:
        return len(self._approved)

    @property
    def device_ids(self) -> set[str]:
        return set(self._approved.keys())

    def lookup(self, device_id: str) -> Ed25519PublicKey | None:
        """The approved key for ``device_id``, or ``None`` if never approved.
        None means reject — never "ask the server"."""
        return self._approved.get(device_id)

    def is_approved(self, device_id: str) -> bool:
        return device_id in self._approved

    def approve(self, device_id: str, public_key: Ed25519PublicKey) -> None:
        """Record a local human approval of ``device_id`` holding ``public_key``.

        Re-approving the same device with a *different* key raises
        ``ValueError``. Silently overwriting would turn any code path that can
        call ``approve`` into a key-substitution primitive; swapping a device's
        key must go through an explicit :meth:`revoke`. Mirrors ``approve``."""
        if device_id == "":
            raise ValueError("deviceId must not be empty")
        raw = public_key.public_bytes_raw()
        if len(raw) != PUBLIC_KEY_LENGTH:
            raise ValueError(f"publicKey must be a {PUBLIC_KEY_LENGTH}-byte Ed25519 key")
        existing = self._approved.get(device_id)
        if existing is not None and not _same_key(existing, public_key):
            raise ValueError(
                f"Device {device_id} is already approved with a different key. "
                "Revoke it before approving a new key."
            )
        self._approved[device_id] = public_key

    def revoke(self, device_id: str) -> bool:
        """Remove ``device_id``. Returns True if it had been approved. Kill
        switch #1: after this returns, every frame from that device is rejected,
        with no server round-trip. Mirrors ``revoke``."""
        return self._approved.pop(device_id, None) is not None

    def revoke_all(self) -> None:
        """Remove every device — the tray "panic" wipe. Mirrors ``revokeAll``."""
        self._approved.clear()

    def to_base64_map(self) -> dict[str, str]:
        """Persistable snapshot: ``deviceId -> base64 public key``."""
        return {
            device_id: base64.b64encode(pk.public_bytes_raw()).decode("ascii")
            for device_id, pk in self._approved.items()
        }


def _same_key(a: Ed25519PublicKey, b: Ed25519PublicKey) -> bool:
    return hmac.compare_digest(a.public_bytes_raw(), b.public_bytes_raw())
