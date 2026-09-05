"""The at-rest key for the host's secret vault (docs/WIRE_CONTRACT.md, "Secrets").

The vault file (``~/.cowork/secrets.enc``) is AES-256-GCM. Its key is not a
second file to protect: it is derived from the host's long-term Ed25519 seed
(``host_device.key``, already ``0600``) with HKDF under a fixed label, so the
one secret the host already keeps is the only secret it keeps. Re-pairing
does not change the identity, so the vault survives it; deleting
``host_device.key`` makes the vault unreadable, which is the right outcome
for "this host is no longer mine".
"""

from __future__ import annotations

from cowork_crypto import DeviceIdentity
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# Bump the ``vN`` only for a breaking change to the derivation. An old vault
# file then no longer opens and is replaced by the next ``secrets`` frame.
_LABEL = b"cowork/host/secrets-at-rest/v1"
KEY_LEN = 32


def secrets_at_rest_key(identity: DeviceIdentity) -> bytes:
    """32 bytes for AES-256-GCM, derived from the identity's private seed."""
    return HKDF(
        algorithm=hashes.SHA256(), length=KEY_LEN, salt=None, info=_LABEL
    ).derive(identity.export_private_seed())
