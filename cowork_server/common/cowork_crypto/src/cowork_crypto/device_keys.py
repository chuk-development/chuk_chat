"""Per-device Ed25519 identity — the Python twin of the Dart ``CoworkDeviceKeys``.

Each device generates one long-lived signing key at first launch and signs
every frame it sends with it. Per-device keys make revocation real: pulling one
device's public key out of the executor's local approved set instantly and
permanently stops that device, with no server cooperation required.

Mirrors ``cowork_device_keys.dart``.
"""

from __future__ import annotations

import base64
import hashlib

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

# Ed25519 seed length in bytes — what ``export_private_seed`` returns.
SEED_LENGTH = 32

# Ed25519 public key length in bytes.
PUBLIC_KEY_LENGTH = 32

# Bytes of the SHA-256 digest shown in a fingerprint. 10 bytes = 80 bits.
# A security parameter, not cosmetic: an 80-bit fingerprint needs ~2^40 work for
# a second preimage, out of reach for a compromised backend grinding a substitute
# key that displays the same string. Mirrors ``fingerprintBytes`` in
# cowork_device_keys.dart:90.
FINGERPRINT_BYTES = 10


class DeviceIdentity:
    """A device's Ed25519 signing key pair.

    Pure helper: it generates, seeds, serialises and signs. Where the private
    seed is persisted and where public keys are distributed are somebody else's
    problem — exactly as in the Dart class.
    """

    def __init__(self, private_key: Ed25519PrivateKey):
        self._private_key = private_key
        self._public_key = private_key.public_key()

    # --- construction --------------------------------------------------------

    @classmethod
    def generate(cls) -> DeviceIdentity:
        """Generate a fresh device signing key. Mirrors ``generate``."""
        return cls(Ed25519PrivateKey.generate())

    @classmethod
    def from_seed(cls, seed: bytes) -> DeviceIdentity:
        """Rebuild a key pair from a stored 32-byte seed. Mirrors ``fromSeed``."""
        if len(seed) != SEED_LENGTH:
            raise ValueError(f"Ed25519 seed must be {SEED_LENGTH} bytes, got {len(seed)}")
        return cls(Ed25519PrivateKey.from_private_bytes(seed))

    @classmethod
    def from_seed_base64(cls, seed_b64: str) -> DeviceIdentity:
        """Rebuild a key pair from a base64 seed. Mirrors ``fromSeedBase64``."""
        return cls.from_seed(_decode_base64(seed_b64, "seed"))

    # --- serialisation -------------------------------------------------------

    def export_private_seed(self) -> bytes:
        """The private seed. Persist in secure storage and nowhere else — never
        logged, synced, or sent to the relay. Mirrors ``exportPrivateKeySeed``."""
        return self._private_key.private_bytes_raw()

    def export_private_seed_base64(self) -> str:
        return base64.b64encode(self.export_private_seed()).decode("ascii")

    def public_key_bytes(self) -> bytes:
        return self._public_key.public_bytes_raw()

    def export_public_key_base64(self) -> str:
        """The public key, safe to publish. Mirrors ``exportPublicKeyBase64``."""
        return base64.b64encode(self.public_key_bytes()).decode("ascii")

    @property
    def public_key(self) -> Ed25519PublicKey:
        return self._public_key

    # --- signing -------------------------------------------------------------

    def sign(self, data: bytes) -> bytes:
        return self._private_key.sign(data)

    # --- fingerprint ---------------------------------------------------------

    def fingerprint(self) -> str:
        return fingerprint(self.public_key_bytes())


def public_key_from_base64(encoded: str) -> Ed25519PublicKey:
    """Parse a peer public key. Raises ``ValueError`` on anything that is not a
    32-byte base64 Ed25519 key, so a malformed or hostile row cannot become a
    trusted key. Mirrors ``publicKeyFromBase64`` in cowork_device_keys.dart:71."""
    raw = _decode_base64(encoded, "public key")
    if len(raw) != PUBLIC_KEY_LENGTH:
        raise ValueError(
            f"Ed25519 public key must be {PUBLIC_KEY_LENGTH} bytes, got {len(raw)}"
        )
    return Ed25519PublicKey.from_public_bytes(raw)


def fingerprint(public_key_bytes: bytes) -> str:
    """A human-comparable fingerprint of a public key, e.g.
    ``4F2A-9C31-88B0-1D5E-A7C4``.

    SHA-256 of the raw public key bytes, first 10 bytes, upper-case hex, grouped
    in 4-character chunks joined by ``-``. Mirrors ``fingerprint`` in
    cowork_device_keys.dart:96.
    """
    digest = hashlib.sha256(public_key_bytes).digest()
    hex_str = digest[:FINGERPRINT_BYTES].hex().upper()
    groups = [hex_str[i : i + 4] for i in range(0, len(hex_str), 4)]
    return "-".join(groups)


def _decode_base64(value: str, label: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ValueError(f"Invalid base64 {label}")
