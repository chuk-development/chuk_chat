"""Pairing state-machine tests — the full two-role handshake in-process plus
the MITM / abort / expiry / single-use paths, and the cross-language vector.

The wire messages ride the real relay later; here they are handed straight from
one role to the other, which is exactly the surface a relay would carry.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)

from cowork_crypto import (
    CONFIRM_D_LABEL,
    ApprovedDevices,
    DeviceIdentity,
    Pairing,
    PairingError,
    PairingRejection,
    PairingState,
    commitment,
    derive_confirm_mac,
    transcript,
)

FIXTURE = Path(__file__).parent / "fixtures" / "pairing_vectors.json"

TS = 1_723_478_400_000


def _clock():
    return TS


def _make_pair(*, initiator_devices=None, joiner_devices=None, digits="428913"):
    """A fresh initiator + joiner wired to the fixed clock, with fresh keys."""
    initiator = Pairing.initiator(
        device_id="client-01",
        device_identity=DeviceIdentity.generate(),
        now_ms=_clock,
        channel_id="chan0001",
        digits=digits,
        approved_devices=initiator_devices,
    )
    joiner = Pairing.joiner(
        device_id="desktop-01",
        device_identity=DeviceIdentity.generate(),
        pairing_code=initiator.pairing_code,
        now_ms=_clock,
        approved_devices=joiner_devices,
    )
    return initiator, joiner


def _run_to_confirmed(initiator: Pairing, joiner: Pairing):
    commit = initiator.create_commit()
    joiner.on_commit(commit)
    pubkey = joiner.create_pubkey()
    reveal = initiator.on_pubkey(pubkey)
    confirm_d = joiner.on_reveal(reveal)
    confirm_c = initiator.on_confirm_d(confirm_d)
    joiner.on_confirm_c(confirm_c)


def _exchange_device_keys(initiator: Pairing, joiner: Pairing):
    dev_j = joiner.create_device_key()
    initiator.on_peer_device_key(dev_j)
    dev_i = initiator.create_device_key()
    joiner.on_peer_device_key(dev_i)


# --- happy path --------------------------------------------------------------


def test_happy_path_reaches_same_key_sas_and_mutual_trust():
    init_store = ApprovedDevices.empty()
    join_store = ApprovedDevices.empty()
    initiator, joiner = _make_pair(
        initiator_devices=init_store, joiner_devices=join_store
    )

    _run_to_confirmed(initiator, joiner)

    # Same channel key, and it is only exposed now both MACs verified. No human
    # SAS comparison is performed: PC folded into the MACs already authenticated
    # the channel, so the happy path never calls confirm_peer_sas.
    assert initiator.channel_key == joiner.channel_key
    assert len(initiator.channel_key) == 32

    _exchange_device_keys(initiator, joiner)

    assert initiator.state is PairingState.COMPLETED
    assert joiner.state is PairingState.COMPLETED
    # Each side locally approved the other's long-term device key.
    assert init_store.is_approved("desktop-01")
    assert join_store.is_approved("client-01")
    assert initiator.peer_device_id == "desktop-01"
    assert joiner.peer_device_id == "client-01"


def test_channel_key_hidden_before_confirmation():
    initiator, joiner = _make_pair()
    commit = initiator.create_commit()
    joiner.on_commit(commit)
    pubkey = joiner.create_pubkey()
    initiator.on_pubkey(pubkey)  # initiator has K + SAS but not confirmed
    # SAS is exposed (that is the point); the channel key is not.
    assert isinstance(initiator.sas, str)
    with pytest.raises(PairingError) as exc:
        initiator.channel_key
    assert exc.value.rejection is PairingRejection.WRONG_STATE


# --- MITM: a full relaying attacker who controls both ECDH legs --------------


def test_relaying_mitm_cannot_forge_a_confirm_mac_without_pc():
    """The real attack the folded-in PC defends against.

    A relay sits between the two honest sides and runs **two** ECDH legs, one
    with each, using its own ephemeral keys. It sees every wire message, so it
    learns both shared secrets ``K1``/``K2`` and both transcripts ``T1``/``T2``.
    With a confirm MAC over ``T`` alone it would just recompute a valid MAC for
    each leg and pass both checks. The one thing it never learns is the pairing
    code ``PC`` — read off the client and typed one way into the desktop, never
    on the wire. Because ``PC`` is folded into the MAC, the attacker cannot
    produce a MAC the honest initiator accepts, so the ceremony aborts with no
    channel key.
    """
    real_digits = "428913"
    initiator = Pairing.initiator(
        device_id="client-01",
        device_identity=DeviceIdentity.generate(),
        now_ms=_clock,
        channel_id="chan0001",
        digits=real_digits,  # the real, out-of-band pairing code
    )
    joiner = Pairing.joiner(
        device_id="desktop-01",
        device_identity=DeviceIdentity.generate(),
        pairing_code=initiator.pairing_code,  # user typed the real code
        now_ms=_clock,
    )

    # The attacker's two ephemeral keypairs: one per leg.
    atk_leg_to_initiator = X25519PrivateKey.generate()  # plays "joiner" to init
    atk_leg_to_joiner = X25519PrivateKey.generate()  # plays "initiator" to joiner
    atk_pub_to_initiator = atk_leg_to_initiator.public_key().public_bytes_raw()
    atk_pub_to_joiner = atk_leg_to_joiner.public_key().public_bytes_raw()

    # 1. Initiator publishes commit(H(A)). The attacker forges its own commit to
    #    the joiner over its own ephemeral M, reusing the channel id so the code
    #    the user typed still routes.
    commit = initiator.create_commit()
    forged_commit = {
        "type": "commit",
        "channel_id": commit["channel_id"],
        "commitment": base64.b64encode(commitment(atk_pub_to_joiner)).decode(),
        "expires_at": commit["expires_at"],
        "sas_digits": commit["sas_digits"],
    }
    joiner.on_commit(forged_commit)

    # 2. Joiner sends its real B; the attacker swallows it and sends the
    #    initiator its own B' instead.
    joiner.create_pubkey()  # real B, swallowed by the attacker
    reveal = initiator.on_pubkey(
        {"type": "pubkey", "pubkey": base64.b64encode(atk_pub_to_initiator).decode()}
    )
    # 3. Initiator reveals A on the wire; the attacker reads it and reveals M to
    #    the joiner. Both honest sides now derive a key with the attacker.
    real_a = base64.b64decode(reveal["pubkey"])
    joiner.on_reveal(
        {"type": "reveal", "pubkey": base64.b64encode(atk_pub_to_joiner).decode()}
    )

    # The attacker now knows both legs completely.
    k1 = atk_leg_to_initiator.exchange(
        X25519PublicKey.from_public_bytes(real_a)
    )  # == DH(a, B')
    t1 = transcript(real_a, atk_pub_to_initiator)  # A ‖ B', initiator-first

    # 4. The attacker tries every code it does not have: it can only guess PC.
    #    A wrong guess yields a MAC the initiator rejects.
    guessed = derive_confirm_mac(k1, CONFIRM_D_LABEL, t1, "000000")
    with pytest.raises(PairingError) as exc:
        initiator.on_confirm_d(
            {"type": "confirm-d", "mac": base64.b64encode(guessed).decode()}
        )
    assert exc.value.rejection is PairingRejection.MAC_MISMATCH
    assert initiator.state is PairingState.ABORTED
    with pytest.raises(PairingError):
        initiator.channel_key

    # Positive control: PC is the *only* missing ingredient. Over the very same
    # (K1, T1) the attacker held, the MAC built with the real code differs from
    # its best guess -- and an honest run with the correct code on both sides
    # verifies. So the accept/reject line is exactly the pairing code.
    with_real_pc = derive_confirm_mac(k1, CONFIRM_D_LABEL, t1, initiator.pairing_code)
    assert with_real_pc != guessed

    initiator2, joiner2 = _make_pair(digits=real_digits)
    c2 = initiator2.create_commit()
    joiner2.on_commit(c2)
    reveal2 = initiator2.on_pubkey(joiner2.create_pubkey())
    good_confirm_d = joiner2.on_reveal(reveal2)
    initiator2.on_confirm_d(good_confirm_d)  # no raise: correct PC on both sides
    assert initiator2.state is PairingState.CONFIRMED


def test_mitm_swapping_a_is_caught_by_the_commitment():
    initiator, joiner = _make_pair()
    commit = initiator.create_commit()
    joiner.on_commit(commit)
    pubkey = joiner.create_pubkey()
    initiator.on_pubkey(pubkey)

    # Attacker reveals a different A than was committed to.
    attacker = X25519PrivateKey.generate()
    forged_reveal = {
        "type": "reveal",
        "pubkey": base64.b64encode(
            attacker.public_key().public_bytes_raw()
        ).decode(),
    }
    with pytest.raises(PairingError) as exc:
        joiner.on_reveal(forged_reveal)
    assert exc.value.rejection is PairingRejection.COMMITMENT_MISMATCH
    assert joiner.state is PairingState.ABORTED
    with pytest.raises(PairingError):
        joiner.channel_key


# --- wrong pairing code ------------------------------------------------------


def test_wrong_pairing_code_aborts_at_the_confirm_mac_no_human_step():
    # The joiner types a code with different digits: same channel id, so the
    # messages still route. Because PC is folded into the confirm MAC, the
    # mismatch is caught automatically at verification -- no human SAS compare.
    initiator = Pairing.initiator(
        device_id="client-01",
        device_identity=DeviceIdentity.generate(),
        now_ms=_clock,
        channel_id="chan0001",
        digits="111111",
    )
    joiner = Pairing.joiner(
        device_id="desktop-01",
        device_identity=DeviceIdentity.generate(),
        pairing_code="chan0001-222222",  # wrong digits
        now_ms=_clock,
    )
    commit = initiator.create_commit()
    joiner.on_commit(commit)
    reveal = initiator.on_pubkey(joiner.create_pubkey())
    # The joiner builds MAC_d over its (wrong) PC; the initiator verifies over
    # its own PC -> mismatch -> abort, with no channel key committed.
    confirm_d = joiner.on_reveal(reveal)
    with pytest.raises(PairingError) as exc:
        initiator.on_confirm_d(confirm_d)
    assert exc.value.rejection is PairingRejection.MAC_MISMATCH
    assert initiator.state is PairingState.ABORTED
    with pytest.raises(PairingError):
        initiator.channel_key
    # SAS also diverges, but the abort did not depend on comparing it.
    assert initiator.sas != joiner.sas


def test_confirm_peer_sas_is_an_optional_display_helper():
    # SAS still matches on an honest run and the optional helper accepts it, but
    # nothing in the happy path requires calling it.
    initiator, joiner = _make_pair()
    _run_to_confirmed(initiator, joiner)
    assert initiator.sas == joiner.sas
    initiator.confirm_peer_sas(joiner.sas)  # optional, does not raise
    # A mismatching value still aborts, for UIs that choose to use it.
    fresh_i, fresh_j = _make_pair()
    _run_to_confirmed(fresh_i, fresh_j)
    with pytest.raises(PairingError) as exc:
        fresh_j.confirm_peer_sas("000000" if fresh_j.sas != "000000" else "111111")
    assert exc.value.rejection is PairingRejection.SAS_MISMATCH


# --- tampered device key -----------------------------------------------------


def test_forged_device_key_mac_is_rejected():
    initiator, joiner = _make_pair()
    _run_to_confirmed(initiator, joiner)
    dev_j = joiner.create_device_key()
    dev_j["mac"] = base64.b64encode(b"\x00" * 32).decode()
    with pytest.raises(PairingError) as exc:
        initiator.on_peer_device_key(dev_j)
    assert exc.value.rejection is PairingRejection.MAC_MISMATCH
    assert initiator.state is PairingState.ABORTED


def test_forged_device_proof_is_rejected():
    initiator, joiner = _make_pair()
    _run_to_confirmed(initiator, joiner)
    # A device key whose MAC is valid but whose signature is for another key:
    # swap in a different Ed25519 public key, keep the (now stale) proof/mac by
    # recomputing the mac for the swapped key so only the signature fails.
    other = DeviceIdentity.generate()
    dev_j = joiner.create_device_key()
    # Recompute a matching mac for the swapped pubkey so the MAC check passes
    # and the signature check is what fails.
    from cowork_crypto.pairing import DEVICE_D_LABEL, _device_mac  # noqa: PLC0415

    t = initiator._current_transcript()  # noqa: SLF001 (test introspection)
    dev_j["ed25519_pub"] = other.export_public_key_base64()
    dev_j["mac"] = base64.b64encode(
        _device_mac(
            initiator._k_raw,  # noqa: SLF001
            DEVICE_D_LABEL,
            t,
            other.public_key_bytes(),
            "desktop-01",
            initiator.pairing_code,
        )
    ).decode()
    with pytest.raises(PairingError) as exc:
        initiator.on_peer_device_key(dev_j)
    assert exc.value.rejection is PairingRejection.BAD_DEVICE_PROOF
    assert initiator.state is PairingState.ABORTED


# --- expiry + single use -----------------------------------------------------


def test_expired_session_is_rejected():
    now = {"t": TS}
    initiator = Pairing.initiator(
        device_id="client-01",
        device_identity=DeviceIdentity.generate(),
        now_ms=lambda: now["t"],
        channel_id="chan0001",
        digits="428913",
        expiry_ms=120_000,
    )
    joiner = Pairing.joiner(
        device_id="desktop-01",
        device_identity=DeviceIdentity.generate(),
        pairing_code=initiator.pairing_code,
        now_ms=lambda: now["t"],
    )
    commit = initiator.create_commit()
    # Two minutes and a bit later the joiner tries to act on the code.
    now["t"] = TS + 120_001
    with pytest.raises(PairingError) as exc:
        joiner.on_commit(commit)
    assert exc.value.rejection is PairingRejection.EXPIRED


def test_single_use_completed_session_rejects_reuse():
    initiator, joiner = _make_pair()
    _run_to_confirmed(initiator, joiner)
    _exchange_device_keys(initiator, joiner)
    assert joiner.state is PairingState.COMPLETED
    # Any further step on a completed session is refused.
    with pytest.raises(PairingError) as exc:
        joiner.create_device_key()
    assert exc.value.rejection is PairingRejection.CONSUMED
    with pytest.raises(PairingError) as exc:
        initiator.create_commit()
    assert exc.value.rejection in (
        PairingRejection.CONSUMED,
        PairingRejection.WRONG_STATE,
    )


def test_aborted_session_rejects_further_steps():
    initiator, joiner = _make_pair()
    commit = initiator.create_commit()
    joiner.on_commit(commit)
    pubkey = joiner.create_pubkey()
    initiator.on_pubkey(pubkey)
    # Force an abort via a bad reveal.
    attacker = X25519PrivateKey.generate()
    with pytest.raises(PairingError):
        joiner.on_reveal(
            {
                "type": "reveal",
                "pubkey": base64.b64encode(
                    attacker.public_key().public_bytes_raw()
                ).decode(),
            }
        )
    assert joiner.state is PairingState.ABORTED
    with pytest.raises(PairingError) as exc:
        joiner.on_confirm_c({"type": "confirm-c", "mac": ""})
    assert exc.value.rejection is PairingRejection.CONSUMED


def test_channel_id_mismatch_is_rejected():
    initiator, _ = _make_pair()
    commit = initiator.create_commit()
    wrong_joiner = Pairing.joiner(
        device_id="desktop-01",
        device_identity=DeviceIdentity.generate(),
        pairing_code="different-428913",
        now_ms=_clock,
    )
    with pytest.raises(PairingError) as exc:
        wrong_joiner.on_commit(commit)
    assert exc.value.rejection is PairingRejection.CHANNEL_MISMATCH


# --- cross-language vector ---------------------------------------------------


def test_vector_reproduces_expected_values():
    vec = json.loads(FIXTURE.read_text())
    inp = vec["inputs"]
    exp = vec["expected"]

    a_priv = X25519PrivateKey.from_private_bytes(
        base64.b64decode(inp["initiator_x25519_seed_b64"])
    )
    b_priv = X25519PrivateKey.from_private_bytes(
        base64.b64decode(inp["joiner_x25519_seed_b64"])
    )
    init_id = DeviceIdentity.from_seed(base64.b64decode(inp["initiator_ed25519_seed_b64"]))
    join_id = DeviceIdentity.from_seed(base64.b64decode(inp["joiner_ed25519_seed_b64"]))

    initiator = Pairing.initiator(
        device_id=inp["initiator_device_id"],
        device_identity=init_id,
        sas_digits=inp["sas_digits"],
        now_ms=_clock,
        ephemeral_private=a_priv,
        channel_id=inp["channel_id"],
        digits=inp["digits"],
    )
    joiner = Pairing.joiner(
        device_id=inp["joiner_device_id"],
        device_identity=join_id,
        pairing_code=inp["pairing_code"],
        now_ms=_clock,
        ephemeral_private=b_priv,
    )

    commit = initiator.create_commit()
    assert commit["commitment"] == exp["commitment_b64"]
    joiner.on_commit(commit)
    pubkey = joiner.create_pubkey()
    reveal = initiator.on_pubkey(pubkey)
    confirm_d = joiner.on_reveal(reveal)
    assert confirm_d["mac"] == exp["mac_d_b64"]
    confirm_c = initiator.on_confirm_d(confirm_d)
    assert confirm_c["mac"] == exp["mac_c_b64"]
    joiner.on_confirm_c(confirm_c)

    assert initiator.sas == exp["sas"]
    assert joiner.sas == exp["sas"]
    assert base64.b64encode(initiator.channel_key).decode() == exp["channel_key_b64"]
    assert base64.b64encode(joiner.channel_key).decode() == exp["channel_key_b64"]
    assert commitment(base64.b64decode(inp["initiator_x25519_public_b64"])) == \
        base64.b64decode(exp["commitment_b64"])
