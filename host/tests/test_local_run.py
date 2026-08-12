"""The whole platform, in one process, over the real localhost relay, no prod.

A Python controller test-double plays the CoWork app: it joins the channel,
completes pairing as the **joiner**, provisions a MOCK account token, and sends a
task. The host pairs as the **initiator**, provisions from that token (a mock
model factory — no credits, no network to prod), and runs the task in a real
sandbox. We assert the controller gets decryptable ``tool`` + ``done`` frames and
that the command really ran (the file exists).
"""

from __future__ import annotations

import base64
import json
import time
from typing import Any

import pytest
from websockets.sync.client import connect

from cowork_agent import MockModelClient
from cowork_crypto import (
    ApprovedDevices,
    CoworkFrameOpener,
    CoworkFrameSealer,
    DeviceIdentity,
    Pairing,
    ReconnectHandshake,
)
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from cowork_executor import frame_to_b64, task_payload
from cowork_host import KEY_VERSION, LocalHost
from cowork_host.protocol import (
    STEP_CONFIRM_D,
    STEP_DEVICE_D,
    STEP_PUBKEY,
    STEP_RECONNECT_RESPONSE,
    frame_envelope,
    join_message,
    pairing_envelope,
)

APP_DEVICE_ID = "cowork-app"


class AppTrust:
    """What the app persists after a first pairing, so it can reconnect with no
    code: its own long-term identity, the host's device id + approved public key,
    the stable channel id and the established channel key."""

    def __init__(
        self,
        *,
        identity: DeviceIdentity,
        host_device_id: str,
        host_public_key: Ed25519PublicKey,
        channel_id: str,
        channel_key: bytes,
    ) -> None:
        self.identity = identity
        self.host_device_id = host_device_id
        self.host_public_key = host_public_key
        self.channel_id = channel_id
        self.channel_key = channel_key


def _scripted_model() -> MockModelClient:
    """First a run_command tool call, then a final answer — the one wire format a
    real backend model produces (a ``<tool_call>`` block in the content)."""
    return MockModelClient(
        [
            '<tool_call>{"name":"run_command",'
            '"arguments":{"command":"echo hello > f.txt"}}</tool_call>',
            "done",
        ]
    )


class ControllerDouble:
    """Plays the CoWork app over the relay: either a first-time joiner pairing (a
    code) or a code-free reconnect from a stored :class:`AppTrust`, then a token
    + a task. After a fresh pairing it can hand back its own trust so the same
    device can reconnect later."""

    def __init__(
        self,
        url: str,
        channel_id: str,
        pairing_code: str | None = None,
        *,
        reconnect_trust: AppTrust | None = None,
    ) -> None:
        self._url = url
        self._channel_id = channel_id
        self._reconnect_trust = reconnect_trust
        if reconnect_trust is not None:
            self._identity = reconnect_trust.identity
            self._pairing = None
            self._reconnect: ReconnectHandshake | None = ReconnectHandshake.joiner(
                device_id=APP_DEVICE_ID,
                device_identity=self._identity,
                peer_device_id=reconnect_trust.host_device_id,
                peer_public_key=reconnect_trust.host_public_key,
                channel_id=channel_id,
            )
        else:
            assert pairing_code is not None
            self._identity = DeviceIdentity.generate()
            self._pairing = Pairing.joiner(
                device_id=APP_DEVICE_ID,
                device_identity=self._identity,
                pairing_code=pairing_code,
            )
            self._reconnect = None
        self._sealer: CoworkFrameSealer | None = None
        self._opener: CoworkFrameOpener | None = None
        self._host_device_id: str | None = None
        self._host_public_key: Ed25519PublicKey | None = None
        self._channel_key: bytes | None = None
        self.raw_result_frames: list[str] = []

    def trust(self) -> AppTrust:
        """The trust record this device persists after a successful pairing."""
        assert self._host_device_id is not None
        assert self._host_public_key is not None
        assert self._channel_key is not None
        return AppTrust(
            identity=self._identity,
            host_device_id=self._host_device_id,
            host_public_key=self._host_public_key,
            channel_id=self._channel_id,
            channel_key=self._channel_key,
        )

    def run(self, prompt: str, *, timeout: float = 25.0) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        with connect(self._url, open_timeout=10.0) as ws:
            ws.send(json.dumps(join_message(self._channel_id, "controller")))
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    raw = ws.recv(timeout=2.0)
                except TimeoutError:
                    continue
                msg = json.loads(raw)
                kind = msg.get("type")
                if kind == "pairing":
                    self._on_pairing(ws, msg.get("data") or {}, prompt)
                elif kind == "frame":
                    self.raw_result_frames.append(msg["frame"])
                    payload = self._open(msg["frame"])
                    results.append(payload)
                    if payload.get("type") in ("done", "error"):
                        return results
        return results

    # -- joiner ceremony -------------------------------------------------

    def _on_pairing(self, ws, data: dict, prompt: str) -> None:
        step = data.get("type")
        # Reconnect flow (code-free) when this device has a stored trust.
        if self._reconnect is not None:
            if step == "reconnect-hello":
                response = self._reconnect.on_hello(data)
                ws.send(json.dumps(pairing_envelope(STEP_RECONNECT_RESPONSE, response)))
            elif step == "reconnect-confirm":
                self._reconnect.on_confirm(data)
                self._finish_reconnect()
                self._provision_and_task(ws, prompt)
            return
        # First-pair flow (code).
        p = self._pairing
        if step == "commit":
            p.on_commit(data)
            ws.send(json.dumps(pairing_envelope(STEP_PUBKEY, p.create_pubkey())))
        elif step == "reveal":
            confirm_d = p.on_reveal(data)
            ws.send(json.dumps(pairing_envelope(STEP_CONFIRM_D, confirm_d)))
        elif step == "confirm-c":
            p.on_confirm_c(data)
            device_d = p.create_device_key()
            ws.send(json.dumps(pairing_envelope(STEP_DEVICE_D, device_d)))
        elif step == "device-key":  # the host's device-c
            p.on_peer_device_key(data)
            self._finish_pairing()
            self._provision_and_task(ws, prompt)

    def _finish_pairing(self) -> None:
        channel_key = self._pairing.channel_key
        # Remember what the app would persist for a later reconnect.
        self._host_device_id = self._pairing.peer_device_id
        self._host_public_key = self._pairing.approved_devices.lookup(
            self._host_device_id
        )
        self._channel_key = channel_key
        self._build_codec(channel_key, self._pairing.approved_devices)

    def _finish_reconnect(self) -> None:
        trust = self._reconnect_trust
        assert trust is not None
        self._host_device_id = trust.host_device_id
        self._host_public_key = trust.host_public_key
        self._channel_key = trust.channel_key
        approved = ApprovedDevices.empty()
        approved.approve(trust.host_device_id, trust.host_public_key)
        self._build_codec(trust.channel_key, approved)

    def _build_codec(self, channel_key: bytes, approved: ApprovedDevices) -> None:
        self._sealer = CoworkFrameSealer(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            device_id=APP_DEVICE_ID,
            signing_identity=self._identity,
        )
        self._opener = CoworkFrameOpener(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            approved_devices=approved,
        )

    def _provision_and_task(self, ws, prompt: str) -> None:
        # Token first (§15 step 7), then the task — both ride sealed frames.
        token = {
            "type": "account_authentication",
            "access_token": "mock-access",
            "refresh_token": "mock-refresh",
            "user_id": "user-123",
        }
        ws.send(json.dumps(frame_envelope(self._seal(token))))
        ws.send(json.dumps(frame_envelope(self._seal(task_payload(prompt, "thread-1")))))

    # -- crypto helpers --------------------------------------------------

    def _seal(self, payload: dict) -> str:
        assert self._sealer is not None
        sealed = self._sealer.seal(json.dumps(payload, separators=(",", ":")).encode())
        return frame_to_b64(sealed.to_bytes())

    def _open(self, frame_b64: str) -> dict[str, Any]:
        assert self._opener is not None
        plaintext = self._opener.open(base64.b64decode(frame_b64))
        return json.loads(plaintext)


def test_full_local_run(tmp_path):
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="test-worker",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        assert host.pairing_code == "testchannel00-428913"
        controller = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        events = controller.run("run `echo hello > f.txt` then tell me done")
    finally:
        host.stop()

    types = [e["type"] for e in events]
    assert types, "controller received no frames"
    assert types[-1] == "done", f"stream did not end cleanly: {types}"

    tool_events = [e for e in events if e["type"] == "tool"]
    assert len(tool_events) == 1
    tool = tool_events[0]
    assert tool["name"] == "run_command"
    assert tool["command"] == "echo hello > f.txt"
    assert tool["exit_code"] == 0
    assert tool["timed_out"] is False

    done = events[-1]
    assert done["final_answer"] == "done"
    assert done["reason"] == "finished"

    # The command really ran in the agent's real sandbox workspace.
    produced = tmp_path / "agents" / "test-worker" / "f.txt"
    assert produced.exists(), "sandbox did not run the command"
    assert produced.read_text().strip() == "hello"


def test_result_frames_are_sealed_and_authenticated(tmp_path):
    """Every result frame the app receives is opaque to a stranger: the relay is
    blind, the frames are genuinely encrypted + device-authenticated."""
    from cowork_crypto import ApprovedDevices, CoworkFrameRejected

    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="w",
        channel_id="chanstranger0",
        digits="000000",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        controller = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        events = controller.run("run `echo hi > f.txt` then say done")
        assert events and events[-1]["type"] == "done"
    finally:
        host.stop()

    assert controller.raw_result_frames, "no result frames captured off the wire"

    # A stranger holding the right channel key but an empty trust store (default
    # deny) still cannot open a frame — device approval is required.
    channel_key = controller._pairing.channel_key
    stranger = CoworkFrameOpener(
        channel_key=channel_key,
        key_version=KEY_VERSION,
        approved_devices=ApprovedDevices(),
    )
    sealed = base64.b64decode(controller.raw_result_frames[0])
    assert b"final_answer" not in sealed  # plaintext never on the wire
    with pytest.raises(CoworkFrameRejected):
        stranger.open(sealed)


def _assert_ran(events: list[dict[str, Any]]) -> None:
    types = [e["type"] for e in events]
    assert types, "controller received no frames"
    assert types[-1] == "done", f"stream did not end cleanly: {types}"
    tools = [e for e in events if e["type"] == "tool"]
    assert len(tools) == 1 and tools[0]["exit_code"] == 0


def test_stress_first_pair_then_many_reconnects(tmp_path):
    """One long-lived host: the first controller pairs from the code, then the
    same device reconnects nineteen more times back to back with NO code. Each
    reconnect must authenticate off the stored device keys and run the task to a
    clean ``done``. Regression net for the reconnect session lifecycle: a fresh
    reconnect session is minted per connection, so 20/20 pass deterministically."""
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="stress-worker",
        channel_id="stresschannel",
        digits="428913",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        # First connection: a real pairing from the code. It persists trust.
        first = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        events = first.run("run `echo hi > f.txt` then say done", timeout=15.0)
        assert events and events[-1]["type"] == "done", (
            f"first pairing did not complete: {[e['type'] for e in events]}"
        )
        _assert_ran(events)
        assert host.has_stored_pairing
        trust = first.trust()

        # Nineteen code-free reconnects of the SAME device.
        for i in range(1, 20):
            controller = ControllerDouble(
                host.url, host.channel_id, reconnect_trust=trust
            )
            events = controller.run(
                "run `echo hi > f.txt` then say done", timeout=15.0
            )
            assert events and events[-1]["type"] == "done", (
                f"reconnect {i} did not authenticate+complete: "
                f"{[e['type'] for e in events]}"
            )
            _assert_ran(events)
    finally:
        host.stop()


def test_first_pair_then_both_restart_and_reconnect_no_code(tmp_path):
    """The whole persistent-pairing loop. A host + app pair from a code and run a
    task. Then BOTH restart: a brand-new LocalHost on the same workspace (so it
    loads the stored trust and prints no code) and a fresh controller built only
    from the app's stored trust reconnect with NO code and run another task.

    This is the end-to-end proof that pairing survives restarts of either side.
    """
    workspace = str(tmp_path)

    # --- first pairing (a code) -------------------------------------------
    host = LocalHost(
        port=0,
        workspace_dir=workspace,
        agent_name="persist-worker",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        assert not host.has_stored_pairing
        first = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        events = first.run("run `echo hi > f.txt` then say done", timeout=15.0)
        _assert_ran(events)
        assert host.has_stored_pairing, "host did not persist the pairing"
        channel_id = host.channel_id
        trust = first.trust()
    finally:
        host.stop()

    # The trust file is really on disk under the workspace.
    assert (tmp_path / "paired.json").exists()

    # --- both restart, reconnect with no code -----------------------------
    host2 = LocalHost(
        port=0,
        workspace_dir=workspace,
        agent_name="persist-worker",
        model_factory_override=_scripted_model,
    )
    host2.start()
    try:
        # Same host identity → same stable channel id, and it is in reconnect
        # mode (a code is not printed / used).
        assert host2.has_stored_pairing
        assert host2.channel_id == channel_id
        controller = ControllerDouble(
            host2.url, host2.channel_id, reconnect_trust=trust
        )
        events = controller.run("run `echo hi > f.txt` then say done", timeout=15.0)
        assert events and events[-1]["type"] == "done", (
            f"reconnect did not complete: {[e['type'] for e in events]}"
        )
        _assert_ran(events)
    finally:
        host2.stop()


def test_reconnect_after_a_dropped_attempt_still_pairs(tmp_path):
    """A controller connects, takes the commit, then drops WITHOUT pairing. A new
    controller on the same host must still pair cleanly — the stable code is
    reused but a fresh, unconsumed, non-expired session is minted for it."""
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="reconnect-worker",
        channel_id="reconnectchan",
        digits="428913",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        # First controller: join, receive the host's commit, then vanish.
        with connect(host.url, open_timeout=10.0) as ws:
            ws.send(json.dumps(join_message(host.channel_id, "controller")))
            first = json.loads(ws.recv(timeout=5.0))
            assert first["type"] == "pairing"
        time.sleep(0.2)  # let the host observe the drop and reset

        # Second controller: a full, fresh pairing + task on the same host.
        controller = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        events = controller.run("run `echo hi > f.txt` then say done", timeout=15.0)
        assert events and events[-1]["type"] == "done", (
            f"reconnect did not pair+complete: {[e['type'] for e in events]}"
        )
        _assert_ran(events)
    finally:
        host.stop()
