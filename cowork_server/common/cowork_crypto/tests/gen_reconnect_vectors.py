"""Regenerate ``fixtures/reconnect_vectors.json`` — the cross-language reconnect
handshake vector shared with the Dart twin.

Run with:  uv run python tests/gen_reconnect_vectors.py

Determinism: fixed Ed25519 device seeds for both sides, a fixed channel id and
fixed 32-byte nonces for each side. Ed25519 is deterministic from its private
bytes (RFC 8032), so both signed proofs are reproducible with no RNG. The Dart
reconnect twin, fed the same inputs, MUST reproduce every ``expected`` byte
string.

After running, copy the fixture into the app test tree:
    cp tests/fixtures/reconnect_vectors.json \\
       ../../app/test/fixtures/cowork_reconnect_vectors.json
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

from cowork_crypto import DeviceIdentity, ReconnectHandshake
from cowork_crypto.reconnect import (
    RECONNECT_I_LABEL,
    RECONNECT_J_LABEL,
    reconnect_signed_bytes,
    reconnect_transcript,
)

# --- fixed inputs (do not change without regenerating and updating Dart) -----

# 32-byte Ed25519 device seeds (distinct from the pairing-vector seeds).
INITIATOR_ED_SEED = bytes(range(0x20, 0x40))  # 0x20..0x3f
JOINER_ED_SEED = bytes(range(0xA0, 0xC0))  # 0xa0..0xbf

# 32-byte reconnect nonces.
INITIATOR_NONCE = bytes(range(0x01, 0x21))  # 0x01..0x20
JOINER_NONCE = bytes(range(0x40, 0x60))  # 0x40..0x5f

CHANNEL_ID = "cowork00deadbeef"  # 16 hex chars, no '-'
INITIATOR_DEVICE_ID = "cowork-host"
JOINER_DEVICE_ID = "desktop-flutter-01"


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def build() -> dict:
    init_id = DeviceIdentity.from_seed(INITIATOR_ED_SEED)
    join_id = DeviceIdentity.from_seed(JOINER_ED_SEED)

    initiator = ReconnectHandshake.initiator(
        device_id=INITIATOR_DEVICE_ID,
        device_identity=init_id,
        peer_device_id=JOINER_DEVICE_ID,
        peer_public_key=join_id.public_key,
        channel_id=CHANNEL_ID,
        nonce=INITIATOR_NONCE,
    )
    joiner = ReconnectHandshake.joiner(
        device_id=JOINER_DEVICE_ID,
        device_identity=join_id,
        peer_device_id=INITIATOR_DEVICE_ID,
        peer_public_key=init_id.public_key,
        channel_id=CHANNEL_ID,
        nonce=JOINER_NONCE,
    )

    # Drive the real state machine so the vector is exactly what the code emits.
    hello = initiator.create_hello()
    response = joiner.on_hello(hello)
    confirm = initiator.on_response(response)
    joiner.on_confirm(confirm)

    assert initiator.authenticated
    assert joiner.authenticated

    # Independently recompute the primitives, to pin them regardless of the
    # message envelopes.
    transcript = reconnect_transcript(INITIATOR_NONCE, JOINER_NONCE)
    proof_i = init_id.sign(
        reconnect_signed_bytes(RECONNECT_I_LABEL, CHANNEL_ID, transcript)
    )
    proof_j = join_id.sign(
        reconnect_signed_bytes(RECONNECT_J_LABEL, CHANNEL_ID, transcript)
    )
    assert base64.b64decode(response["sig"]) == proof_j
    assert base64.b64decode(confirm["sig"]) == proof_i

    return {
        "_comment": (
            "Cross-language reconnect vector. The Dart reconnect twin, fed these "
            "inputs, MUST reproduce every 'expected' value: the transcript "
            "RT=N_i||N_j (initiator nonce first), and both Ed25519 proofs signed "
            "over label||channel_id||RT with label=RECONNECT_I_LABEL (host) / "
            "RECONNECT_J_LABEL (app). Each side verifies the peer's proof against "
            "the STORED approved public key; an imposter without the peer's "
            "private key cannot forge a verifying proof."
        ),
        "labels": {
            "proof_i": RECONNECT_I_LABEL.decode(),
            "proof_j": RECONNECT_J_LABEL.decode(),
        },
        "inputs": {
            "initiator_ed25519_seed_b64": _b64(INITIATOR_ED_SEED),
            "joiner_ed25519_seed_b64": _b64(JOINER_ED_SEED),
            "initiator_ed25519_public_b64": init_id.export_public_key_base64(),
            "joiner_ed25519_public_b64": join_id.export_public_key_base64(),
            "initiator_nonce_b64": _b64(INITIATOR_NONCE),
            "joiner_nonce_b64": _b64(JOINER_NONCE),
            "initiator_device_id": INITIATOR_DEVICE_ID,
            "joiner_device_id": JOINER_DEVICE_ID,
            "channel_id": CHANNEL_ID,
        },
        "expected": {
            "transcript_b64": _b64(transcript),
            "proof_i_b64": _b64(proof_i),
            "proof_j_b64": _b64(proof_j),
            "hello_msg": hello,
            "response_msg": response,
            "confirm_msg": confirm,
        },
    }


def main() -> None:
    out = build()
    path = Path(__file__).parent / "fixtures" / "reconnect_vectors.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
