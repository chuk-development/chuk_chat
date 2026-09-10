"""Independent account devices; no cloned identity and no shared replay guard."""

import base64
import json

import pytest
from cowork_crypto import ApprovedDevices, CoworkFrameOpener, CoworkFrameSealer
from cowork_crypto.device_keys import DeviceIdentity
from cowork_crypto.frame import CoworkFrameRejected
from cowork_host.controller_sessions import ControllerSessions, b64, mac, transcript
from cowork_host.pairing_store import HostTrust
from cowork_host.cloud_party import _OpenedFrames


def controller(host, device, identity=None):
    identity = identity or DeviceIdentity.generate()
    request = dict(
        type="controller_resume",
        channel="shared",
        device_id=device,
        public_key=identity.export_public_key_base64(),
        client_nonce=b64(bytes(range(32))),
    )
    challenge = host.challenge(request)
    signed = transcript(
        "shared",
        device,
        request["public_key"],
        request["client_nonce"],
        challenge["host_nonce"],
    )
    host.identity.public_key.verify(
        base64.b64decode(challenge["signature"]), b"cowork/controller/host/" + signed
    )
    proof = dict(
        connection=challenge["connection"],
        proof=b64(mac(host.trust.channel_key, "cowork/controller/approve/", signed)),
        signature=b64(identity.sign(b"cowork/controller/device/" + signed)),
    )
    ready = host.confirm(proof)
    key = mac(host.trust.channel_key, "cowork/controller/traffic/", signed)
    assert ready["proof"] == b64(mac(key, "cowork/controller/ready/", signed))
    approved = ApprovedDevices.empty()
    approved.approve("host", host.identity.public_key)
    return (
        identity,
        proof,
        CoworkFrameSealer(
            channel_key=key, key_version=1, device_id=device, signing_identity=identity
        ),
        CoworkFrameOpener(channel_key=key, key_version=1, approved_devices=approved),
    )


@pytest.fixture
def host():
    desktop = DeviceIdentity.generate()
    return ControllerSessions(
        HostTrust("shared", b"x" * 32, "desktop", desktop.public_key),
        DeviceIdentity.generate(),
        "host",
    )


def test_two_devices_reconnect_and_broadcast(host):
    desktop = controller(host, "desktop")
    phone = controller(host, "phone")
    assert desktop[0].public_key_bytes() != phone[0].public_key_bytes()
    assert host.open(desktop[2].seal(b'{"type":"agent_create"}'))
    assert host.open(phone[2].seal(b'{"type":"agent_list"}'))
    batch = host.seal(b'{"type":"agent_list","agents":[{"id":"new"}]}')
    assert batch.broadcast
    for item, client in zip(batch.frames, [desktop, phone]):
        assert (
            json.loads(client[3].open(base64.b64decode(item["frame"])))["agents"][0][
                "id"
            ]
            == "new"
        )
    old = phone[2].seal(b'{"type":"stop"}')
    controller(host, "phone", phone[0])
    # Phone reconnect invalidates old traffic but leaves desktop live.
    with pytest.raises(CoworkFrameRejected):
        host.open(old)
    assert host.open(desktop[2].seal(b'{"type":"agent_list"}'))


def test_proof_and_frame_replays_rejected(host):
    client = controller(host, "phone")
    with pytest.raises(ValueError):
        host.confirm(client[1])
    frame = client[2].seal(b"{}")
    assert host.open(frame) == b"{}"
    with pytest.raises(CoworkFrameRejected):
        host.open(frame)


def test_unknown_device_cannot_send_frame(host):
    rogue = CoworkFrameSealer(
        channel_key=host.trust.channel_key,
        key_version=1,
        device_id="rogue",
        signing_identity=DeviceIdentity.generate(),
    )
    with pytest.raises(CoworkFrameRejected):
        host.open(rogue.seal(b"{}"))


def test_missing_recovery_capability_cannot_enroll(host):
    identity = DeviceIdentity.generate()
    request = dict(
        channel="shared",
        device_id="rogue",
        public_key=identity.export_public_key_base64(),
        client_nonce=b64(b"n" * 32),
    )
    challenge = host.challenge(request)
    with pytest.raises(ValueError):
        host.confirm(
            dict(
                connection=challenge["connection"],
                proof=b64(b"?" * 32),
                signature=b64(b"?" * 64),
            )
        )
    assert not host.sessions


def test_executor_tickets_are_one_use_and_bounded():
    opener = _OpenedFrames()
    raw = base64.b64decode(opener.put(b"private payload"))
    assert opener.open(raw) == b"private payload"
    with pytest.raises(CoworkFrameRejected):
        opener.open(raw)
    for _ in range(1024):
        opener.put(b"x")
    with pytest.raises(ValueError):
        opener.put(b"x")


def test_real_executor_broadcasts_new_agent_to_both_devices_under_one_second(tmp_path):
    import queue
    import time
    from cowork_host import LocalHost
    from cowork_host.cloud_party import CloudHostParty
    from cowork_agent import MockModelClient

    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        model_factory_override=lambda: MockModelClient(["unused"]),
    )
    desktop_key = DeviceIdentity.generate()
    trust = HostTrust("shared", b"x" * 32, "desktop", desktop_key.public_key)
    party = CloudHostParty(
        transport=None,
        channel_id="shared",
        pairing_factory=lambda: None,
        device_id="host",
        device_identity=host._identity,
        key_version=1,
        build_task_server=host._build_task_server,
        trust_provider=lambda: trust,
        on_reprovision=host._on_reprovision,
    )
    host._party = party
    wire = queue.Queue()
    party._send = wire.put
    desktop = controller(party._sessions(), "desktop", desktop_key)
    phone = controller(party._sessions(), "phone")

    def send(client, payload):
        party._handle(
            dict(
                type="controller_frame",
                frame=b64(client[2].seal(json.dumps(payload).encode()).to_bytes()),
            )
        )

    try:
        send(
            desktop,
            dict(type="account_authentication", access_token="test", user_id="test"),
        )
        assert party.task_server is not None
        executor = party.task_server
        send(
            phone,
            dict(type="account_authentication", access_token="test", user_id="test"),
        )
        assert party.task_server is executor
        started = time.monotonic()
        send(
            desktop,
            dict(type="agent_create", agent_id="local:new", name="Shared coworker"),
        )
        seen = set()
        clients = {
            party._sessions().sessions["desktop"].connection: ("desktop", desktop),
            party._sessions().sessions["phone"].connection: ("phone", phone),
        }
        while len(seen) < 2:
            envelope = wire.get(timeout=max(0.01, 1 - (time.monotonic() - started)))
            device, client = clients[envelope["connection"]]
            payload = json.loads(client[3].open(base64.b64decode(envelope["frame"])))
            if payload["type"] == "agent_list":
                assert any(a["agent_id"] == "local:new" for a in payload["agents"])
                seen.add(device)
        assert time.monotonic() - started < 1
    finally:
        host.stop()
