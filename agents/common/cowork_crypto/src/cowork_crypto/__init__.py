"""cowork_crypto — the byte-identical Python twin of the Dart CoWork frame crypto.

Wire-compatible with ``lib/services/cowork/cowork_frame*.dart`` in chuk_chat.
See ``fixtures/test_vectors.json`` and the README for the cross-language
byte-compat contract.
"""

from .approved_devices import ApprovedDevices
from .channel_key import (
    CHANNEL_KEY_INFO,
    CHANNEL_KEY_LENGTH,
    derive_channel_key,
    generate_x25519_keypair,
)
from .device_keys import (
    FINGERPRINT_BYTES,
    PUBLIC_KEY_LENGTH,
    SEED_LENGTH,
    DeviceIdentity,
    fingerprint,
    public_key_from_base64,
)
from .frame import (
    FRAME_VERSION,
    MAC_LENGTH,
    NONCE_LENGTH,
    SIGNATURE_LENGTH,
    CoworkFrame,
    CoworkFrameRejected,
    CoworkFrameRejection,
    build_header_bytes,
    build_signed_bytes,
)
from .replay_guard import DEFAULT_WINDOW_MS, ReplayGuard
from .sealer import CoworkFrameOpener, CoworkFrameSealer, open, seal

__all__ = [
    "ApprovedDevices",
    "CHANNEL_KEY_INFO",
    "CHANNEL_KEY_LENGTH",
    "CoworkFrame",
    "CoworkFrameOpener",
    "CoworkFrameRejected",
    "CoworkFrameRejection",
    "CoworkFrameSealer",
    "DEFAULT_WINDOW_MS",
    "DeviceIdentity",
    "FINGERPRINT_BYTES",
    "FRAME_VERSION",
    "MAC_LENGTH",
    "NONCE_LENGTH",
    "PUBLIC_KEY_LENGTH",
    "ReplayGuard",
    "SEED_LENGTH",
    "SIGNATURE_LENGTH",
    "build_header_bytes",
    "build_signed_bytes",
    "derive_channel_key",
    "fingerprint",
    "generate_x25519_keypair",
    "open",
    "public_key_from_base64",
    "seal",
]
