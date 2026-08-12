"""Persistent host device identity.

The host signs every frame it seals with one long-lived Ed25519 device key. That
key is what the app approves during pairing, so it must survive restarts — a new
key on every launch would break the app's local trust store. The private seed is
stored as base64 text in the workspace, readable only by the owner.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

from cowork_crypto import DeviceIdentity

# The stable device id the host presents at pairing and in every sealed frame.
HOST_DEVICE_ID = "cowork-host"

# Domain prefix for the deterministic channel-id derivation. Bump the ``vN``
# suffix only for a breaking change to how the channel id is computed.
_CHANNEL_ID_LABEL = b"cowork/host/channel-id/v1"

# Bytes of the SHA-256 digest folded into the hex channel id (8 -> 16 hex chars).
_CHANNEL_ID_BYTES = 8


def derive_channel_id(identity: DeviceIdentity) -> str:
    """The host's **stable** relay channel id, derived deterministically from its
    long-term Ed25519 public key.

    Deriving it from the persisted identity — rather than a fresh random value on
    each launch — is what lets the app find the same host again after a restart:
    the channel id it stored at pairing still routes. 16 lower-case hex chars,
    never containing ``'-'`` (so it is a valid pairing-code channel component)."""
    digest = hashlib.sha256(_CHANNEL_ID_LABEL + identity.public_key_bytes()).digest()
    return digest[:_CHANNEL_ID_BYTES].hex()


def load_or_create_identity(seed_path: Path) -> DeviceIdentity:
    """Load the host's Ed25519 identity from ``seed_path``, or create + persist it."""
    if seed_path.exists():
        seed_b64 = seed_path.read_text(encoding="ascii").strip()
        return DeviceIdentity.from_seed_base64(seed_b64)
    identity = DeviceIdentity.generate()
    seed_path.parent.mkdir(parents=True, exist_ok=True)
    # 0600: the seed is a private key. Never logged, synced, or sent to the relay.
    fd = os.open(str(seed_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as handle:
        handle.write(identity.export_private_seed_base64())
    return identity
