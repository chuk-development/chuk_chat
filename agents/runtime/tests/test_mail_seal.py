"""The agent mail seal ``chuk-agent-mail-v1`` (docs/AGENT_MAIL.md §3.2).

The test vector of the contract: every implementation must open it, and must
produce it when the ephemeral key and the nonce are fixed.
"""

from __future__ import annotations

import base64
import json

import pytest

from chuk_agents_runtime.mail_seal import (
    MailKey,
    MailSealError,
    open_binary,
    open_json,
    open_text,
    seal_binary,
    seal_json,
    seal_text,
)

RECIPIENT_PRIVATE = bytes.fromhex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
RECIPIENT_PUBLIC_B64 = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw="
EPHEMERAL_PRIVATE = bytes.fromhex("65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384")
NONCE = bytes.fromhex("c9cacbcccdcecfd0d1d2d3d4")
PLAINTEXT = "hello agent mail ✓".encode("utf-8")
TEXT_ENVELOPE = (
    '{"v":1,"epk":"VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY=",'
    '"n":"ycrLzM3Oz9DR0tPU","ct":"bPxiL4cAEjEH7OPALFms6fEudfWc8Wz6VHV5vyBhIkO5Cis9"}'
)
BINARY_ENVELOPE_B64 = (
    "Q0FNMVcUdp0Ra/dkNq50vHk9LDCtGQPFmsUnOAXH4mmLQQw2ycrLzM3Oz9DR0tPU"
    "bPxiL4cAEjEH7OPALFms6fEudfWc8Wz6VHV5vyBhIkO5Cis9"
)


def _key() -> MailKey:
    return MailKey.from_b64(RECIPIENT_PUBLIC_B64, base64.b64encode(RECIPIENT_PRIVATE).decode())


def _other_key() -> MailKey:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

    private = X25519PrivateKey.generate()
    return MailKey(private.public_key().public_bytes_raw(), private.private_bytes_raw())


def test_the_vector_opens_in_both_forms():
    key = _key()
    assert open_text(TEXT_ENVELOPE, key) == PLAINTEXT
    assert open_text(json.loads(TEXT_ENVELOPE), key) == PLAINTEXT
    assert open_binary(base64.b64decode(BINARY_ENVELOPE_B64), key) == PLAINTEXT


def test_a_fixed_ephemeral_key_and_nonce_reproduce_the_vector():
    key = _key()
    assert key.public_b64() == RECIPIENT_PUBLIC_B64
    envelope = seal_text(
        PLAINTEXT, key.public_key, ephemeral_private=EPHEMERAL_PRIVATE, nonce=NONCE
    )
    assert json.dumps(envelope, separators=(",", ":")) == TEXT_ENVELOPE
    blob = seal_binary(
        PLAINTEXT, key.public_key, ephemeral_private=EPHEMERAL_PRIVATE, nonce=NONCE
    )
    assert base64.b64encode(blob).decode() == BINARY_ENVELOPE_B64


def test_a_random_seal_round_trips_and_differs_each_time():
    key = _key()
    one = seal_text(PLAINTEXT, key.public_key)
    two = seal_text(PLAINTEXT, key.public_key)
    assert one != two
    assert open_text(one, key) == open_text(two, key) == PLAINTEXT
    assert open_json(seal_json({"subject": "Hi ✓"}, key.public_key), key) == {"subject": "Hi ✓"}


def test_a_wrong_key_or_a_changed_byte_does_not_open():
    key = _key()
    with pytest.raises(MailSealError):
        open_text(TEXT_ENVELOPE, _other_key())
    envelope = json.loads(TEXT_ENVELOPE)
    ct = bytearray(base64.b64decode(envelope["ct"]))
    ct[0] ^= 1
    with pytest.raises(MailSealError):
        open_text({**envelope, "ct": base64.b64encode(bytes(ct)).decode()}, key)
    blob = bytearray(base64.b64decode(BINARY_ENVELOPE_B64))
    blob[-1] ^= 1
    with pytest.raises(MailSealError):
        open_binary(bytes(blob), key)


@pytest.mark.parametrize(
    "envelope",
    [
        "not json",
        "[1, 2]",
        {"v": 2, "epk": "AA==", "n": "AA==", "ct": "AA=="},
        {"v": True, "epk": "AA==", "n": "AA==", "ct": "AA=="},
        {"v": 1, "epk": "!!", "n": "ycrLzM3Oz9DR0tPU", "ct": "AA=="},
        {"v": 1, "epk": "AAAA", "n": "ycrLzM3Oz9DR0tPU", "ct": "A" * 24},
        {"v": 1, "epk": "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY=", "n": "AAAA", "ct": "A" * 24},
        {"v": 1, "epk": "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY=", "n": "ycrLzM3Oz9DR0tPU", "ct": "AAAA"},
        # A low-order ephemeral key: the shared secret would be all zeros.
        {"v": 1, "epk": base64.b64encode(bytes(32)).decode(), "n": "ycrLzM3Oz9DR0tPU", "ct": "A" * 24},
    ],
)
def test_a_bad_envelope_is_a_seal_error_not_a_crash(envelope):
    with pytest.raises(MailSealError):
        open_text(envelope, _key())


def test_a_bad_binary_object_is_a_seal_error():
    key = _key()
    for blob in (b"", b"CAM2" + bytes(80), b"CAM1" + bytes(10), "text"):
        with pytest.raises(MailSealError):
            open_binary(blob, key)  # type: ignore[arg-type]


def test_a_sealed_document_must_be_a_json_object():
    key = _key()
    with pytest.raises(MailSealError):
        open_json(seal_text(b"\xff\xfe", key.public_key), key)
    with pytest.raises(MailSealError):
        open_json(seal_text(b"[1]", key.public_key), key)


def test_the_key_pair_is_checked_and_never_printed():
    private_b64 = base64.b64encode(RECIPIENT_PRIVATE).decode()
    other = _other_key()
    for public, private in (
        (other.public_b64(), private_b64),  # not this private key's public key
        (RECIPIENT_PUBLIC_B64, base64.b64encode(RECIPIENT_PRIVATE[:31]).decode()),
        ("!!", private_b64),
        (RECIPIENT_PUBLIC_B64, None),
    ):
        with pytest.raises(ValueError):
            MailKey.from_b64(public, private)
    key = _key()
    assert private_b64 not in repr(key) and RECIPIENT_PRIVATE.hex() not in repr(key)
    assert key.same_as(_key()) and not key.same_as(other) and not key.same_as(None)
