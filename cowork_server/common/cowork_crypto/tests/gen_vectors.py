"""Regenerate ``fixtures/test_vectors.json``.

Run with:  uv run python tests/gen_vectors.py

This produces a deterministic, documented cross-language test vector: fixed key
material + fixed inputs -> the exact expected frame bytes. A Dart test on the
chuk_chat side must feed the same inputs to ``CoworkFrameSealer`` and confirm it
produces byte-identical ``header``, ``signed`` and ``frame_json`` output, then
open it back to the plaintext. See the README for the contract.

Determinism comes from a fixed Ed25519 seed, a fixed channel key, a fixed nonce,
a fixed ``seq``/``ts``/``device_id``/``kv`` and a fixed plaintext. Ed25519 is
deterministic (RFC 8032), so the signature is reproducible with no RNG.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

from cowork_crypto import (
    CoworkFrameSealer,
    DeviceIdentity,
    build_header_bytes,
    build_signed_bytes,
)

# --- fixed inputs (do not change without regenerating and updating the Dart test) ---

# 32-byte Ed25519 seed: bytes 0x00..0x1f.
ED25519_SEED = bytes(range(32))
# 32-byte AES-256 channel key: bytes 0x40..0x5f.
CHANNEL_KEY = bytes(range(0x40, 0x60))
# 12-byte AES-GCM nonce: bytes 0xA0..0xAB.
NONCE = bytes(range(0xA0, 0xAC))

DEVICE_ID = "executor-laptop-01"
KEY_VERSION = 1
SEQ = 7
TS = 1_723_478_400_000  # 2024-08-12T16:00:00Z, fixed
PLAINTEXT = b'{"jsonrpc":"2.0","method":"run","id":"42"}'


def build() -> dict:
    identity = DeviceIdentity.from_seed(ED25519_SEED)

    sealer = CoworkFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        device_id=DEVICE_ID,
        signing_identity=identity,
        next_seq=SEQ,
        now_ms=lambda: TS,
        rand=lambda n: NONCE[:n],
    )
    frame = sealer.seal(PLAINTEXT)

    header = build_header_bytes(
        version=frame.version,
        key_version=frame.key_version,
        device_id=frame.device_id,
        seq=frame.seq,
        ts=frame.ts,
    )
    signed = build_signed_bytes(
        header=header, nonce=frame.nonce, ciphertext=frame.ciphertext
    )

    def b64(b: bytes) -> str:
        return base64.b64encode(b).decode("ascii")

    return {
        "_comment": (
            "Cross-language byte-compat vector for CoWork frame crypto. "
            "The Dart CoworkFrameSealer, fed these exact inputs, MUST produce "
            "byte-identical header_b64, signed_b64 and frame_json, and open it "
            "back to plaintext_utf8. AES-GCM uses the header as AAD; Ed25519 "
            "signs signed_b64; ciphertext = cipher||16-byte tag."
        ),
        "inputs": {
            "ed25519_seed_b64": b64(ED25519_SEED),
            "ed25519_public_b64": identity.export_public_key_base64(),
            "fingerprint": identity.fingerprint(),
            "channel_key_b64": b64(CHANNEL_KEY),
            "nonce_b64": b64(NONCE),
            "device_id": DEVICE_ID,
            "key_version": KEY_VERSION,
            "seq": SEQ,
            "ts": TS,
            "plaintext_utf8": PLAINTEXT.decode("utf-8"),
        },
        "expected": {
            "header_b64": b64(header),
            "signed_b64": b64(signed),
            "nonce_b64": b64(frame.nonce),
            "ciphertext_b64": b64(frame.ciphertext),
            "sig_b64": b64(frame.sig),
            "frame_json": frame.to_json_string(),
        },
    }


def main() -> None:
    out = build()
    path = Path(__file__).parent / "fixtures" / "test_vectors.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
