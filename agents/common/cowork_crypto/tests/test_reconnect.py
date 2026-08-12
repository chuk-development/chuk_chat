"""Reconnect handshake tests — the full mutual signed-nonce challenge in
process, the imposter-rejection paths (a forged signature on either side is
refused and no channel resumes), and the cross-language vector.

The wire messages ride the real relay later; here they are handed straight from
one role to the other, which is exactly the surface a relay would carry.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from cowork_crypto import (
    DeviceIdentity,
    ReconnectError,
    ReconnectHandshake,
    ReconnectRejection,
    ReconnectState,
)

FIXTURE = Path(__file__).parent / "fixtures" / "reconnect_vectors.json"

HOST_ID = "cowork-host"
APP_ID = "desktop-01"
CHANNEL = "chan0001deadbeef"


def _make_pair(*, host_id=None, app_id=None, channel=CHANNEL):
    """A fresh initiator (host) + joiner (app), each seeded from the other's
    long-term public key exactly as a stored trust record would provide."""
    host_id = host_id or HOST_ID
    app_id = app_id or APP_ID
    host_identity = DeviceIdentity.generate()
    app_identity = DeviceIdentity.generate()
    initiator = ReconnectHandshake.initiator(
        device_id=host_id,
        device_identity=host_identity,
        peer_device_id=app_id,
        peer_public_key=app_identity.public_key,
        channel_id=channel,
    )
    joiner = ReconnectHandshake.joiner(
        device_id=app_id,
        device_identity=app_identity,
        peer_device_id=host_id,
        peer_public_key=host_identity.public_key,
        channel_id=channel,
    )
    return initiator, joiner


def _run(initiator: ReconnectHandshake, joiner: ReconnectHandshake):
    hello = initiator.create_hello()
    response = joiner.on_hello(hello)
    confirm = initiator.on_response(response)
    joiner.on_confirm(confirm)


# --- happy path --------------------------------------------------------------


def test_happy_path_mutually_authenticates():
    initiator, joiner = _make_pair()
    _run(initiator, joiner)
    assert initiator.authenticated
    assert joiner.authenticated
    assert initiator.state is ReconnectState.AUTHENTICATED
    assert joiner.state is ReconnectState.AUTHENTICATED
    assert initiator.peer_device_id == APP_ID
    assert joiner.peer_device_id == HOST_ID


# --- imposter rejection: the whole point of the ceremony ---------------------


def test_imposter_joiner_without_private_key_is_rejected():
    """An attacker connects claiming to be the app but holds neither the app's
    long-term private key. The host stored the real app pubkey, so the forged
    proof fails to verify and the host aborts with no channel."""
    host_identity = DeviceIdentity.generate()
    real_app = DeviceIdentity.generate()
    imposter = DeviceIdentity.generate()  # attacker's own key, not approved

    initiator = ReconnectHandshake.initiator(
        device_id=HOST_ID,
        device_identity=host_identity,
        peer_device_id=APP_ID,
        peer_public_key=real_app.public_key,  # host trusts the REAL app key
        channel_id=CHANNEL,
    )
    # The imposter runs a joiner with its OWN key but claims the app's device id.
    imposter_joiner = ReconnectHandshake.joiner(
        device_id=APP_ID,
        device_identity=imposter,
        peer_device_id=HOST_ID,
        peer_public_key=host_identity.public_key,
        channel_id=CHANNEL,
    )

    hello = initiator.create_hello()
    response = imposter_joiner.on_hello(hello)  # signs with the imposter key
    with pytest.raises(ReconnectError) as exc:
        initiator.on_response(response)
    assert exc.value.rejection is ReconnectRejection.BAD_SIGNATURE
    assert initiator.state is ReconnectState.ABORTED
    assert not initiator.authenticated


def test_imposter_host_without_private_key_is_rejected():
    """An attacker plays the host toward the app but does not hold the host's
    long-term private key. The app stored the real host pubkey, so the forged
    confirm fails to verify and the app aborts with no channel."""
    real_host = DeviceIdentity.generate()
    app_identity = DeviceIdentity.generate()
    imposter = DeviceIdentity.generate()

    joiner = ReconnectHandshake.joiner(
        device_id=APP_ID,
        device_identity=app_identity,
        peer_device_id=HOST_ID,
        peer_public_key=real_host.public_key,  # app trusts the REAL host key
        channel_id=CHANNEL,
    )
    imposter_initiator = ReconnectHandshake.initiator(
        device_id=HOST_ID,
        device_identity=imposter,
        peer_device_id=APP_ID,
        peer_public_key=app_identity.public_key,
        channel_id=CHANNEL,
    )

    hello = imposter_initiator.create_hello()
    response = joiner.on_hello(hello)
    confirm = imposter_initiator.on_response(response)  # signs with imposter key
    with pytest.raises(ReconnectError) as exc:
        joiner.on_confirm(confirm)
    assert exc.value.rejection is ReconnectRejection.BAD_SIGNATURE
    assert joiner.state is ReconnectState.ABORTED
    assert not joiner.authenticated


def test_tampered_nonce_breaks_the_signature():
    """Flipping a byte of the response nonce changes the transcript the host
    verifies over, so the (valid-for-the-original) proof no longer verifies."""
    initiator, joiner = _make_pair()
    hello = initiator.create_hello()
    response = joiner.on_hello(hello)
    raw = base64.b64decode(response["nonce"])
    tampered = bytes([raw[0] ^ 0x01]) + raw[1:]
    response["nonce"] = base64.b64encode(tampered).decode()
    with pytest.raises(ReconnectError) as exc:
        initiator.on_response(response)
    assert exc.value.rejection is ReconnectRejection.BAD_SIGNATURE


def test_replayed_proof_from_another_session_is_rejected():
    """A proof captured from an earlier reconnect has that session's nonces; the
    fresh session has new nonces, so the replayed signature fails to verify."""
    host_identity = DeviceIdentity.generate()
    app_identity = DeviceIdentity.generate()

    def fresh_initiator():
        return ReconnectHandshake.initiator(
            device_id=HOST_ID,
            device_identity=host_identity,
            peer_device_id=APP_ID,
            peer_public_key=app_identity.public_key,
            channel_id=CHANNEL,
        )

    def fresh_joiner():
        return ReconnectHandshake.joiner(
            device_id=APP_ID,
            device_identity=app_identity,
            peer_device_id=HOST_ID,
            peer_public_key=host_identity.public_key,
            channel_id=CHANNEL,
        )

    # Session 1: capture the app's real response (a genuine proof_j).
    init1, join1 = fresh_initiator(), fresh_joiner()
    captured = join1.on_hello(init1.create_hello())

    # Session 2: a new host challenge with a new nonce. Replaying the captured
    # response (old nonce + old proof) must not authenticate.
    init2 = fresh_initiator()
    init2.create_hello()
    with pytest.raises(ReconnectError) as exc:
        init2.on_response(captured)
    assert exc.value.rejection is ReconnectRejection.BAD_SIGNATURE


def test_reflection_the_peers_own_proof_cannot_stand_in_for_the_other_role():
    """Reflection attack. An imposter host holds no private key, so it cannot
    produce ``proof_i``. All it has is the ``proof_j`` the app just sent it, over
    the very same transcript. Bouncing that straight back as the confirm must
    fail: the two roles sign under DIFFERENT labels, so a signature made as the
    joiner never verifies as the initiator."""
    initiator, joiner = _make_pair()
    hello = initiator.create_hello()
    response = joiner.on_hello(hello)

    reflected = {"type": "reconnect-confirm", "sig": response["sig"]}
    with pytest.raises(ReconnectError) as exc:
        joiner.on_confirm(reflected)
    assert exc.value.rejection is ReconnectRejection.BAD_SIGNATURE
    assert joiner.state is ReconnectState.ABORTED
    assert not joiner.authenticated


def test_reflection_the_initiators_proof_cannot_stand_in_for_the_joiners():
    """The mirror image: the host's genuine ``proof_i``, replayed by an imposter
    app as its ``proof_j`` on the same transcript, is refused as well. Neither
    label can be swapped for the other in either direction."""
    host_identity = DeviceIdentity.generate()
    app_identity = DeviceIdentity.generate()

    def fresh_initiator():
        return ReconnectHandshake.initiator(
            device_id=HOST_ID,
            device_identity=host_identity,
            peer_device_id=APP_ID,
            peer_public_key=app_identity.public_key,
            channel_id=CHANNEL,
        )

    # Session 1: run it through so we hold a genuine proof_i for a known
    # transcript, plus the joiner nonce that produced it.
    init1 = fresh_initiator()
    joiner1 = ReconnectHandshake.joiner(
        device_id=APP_ID,
        device_identity=app_identity,
        peer_device_id=HOST_ID,
        peer_public_key=host_identity.public_key,
        channel_id=CHANNEL,
    )
    hello1 = init1.create_hello()
    response1 = joiner1.on_hello(hello1)
    confirm1 = init1.on_response(response1)

    # A second host session that happens to reuse the SAME nonce — the strongest
    # form of the attack, where the transcript matches exactly. Presenting the
    # host's own proof_i as the app's proof_j still fails on the label.
    init2 = ReconnectHandshake.initiator(
        device_id=HOST_ID,
        device_identity=host_identity,
        peer_device_id=APP_ID,
        peer_public_key=app_identity.public_key,
        channel_id=CHANNEL,
        nonce=base64.b64decode(hello1["nonce"]),
    )
    init2.create_hello()
    forged = dict(response1)
    forged["sig"] = confirm1["sig"]
    with pytest.raises(ReconnectError) as exc:
        init2.on_response(forged)
    assert exc.value.rejection is ReconnectRejection.BAD_SIGNATURE
    assert init2.state is ReconnectState.ABORTED


# --- structural rejections ---------------------------------------------------


def test_channel_mismatch_is_rejected():
    initiator, _ = _make_pair()
    other_app = DeviceIdentity.generate()
    joiner = ReconnectHandshake.joiner(
        device_id=APP_ID,
        device_identity=other_app,
        peer_device_id=HOST_ID,
        peer_public_key=DeviceIdentity.generate().public_key,
        channel_id="a-different-channel",
    )
    hello = initiator.create_hello()
    with pytest.raises(ReconnectError) as exc:
        joiner.on_hello(hello)
    assert exc.value.rejection is ReconnectRejection.CHANNEL_MISMATCH


def test_wrong_peer_device_id_is_rejected():
    host_identity = DeviceIdentity.generate()
    app_identity = DeviceIdentity.generate()
    initiator = ReconnectHandshake.initiator(
        device_id=HOST_ID,
        device_identity=host_identity,
        peer_device_id=APP_ID,
        peer_public_key=app_identity.public_key,
        channel_id=CHANNEL,
    )
    # The joiner announces a different device id than the host has stored.
    joiner = ReconnectHandshake.joiner(
        device_id="someone-else",
        device_identity=app_identity,
        peer_device_id=HOST_ID,
        peer_public_key=host_identity.public_key,
        channel_id=CHANNEL,
    )
    hello = initiator.create_hello()
    response = joiner.on_hello(hello)
    with pytest.raises(ReconnectError) as exc:
        initiator.on_response(response)
    assert exc.value.rejection is ReconnectRejection.WRONG_PEER


def test_steps_out_of_order_are_refused():
    initiator, joiner = _make_pair()
    # Joiner cannot confirm before it has answered a hello.
    with pytest.raises(ReconnectError) as exc:
        joiner.on_confirm({"type": "reconnect-confirm", "sig": ""})
    assert exc.value.rejection is ReconnectRejection.WRONG_STATE
    # Initiator cannot answer a response before it has sent a hello.
    with pytest.raises(ReconnectError) as exc:
        initiator.on_response({"type": "reconnect-response"})
    assert exc.value.rejection is ReconnectRejection.WRONG_STATE


def test_authenticated_session_refuses_reuse():
    initiator, joiner = _make_pair()
    _run(initiator, joiner)
    with pytest.raises(ReconnectError) as exc:
        initiator.create_hello()
    assert exc.value.rejection is ReconnectRejection.WRONG_STATE
    with pytest.raises(ReconnectError) as exc:
        joiner.on_confirm({"type": "reconnect-confirm", "sig": ""})
    assert exc.value.rejection is ReconnectRejection.WRONG_STATE


# --- cross-language vector ---------------------------------------------------


def test_vector_reproduces_expected_values():
    vec = json.loads(FIXTURE.read_text())
    inp = vec["inputs"]
    exp = vec["expected"]

    init_id = DeviceIdentity.from_seed(base64.b64decode(inp["initiator_ed25519_seed_b64"]))
    join_id = DeviceIdentity.from_seed(base64.b64decode(inp["joiner_ed25519_seed_b64"]))

    initiator = ReconnectHandshake.initiator(
        device_id=inp["initiator_device_id"],
        device_identity=init_id,
        peer_device_id=inp["joiner_device_id"],
        peer_public_key=join_id.public_key,
        channel_id=inp["channel_id"],
        nonce=base64.b64decode(inp["initiator_nonce_b64"]),
    )
    joiner = ReconnectHandshake.joiner(
        device_id=inp["joiner_device_id"],
        device_identity=join_id,
        peer_device_id=inp["initiator_device_id"],
        peer_public_key=init_id.public_key,
        channel_id=inp["channel_id"],
        nonce=base64.b64decode(inp["joiner_nonce_b64"]),
    )

    hello = initiator.create_hello()
    assert hello == exp["hello_msg"]
    response = joiner.on_hello(hello)
    assert response["sig"] == exp["proof_j_b64"]
    assert response == exp["response_msg"]
    confirm = initiator.on_response(response)
    assert confirm["sig"] == exp["proof_i_b64"]
    assert confirm == exp["confirm_msg"]
    joiner.on_confirm(confirm)

    assert initiator.authenticated and joiner.authenticated
