"""Regenerate ``fixtures/pairing_vectors.json`` — the cross-language pairing
vector shared with the Dart twin.

Run with:  uv run python tests/gen_pairing_vectors.py

Determinism: fixed X25519 ephemeral private keys for both sides, fixed Ed25519
device seeds, a fixed channel id + digits. X25519 and Ed25519 are both
deterministic from their private bytes (RFC 7748 / RFC 8032), so every derived
value — commitment, shared secret, channel key, SAS, both confirmation MACs and
both device-key messages — is reproducible with no RNG. The Dart pairing code,
fed the same inputs, MUST reproduce every ``expected`` byte string.

After running, copy the fixture into the app test tree:
    cp tests/fixtures/pairing_vectors.json \\
       ../../app/test/fixtures/cowork_pairing_vectors.json
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from cowork_crypto import DeviceIdentity, transcript
from cowork_crypto.channel_key import derive_channel_key
from cowork_crypto.pairing import (
    CONFIRM_C_LABEL,
    CONFIRM_D_LABEL,
    DEVICE_C_LABEL,
    DEVICE_D_LABEL,
    Pairing,
    commitment,
    derive_confirm_mac,
    derive_sas,
)

# --- fixed inputs (do not change without regenerating and updating Dart) -----

# 32-byte X25519 ephemeral private scalars.
INITIATOR_X25519_SEED = bytes(range(0x10, 0x30))  # 0x10..0x2f  (a)
JOINER_X25519_SEED = bytes(range(0x60, 0x80))  # 0x60..0x7f  (b)

# 32-byte Ed25519 device seeds.
INITIATOR_ED_SEED = bytes(range(0x80, 0xA0))  # 0x80..0x9f
JOINER_ED_SEED = bytes(range(0xC0, 0xE0))  # 0xc0..0xdf

CHANNEL_ID = "cowork00deadbeef"  # 16 hex chars, no '-'
DIGITS = "428913"
SAS_DIGITS = len(DIGITS)
PAIRING_CODE = f"{CHANNEL_ID}-{DIGITS}"

INITIATOR_DEVICE_ID = "client-python-01"
JOINER_DEVICE_ID = "desktop-flutter-01"

TS = 1_723_478_400_000  # fixed clock
EXPIRY_MS = 120_000


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def build() -> dict:
    a_priv = X25519PrivateKey.from_private_bytes(INITIATOR_X25519_SEED)
    b_priv = X25519PrivateKey.from_private_bytes(JOINER_X25519_SEED)
    a_pub = a_priv.public_key().public_bytes_raw()
    b_pub = b_priv.public_key().public_bytes_raw()

    init_id = DeviceIdentity.from_seed(INITIATOR_ED_SEED)
    join_id = DeviceIdentity.from_seed(JOINER_ED_SEED)

    # Drive the real state machine so the vector is exactly what the code emits.
    clock = lambda: TS  # noqa: E731
    initiator = Pairing.initiator(
        device_id=INITIATOR_DEVICE_ID,
        device_identity=init_id,
        sas_digits=SAS_DIGITS,
        expiry_ms=EXPIRY_MS,
        now_ms=clock,
        ephemeral_private=a_priv,
        channel_id=CHANNEL_ID,
        digits=DIGITS,
    )
    joiner = Pairing.joiner(
        device_id=JOINER_DEVICE_ID,
        device_identity=join_id,
        pairing_code=PAIRING_CODE,
        now_ms=clock,
        ephemeral_private=b_priv,
    )

    commit = initiator.create_commit()
    joiner.on_commit(commit)
    pubkey = joiner.create_pubkey()
    reveal = initiator.on_pubkey(pubkey)
    confirm_d = joiner.on_reveal(reveal)
    confirm_c = initiator.on_confirm_d(confirm_d)
    joiner.on_confirm_c(confirm_c)
    device_from_joiner = joiner.create_device_key()
    initiator.on_peer_device_key(device_from_joiner)
    device_from_initiator = initiator.create_device_key()
    joiner.on_peer_device_key(device_from_initiator)

    # Independently recompute the primitives, to pin them regardless of the
    # message envelopes.
    k_raw = a_priv.exchange(b_priv.public_key())
    channel_key = derive_channel_key(a_priv, b_priv.public_key())
    t = transcript(a_pub, b_pub)
    sas = derive_sas(k_raw, t, PAIRING_CODE, SAS_DIGITS)
    mac_d = derive_confirm_mac(k_raw, CONFIRM_D_LABEL, t, PAIRING_CODE)
    mac_c = derive_confirm_mac(k_raw, CONFIRM_C_LABEL, t, PAIRING_CODE)

    assert initiator.sas == sas == joiner.sas
    assert base64.b64decode(confirm_d["mac"]) == mac_d
    assert base64.b64decode(confirm_c["mac"]) == mac_c
    assert channel_key == initiator.channel_key == joiner.channel_key

    return {
        "_comment": (
            "Cross-language pairing vector (§15). The Dart pairing twin, fed "
            "these inputs, MUST reproduce every 'expected' value: commitment, "
            "K_raw, channel_key, transcript, SAS, MAC_d/MAC_c and both device-"
            "key messages. Labels: SAS over K_raw with info=SAS_LABEL||T||PC; "
            "confirm MAC over K_raw with info=CONFIRM_?_LABEL||T||PC (PC folded "
            "in so the one-way-typed pairing code authenticates the channel); "
            "device MAC info=LBL||T||ed_pub||device_id||PC; transcript T=A||B "
            "(initiator public first); channel_key=HKDF(K_raw, "
            "info=chuk.cowork.channel-key.v1)."
        ),
        "labels": {
            "sas": "cowork/pairing/sas",
            "confirm_d": "cowork/pairing/confirm-d",
            "confirm_c": "cowork/pairing/confirm-c",
            "device_d": DEVICE_D_LABEL.decode(),
            "device_c": DEVICE_C_LABEL.decode(),
            "device_proof": "cowork/pairing/device-proof",
            "commit": "cowork/pairing/commit-v1",
            "channel_key_info": "chuk.cowork.channel-key.v1",
        },
        "inputs": {
            "initiator_x25519_seed_b64": _b64(INITIATOR_X25519_SEED),
            "joiner_x25519_seed_b64": _b64(JOINER_X25519_SEED),
            "initiator_x25519_public_b64": _b64(a_pub),
            "joiner_x25519_public_b64": _b64(b_pub),
            "initiator_ed25519_seed_b64": _b64(INITIATOR_ED_SEED),
            "joiner_ed25519_seed_b64": _b64(JOINER_ED_SEED),
            "initiator_ed25519_public_b64": init_id.export_public_key_base64(),
            "joiner_ed25519_public_b64": join_id.export_public_key_base64(),
            "initiator_device_id": INITIATOR_DEVICE_ID,
            "joiner_device_id": JOINER_DEVICE_ID,
            "channel_id": CHANNEL_ID,
            "digits": DIGITS,
            "sas_digits": SAS_DIGITS,
            "pairing_code": PAIRING_CODE,
            "expires_at": TS + EXPIRY_MS,
        },
        "expected": {
            "commitment_b64": _b64(commitment(a_pub)),
            "k_raw_b64": _b64(k_raw),
            "channel_key_b64": _b64(channel_key),
            "transcript_b64": _b64(t),
            "sas": sas,
            "mac_d_b64": _b64(mac_d),
            "mac_c_b64": _b64(mac_c),
            "commit_msg": commit,
            "pubkey_msg": pubkey,
            "reveal_msg": reveal,
            "confirm_d_msg": confirm_d,
            "confirm_c_msg": confirm_c,
            "device_key_from_joiner": device_from_joiner,
            "device_key_from_initiator": device_from_initiator,
        },
    }


def main() -> None:
    out = build()
    path = Path(__file__).parent / "fixtures" / "pairing_vectors.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
