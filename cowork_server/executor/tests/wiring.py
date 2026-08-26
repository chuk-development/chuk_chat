"""Shared test wiring: a controller and an executor that share a derived channel
key and each other's approved Ed25519 device keys — the real pairing outcome,
with no network."""

from __future__ import annotations

from dataclasses import dataclass

from cowork_crypto import (
    ApprovedDevices,
    CoworkFrameOpener,
    CoworkFrameSealer,
    DeviceIdentity,
    derive_channel_key,
    generate_x25519_keypair,
)

CONTROLLER_DEVICE = "controller-phone"
EXECUTOR_DEVICE = "executor-laptop"
KEY_VERSION = 1


@dataclass
class Party:
    device_id: str
    sealer: CoworkFrameSealer
    opener: CoworkFrameOpener


@dataclass
class PairedChannel:
    channel_key: bytes
    controller: Party
    executor: Party


def paired_channel() -> PairedChannel:
    """Run the pairing math: X25519 ECDH -> one shared channel key, plus a mutual
    approval of Ed25519 device keys."""
    ctrl_priv, ctrl_pub = generate_x25519_keypair()
    exec_priv, exec_pub = generate_x25519_keypair()

    # Both sides derive the identical AES-256 channel key (symmetric ECDH).
    ck_controller = derive_channel_key(ctrl_priv, exec_pub)
    ck_executor = derive_channel_key(exec_priv, ctrl_pub)
    assert ck_controller == ck_executor
    channel_key = ck_controller

    ctrl_id = DeviceIdentity.generate()
    exec_id = DeviceIdentity.generate()

    # Executor approves the controller's signing key; controller approves the
    # executor's. Default deny otherwise.
    exec_approved = ApprovedDevices()
    exec_approved.approve(CONTROLLER_DEVICE, ctrl_id.public_key)
    ctrl_approved = ApprovedDevices()
    ctrl_approved.approve(EXECUTOR_DEVICE, exec_id.public_key)

    controller = Party(
        device_id=CONTROLLER_DEVICE,
        sealer=CoworkFrameSealer(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            device_id=CONTROLLER_DEVICE,
            signing_identity=ctrl_id,
        ),
        opener=CoworkFrameOpener(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            approved_devices=ctrl_approved,
        ),
    )
    executor = Party(
        device_id=EXECUTOR_DEVICE,
        sealer=CoworkFrameSealer(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            device_id=EXECUTOR_DEVICE,
            signing_identity=exec_id,
        ),
        opener=CoworkFrameOpener(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            approved_devices=exec_approved,
        ),
    )
    return PairedChannel(
        channel_key=channel_key, controller=controller, executor=executor
    )
