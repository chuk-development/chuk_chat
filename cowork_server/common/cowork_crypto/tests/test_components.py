"""Unit tests for the individual components: approved-device store, replay
guard, device identity / fingerprint, and channel-key ECDH."""

from __future__ import annotations

import pytest

from cowork_crypto import (
    ApprovedDevices,
    CoworkFrame,
    CoworkFrameRejected,
    CoworkFrameRejection,
    DeviceIdentity,
    ReplayGuard,
    derive_channel_key,
    fingerprint,
    generate_x25519_keypair,
    public_key_from_base64,
)


# --- ApprovedDevices --------------------------------------------------------

def test_approve_lookup_revoke():
    store = ApprovedDevices.empty()
    identity = DeviceIdentity.generate()
    assert store.lookup("d1") is None
    store.approve("d1", identity.public_key)
    assert store.is_approved("d1")
    assert store.lookup("d1") is not None
    assert store.revoke("d1") is True
    assert store.revoke("d1") is False
    assert store.lookup("d1") is None


def test_reapprove_same_key_ok_different_key_raises():
    store = ApprovedDevices.empty()
    a = DeviceIdentity.generate()
    b = DeviceIdentity.generate()
    store.approve("d1", a.public_key)
    store.approve("d1", a.public_key)  # idempotent, same key
    with pytest.raises(ValueError):
        store.approve("d1", b.public_key)  # key substitution -> refused


def test_revoke_all_and_empty_default_deny():
    store = ApprovedDevices.empty()
    store.approve("d1", DeviceIdentity.generate().public_key)
    store.approve("d2", DeviceIdentity.generate().public_key)
    assert len(store) == 2
    store.revoke_all()
    assert store.is_empty
    assert store.lookup("d1") is None


def test_base64_map_round_trip():
    store = ApprovedDevices.empty()
    ident = DeviceIdentity.generate()
    store.approve("d1", ident.public_key)
    restored = ApprovedDevices.from_base64_map(store.to_base64_map())
    assert restored.lookup("d1").public_bytes_raw() == ident.public_key_bytes()


def test_from_base64_map_rejects_bad_key():
    with pytest.raises(ValueError):
        ApprovedDevices.from_base64_map({"d1": "not-a-valid-key"})


def test_approve_empty_device_id_raises():
    store = ApprovedDevices.empty()
    with pytest.raises(ValueError):
        store.approve("", DeviceIdentity.generate().public_key)


# --- ReplayGuard ------------------------------------------------------------

def _frame(seq: int, ts: int) -> CoworkFrame:
    return CoworkFrame(
        device_id="d", seq=seq, ts=ts, nonce=bytes(12),
        ciphertext=bytes(16), sig=bytes(64),
    )


def test_replay_guard_monotonic_seq():
    g = ReplayGuard(window_ms=60_000, now_ms=lambda: 1000)
    f0 = _frame(0, 1000)
    g.check(f0)
    g.commit(f0)
    # Same seq is a replay.
    with pytest.raises(CoworkFrameRejected) as exc:
        g.check(_frame(0, 1000))
    assert exc.value.rejection == CoworkFrameRejection.REPLAYED_SEQUENCE
    # Lower seq is a replay.
    with pytest.raises(CoworkFrameRejected):
        g.check(_frame(-0, 1000))
    # Higher seq passes.
    g.check(_frame(1, 1000))


def test_replay_guard_injectable_state():
    g = ReplayGuard(window_ms=60_000, now_ms=lambda: 1000, last_seq=41)
    assert g.last_seq == 41
    with pytest.raises(CoworkFrameRejected):
        g.check(_frame(41, 1000))
    g.check(_frame(42, 1000))
    g.commit(_frame(42, 1000))
    assert g.last_seq == 42


def test_replay_guard_timestamp_window_symmetric():
    g = ReplayGuard(window_ms=60_000, now_ms=lambda: 100_000)
    g.check(_frame(0, 100_000))  # exactly now
    g.check(_frame(0, 100_000 - 60_000))  # edge, past
    g.check(_frame(0, 100_000 + 60_000))  # edge, future
    with pytest.raises(CoworkFrameRejected) as exc:
        g.check(_frame(0, 100_000 - 60_001))
    assert exc.value.rejection == CoworkFrameRejection.TIMESTAMP_OUT_OF_WINDOW
    with pytest.raises(CoworkFrameRejected):
        g.check(_frame(0, 100_000 + 60_001))


# --- DeviceIdentity / fingerprint -------------------------------------------

def test_seed_round_trip():
    ident = DeviceIdentity.generate()
    seed = ident.export_private_seed()
    assert len(seed) == 32
    restored = DeviceIdentity.from_seed(seed)
    assert restored.public_key_bytes() == ident.public_key_bytes()


def test_seed_base64_round_trip():
    ident = DeviceIdentity.generate()
    restored = DeviceIdentity.from_seed_base64(ident.export_private_seed_base64())
    assert restored.public_key_bytes() == ident.public_key_bytes()


def test_public_key_from_base64_round_trip_and_reject():
    ident = DeviceIdentity.generate()
    pk = public_key_from_base64(ident.export_public_key_base64())
    assert pk.public_bytes_raw() == ident.public_key_bytes()
    with pytest.raises(ValueError):
        public_key_from_base64("AAAA")  # wrong length


def test_fingerprint_format_and_stability():
    # Fixed seed -> fixed public key -> fixed fingerprint. Matches the Dart
    # algorithm: SHA-256 of pubkey, first 10 bytes, upper hex, grouped by 4.
    ident = DeviceIdentity.from_seed(bytes(range(32)))
    fp = ident.fingerprint()
    assert fp == "5647-5AA7-5463-474C-0285"
    # Shape: 5 groups of 4 hex chars.
    groups = fp.split("-")
    assert len(groups) == 5
    assert all(len(g) == 4 for g in groups)
    assert fingerprint(ident.public_key_bytes()) == fp


def test_seed_wrong_length_raises():
    with pytest.raises(ValueError):
        DeviceIdentity.from_seed(bytes(31))


# --- channel key (X25519 ECDH) ----------------------------------------------

def test_derive_channel_key_symmetric():
    a_priv, a_pub = generate_x25519_keypair()
    b_priv, b_pub = generate_x25519_keypair()
    key_a = derive_channel_key(a_priv, b_pub)
    key_b = derive_channel_key(b_priv, a_pub)
    assert key_a == key_b
    assert len(key_a) == 32


def test_derive_channel_key_differs_for_different_peers():
    a_priv, a_pub = generate_x25519_keypair()
    b_priv, b_pub = generate_x25519_keypair()
    c_priv, c_pub = generate_x25519_keypair()
    assert derive_channel_key(a_priv, b_pub) != derive_channel_key(a_priv, c_pub)
