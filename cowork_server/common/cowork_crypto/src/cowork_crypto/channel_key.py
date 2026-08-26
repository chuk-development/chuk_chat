"""CoWork channel key — established at pairing by X25519 ECDH.

Per §14 of the platform plan, the symmetric key that seals CoWork frames is a
**fresh CoWork channel key**, established at pairing between controller and
executor, **not** the chat account key. This avoids reproducing the account-key
derivation in Python and putting a password on a headless host, and decouples
CoWork crypto from chat crypto.

The channel key is a 32-byte AES-256 key. It is derived from the raw X25519 ECDH
shared secret with HKDF-SHA256 so the AES key is not the raw curve output.

## Cross-language contract (the Dart twin must match this exactly)

Given the controller X25519 private key and the executor X25519 public key (and
vice-versa on the other side), both peers compute the same channel key by:

1. ``shared = X25519(my_private, their_public)``            # 32 raw bytes
2. ``channel_key = HKDF-SHA256(ikm=shared, salt=b"", info=INFO, length=32)``

where ``INFO`` is the fixed ASCII bytes ``b"chuk.cowork.channel-key.v1"`` and the
HKDF salt is empty (32 zero bytes internally, per RFC 5869). Both peers derive
the identical key because X25519 ECDH is symmetric.
"""

from __future__ import annotations

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# HKDF ``info`` — domain separation for the channel key derivation. Bump the
# ``vN`` suffix only for a breaking change to the derivation.
CHANNEL_KEY_INFO = b"chuk.cowork.channel-key.v1"

# Channel key length in bytes (AES-256).
CHANNEL_KEY_LENGTH = 32


def derive_channel_key(
    my_x25519_private: X25519PrivateKey,
    their_x25519_public: X25519PublicKey,
) -> bytes:
    """Derive the 32-byte AES-256 CoWork channel key by X25519 ECDH + HKDF.

    Symmetric: the peer that swaps the arguments (its own private key, our public
    key) derives the identical key.
    """
    shared = my_x25519_private.exchange(their_x25519_public)
    return HKDF(
        algorithm=hashes.SHA256(),
        length=CHANNEL_KEY_LENGTH,
        salt=None,
        info=CHANNEL_KEY_INFO,
    ).derive(shared)


def generate_x25519_keypair() -> tuple[X25519PrivateKey, X25519PublicKey]:
    """Convenience for pairing and tests."""
    private = X25519PrivateKey.generate()
    return private, private.public_key()
