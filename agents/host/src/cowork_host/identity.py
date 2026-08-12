"""Persistent host device identity.

The host signs every frame it seals with one long-lived Ed25519 device key. That
key is what the app approves during pairing, so it must survive restarts — a new
key on every launch would break the app's local trust store. The private seed is
stored as base64 text in the workspace, readable only by the owner.
"""

from __future__ import annotations

import os
from pathlib import Path

from cowork_crypto import DeviceIdentity

# The stable device id the host presents at pairing and in every sealed frame.
HOST_DEVICE_ID = "cowork-host"


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
