"""Behavioural tests for the Agents frame crypto: round-trip and every reject
path required by the task."""

from __future__ import annotations

import base64
import json

import pytest

from chuk_agents_crypto import (
    ApprovedDevices,
    AgentsFrame,
    AgentsFrameOpener,
    AgentsFrameRejected,
    AgentsFrameRejection,
    AgentsFrameSealer,
    DeviceIdentity,
    derive_channel_key,
    generate_x25519_keypair,
)

CHANNEL_KEY = bytes(range(0x40, 0x60))
KEY_VERSION = 1
DEVICE_ID = "executor-01"
# A clock fixed in the middle of the window so freshness always passes.
FIXED_NOW = 1_723_478_400_000


def make_pair(now_ms=lambda: FIXED_NOW, *, channel_key=CHANNEL_KEY, key_version=KEY_VERSION):
    identity = DeviceIdentity.generate()
    approved = ApprovedDevices.empty()
    approved.approve(DEVICE_ID, identity.public_key)
    sealer = AgentsFrameSealer(
        channel_key=channel_key,
        key_version=key_version,
        device_id=DEVICE_ID,
        signing_identity=identity,
        now_ms=now_ms,
    )
    opener = AgentsFrameOpener(
        channel_key=channel_key,
        key_version=key_version,
        approved_devices=approved,
        now_ms=now_ms,
    )
    return identity, approved, sealer, opener


def test_round_trip_bytes():
    _, _, sealer, opener = make_pair()
    frame_bytes = sealer.seal_bytes(b"hello executor")
    assert opener.open(frame_bytes) == b"hello executor"


def test_round_trip_text_and_frame_object():
    _, _, sealer, opener = make_pair()
    frame = sealer.seal_text("run: echo hi")
    assert opener.open_text(frame) == "run: echo hi"


def test_round_trip_multiple_monotonic():
    _, _, sealer, opener = make_pair()
    for i in range(5):
        frame = sealer.seal(f"msg {i}".encode())
        assert opener.open(frame) == f"msg {i}".encode()
    assert opener.last_seq_by_device[DEVICE_ID] == 4


def test_tamper_ciphertext_rejected():
    _, _, sealer, opener = make_pair()
    frame = sealer.seal(b"secret payload")
    tampered = AgentsFrame(
        version=frame.version,
        key_version=frame.key_version,
        device_id=frame.device_id,
        seq=frame.seq,
        ts=frame.ts,
        nonce=frame.nonce,
        ciphertext=frame.ciphertext[:-1] + bytes([frame.ciphertext[-1] ^ 0x01]),
        sig=frame.sig,
    )
    # Tampering the ciphertext breaks the signature first (fail-closed gate).
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(tampered)
    assert exc.value.rejection == AgentsFrameRejection.BAD_SIGNATURE


def test_tamper_header_field_rejected():
    """Flipping an authenticated header field (seq) must reject: the signature
    covers the header, so it fails before decrypt."""
    _, _, sealer, opener = make_pair()
    frame = sealer.seal(b"payload")
    moved = AgentsFrame(
        version=frame.version,
        key_version=frame.key_version,
        device_id=frame.device_id,
        seq=frame.seq + 1,  # changed -> signature no longer matches
        ts=frame.ts,
        nonce=frame.nonce,
        ciphertext=frame.ciphertext,
        sig=frame.sig,
    )
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(moved)
    assert exc.value.rejection == AgentsFrameRejection.BAD_SIGNATURE


def test_replay_same_frame_rejected():
    _, _, sealer, opener = make_pair()
    frame = sealer.seal(b"once")
    assert opener.open(frame) == b"once"
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.REPLAYED_SEQUENCE


def test_stale_timestamp_rejected():
    # Sealer stamps ts far in the past relative to the opener's clock.
    identity = DeviceIdentity.generate()
    approved = ApprovedDevices.empty()
    approved.approve(DEVICE_ID, identity.public_key)
    sealer = AgentsFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        device_id=DEVICE_ID,
        signing_identity=identity,
        now_ms=lambda: FIXED_NOW,
    )
    opener = AgentsFrameOpener(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        approved_devices=approved,
        replay_window_ms=60_000,
        now_ms=lambda: FIXED_NOW + 120_000,  # 2 min later, outside the 60s window
    )
    frame = sealer.seal(b"stale")
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.TIMESTAMP_OUT_OF_WINDOW


def test_future_timestamp_rejected():
    identity = DeviceIdentity.generate()
    approved = ApprovedDevices.empty()
    approved.approve(DEVICE_ID, identity.public_key)
    sealer = AgentsFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        device_id=DEVICE_ID,
        signing_identity=identity,
        now_ms=lambda: FIXED_NOW + 120_000,  # sealer clock ahead
    )
    opener = AgentsFrameOpener(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        approved_devices=approved,
        replay_window_ms=60_000,
        now_ms=lambda: FIXED_NOW,
    )
    frame = sealer.seal(b"future")
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.TIMESTAMP_OUT_OF_WINDOW


def test_wrong_device_signature_rejected():
    """A frame signed by a different device (whose key is not approved) but sent
    under an approved device_id must reject at the signature gate."""
    good = DeviceIdentity.generate()
    attacker = DeviceIdentity.generate()
    approved = ApprovedDevices.empty()
    approved.approve(DEVICE_ID, good.public_key)  # approve the good key only
    # Attacker seals under the approved device_id but signs with its own key.
    sealer = AgentsFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        device_id=DEVICE_ID,
        signing_identity=attacker,
        now_ms=lambda: FIXED_NOW,
    )
    opener = AgentsFrameOpener(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        approved_devices=approved,
        now_ms=lambda: FIXED_NOW,
    )
    frame = sealer.seal(b"forged")
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.BAD_SIGNATURE


def test_unapproved_device_id_rejected():
    """A validly-signed frame from a device whose id is not in the store dies at
    the local-approval gate (default deny), before any signature work."""
    identity = DeviceIdentity.generate()
    approved = ApprovedDevices.empty()
    approved.approve("some-other-device", identity.public_key)
    sealer = AgentsFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        device_id=DEVICE_ID,  # not approved
        signing_identity=identity,
        now_ms=lambda: FIXED_NOW,
    )
    opener = AgentsFrameOpener(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        approved_devices=approved,
        now_ms=lambda: FIXED_NOW,
    )
    frame = sealer.seal(b"unknown")
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.DEVICE_NOT_APPROVED


def test_empty_approval_rejects_all():
    identity = DeviceIdentity.generate()
    empty = ApprovedDevices.empty()
    assert empty.is_empty
    sealer = AgentsFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        device_id=DEVICE_ID,
        signing_identity=identity,
        now_ms=lambda: FIXED_NOW,
    )
    opener = AgentsFrameOpener(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        approved_devices=empty,
        now_ms=lambda: FIXED_NOW,
    )
    frame = sealer.seal(b"anything")
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.DEVICE_NOT_APPROVED


def test_wrong_channel_key_rejected():
    """Right signature, wrong symmetric key -> GCM tag fails at decrypt."""
    identity = DeviceIdentity.generate()
    approved = ApprovedDevices.empty()
    approved.approve(DEVICE_ID, identity.public_key)
    sealer = AgentsFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=KEY_VERSION,
        device_id=DEVICE_ID,
        signing_identity=identity,
        now_ms=lambda: FIXED_NOW,
    )
    opener = AgentsFrameOpener(
        channel_key=bytes(range(0x60, 0x80)),  # different 32-byte key
        key_version=KEY_VERSION,
        approved_devices=approved,
        now_ms=lambda: FIXED_NOW,
    )
    frame = sealer.seal(b"payload")
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.DECRYPTION_FAILED


def test_key_version_mismatch_rejected():
    identity = DeviceIdentity.generate()
    approved = ApprovedDevices.empty()
    approved.approve(DEVICE_ID, identity.public_key)
    sealer = AgentsFrameSealer(
        channel_key=CHANNEL_KEY,
        key_version=2,  # sealed under kv=2
        device_id=DEVICE_ID,
        signing_identity=identity,
        now_ms=lambda: FIXED_NOW,
    )
    opener = AgentsFrameOpener(
        channel_key=CHANNEL_KEY,
        key_version=1,  # receiver holds kv=1
        approved_devices=approved,
        now_ms=lambda: FIXED_NOW,
    )
    frame = sealer.seal(b"payload")
    with pytest.raises(AgentsFrameRejected) as exc:
        opener.open(frame)
    assert exc.value.rejection == AgentsFrameRejection.KEY_VERSION_MISMATCH


def test_unsupported_version_rejected():
    with pytest.raises(AgentsFrameRejected) as exc:
        AgentsFrame.from_json_string(
            json.dumps({"v": "2", "kv": 1, "device_id": "d", "seq": 0, "ts": 0,
                        "nonce": "", "ciphertext": "", "sig": ""})
        )
    assert exc.value.rejection == AgentsFrameRejection.UNSUPPORTED_VERSION


@pytest.mark.parametrize(
    "mutate",
    [
        lambda d: d.pop("v"),
        lambda d: d.__setitem__("kv", 0),
        lambda d: d.__setitem__("device_id", ""),
        lambda d: d.__setitem__("seq", -1),
        lambda d: d.__setitem__("nonce", base64.b64encode(b"short").decode()),
        lambda d: d.__setitem__("sig", base64.b64encode(b"tooshort").decode()),
        lambda d: d.__setitem__("nonce", "!!!not base64!!!"),
    ],
)
def test_malformed_frames_rejected(mutate):
    _, _, sealer, _ = make_pair()
    d = sealer.seal(b"x").to_json()
    mutate(d)
    with pytest.raises(AgentsFrameRejected) as exc:
        AgentsFrame.from_json(d)
    assert exc.value.rejection in (
        AgentsFrameRejection.MALFORMED,
        AgentsFrameRejection.UNSUPPORTED_VERSION,
    )


def test_non_json_rejected():
    with pytest.raises(AgentsFrameRejected) as exc:
        AgentsFrame.from_json_string("not json at all {")
    assert exc.value.rejection == AgentsFrameRejection.MALFORMED
