"""Cross-language byte-compat: re-derive the frame from the fixed inputs in
``fixtures/test_vectors.json`` and assert every expected byte string matches.

This is the same fixture a Dart test must load. If this test and the Dart test
both pass against this file, the two implementations are byte-compatible.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

from cowork_crypto import (
    ApprovedDevices,
    CoworkFrameOpener,
    CoworkFrameSealer,
    DeviceIdentity,
    build_header_bytes,
    build_signed_bytes,
)

FIXTURE = Path(__file__).parent / "fixtures" / "test_vectors.json"


def _load() -> dict:
    return json.loads(FIXTURE.read_text())


def _b64(s: str) -> bytes:
    return base64.b64decode(s)


def test_fixture_reproduces_byte_for_byte():
    vec = _load()
    inp = vec["inputs"]
    exp = vec["expected"]

    identity = DeviceIdentity.from_seed(_b64(inp["ed25519_seed_b64"]))
    # Public key + fingerprint are stable derivations of the seed.
    assert identity.export_public_key_base64() == inp["ed25519_public_b64"]
    assert identity.fingerprint() == inp["fingerprint"]

    sealer = CoworkFrameSealer(
        channel_key=_b64(inp["channel_key_b64"]),
        key_version=inp["key_version"],
        device_id=inp["device_id"],
        signing_identity=identity,
        next_seq=inp["seq"],
        now_ms=lambda: inp["ts"],
        rand=lambda n: _b64(inp["nonce_b64"])[:n],
    )
    frame = sealer.seal(inp["plaintext_utf8"].encode("utf-8"))

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

    assert base64.b64encode(header).decode() == exp["header_b64"]
    assert base64.b64encode(signed).decode() == exp["signed_b64"]
    assert base64.b64encode(frame.nonce).decode() == exp["nonce_b64"]
    # Ed25519 is deterministic (RFC 8032), so the signature must be exact.
    assert base64.b64encode(frame.sig).decode() == exp["sig_b64"]
    assert base64.b64encode(frame.ciphertext).decode() == exp["ciphertext_b64"]
    assert frame.to_json_string() == exp["frame_json"]


def test_fixture_frame_opens_to_plaintext():
    """A receiver built from the fixture inputs opens the expected frame_json."""
    vec = _load()
    inp = vec["inputs"]
    exp = vec["expected"]

    identity = DeviceIdentity.from_seed(_b64(inp["ed25519_seed_b64"]))
    approved = ApprovedDevices.empty()
    approved.approve(inp["device_id"], identity.public_key)
    opener = CoworkFrameOpener(
        channel_key=_b64(inp["channel_key_b64"]),
        key_version=inp["key_version"],
        approved_devices=approved,
        now_ms=lambda: inp["ts"],
    )
    plaintext = opener.open(exp["frame_json"].encode("utf-8"))
    assert plaintext == inp["plaintext_utf8"].encode("utf-8")
