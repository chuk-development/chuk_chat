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
import threading
import time
from pathlib import Path
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

from cowork_executor import frame_to_b64, stop_payload, task_payload
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
        stop_when: threading.Event | None = None,
    ) -> None:
        self._url = url
        self._channel_id = channel_id
        self._reconnect_trust = reconnect_trust
        # When set, this double presses Stop as soon as the event fires.
        self._stop_when = stop_when
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
        if self._stop_when is not None:
            # The app's Stop button: pressed once the run is provably working,
            # and sent as a plain sealed frame like everything else.
            assert self._stop_when.wait(15.0), "the run never started"
            ws.send(
                json.dumps(
                    frame_envelope(self._seal(stop_payload(session_key="thread-1")))
                )
            )

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


def _docker_ready() -> bool:
    from cowork_sandbox import docker_available

    return docker_available()


@pytest.mark.skipif(not _docker_ready(), reason="docker CLI or daemon unavailable")
def test_full_run_inside_the_agents_container(tmp_path, monkeypatch):
    """The same end-to-end run, but the agent's shell is a container (§6).

    Proves the milestone's three pieces at once: the container is created for
    *this* agent, its workspace is bind-mounted (the file appears on the host),
    and the box survives the session for the next turn to reuse.
    """
    import os

    from cowork_sandbox import DockerEnvironment, find_agent_container

    image = os.environ.get("COWORK_TEST_IMAGE", "debian:stable-slim")
    monkeypatch.setenv("COWORK_SANDBOX_IMAGE", image)

    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="dockerworker",
        channel_id="dockerchannel",
        digits="314159",
        sandbox_kind="docker",
        model_factory_override=_scripted_model,
    )
    agent_id = host.agent.id
    host.start()
    try:
        controller = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        events = controller.run("run `echo hello > f.txt` then tell me done")
    finally:
        host.stop()

    try:
        assert [e["type"] for e in events][-1] == "done", events
        tool = [e for e in events if e["type"] == "tool"][0]
        assert tool["exit_code"] == 0, tool

        # The container wrote into the bind-mounted workspace, so the HOST sees it.
        produced = tmp_path / "agents" / "dockerworker" / "f.txt"
        assert produced.exists(), "the container's workspace is not the host's"
        assert produced.read_text().strip() == "hello"

        # The agent's box is still there after the session — that is the reuse
        # contract; only the orphan reaper or an explicit destroy removes it.
        assert find_agent_container(agent_id=agent_id) is not None
    finally:
        DockerEnvironment(agent_id=agent_id, image=image).remove()


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


def _hello_or_none(url: str, channel_id: str, timeout: float = 5.0):
    """Join a host's channel as a bare controller and return the first pairing
    envelope's ``data`` (or ``None`` if the host offers nothing)."""
    with connect(url, open_timeout=10.0) as ws:
        ws.send(json.dumps(join_message(channel_id, "controller")))
        try:
            msg = json.loads(ws.recv(timeout=timeout))
        except TimeoutError:
            return None
    return msg.get("data") if msg.get("type") == "pairing" else None


def test_a_used_pairing_code_is_dead_forever(tmp_path):
    """SINGLE USE. A code buys exactly one pairing. Afterwards the host destroys
    it: it is no longer readable, no commit is ever published again, and a thief
    who copied the code off the screen gets nothing but a reconnect challenge it
    cannot answer."""
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="single-use-worker",
        channel_id="singleusechan",
        digits="428913",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        code = host.pairing_code
        assert code == "singleusechan-428913"

        first = ControllerDouble(host.url, host.channel_id, code)
        _assert_ran(first.run("run `echo hi > f.txt` then say done", timeout=15.0))
        assert host.has_stored_pairing

        # The code no longer exists — not even the host can hand it out.
        assert host.pairing_code is None
        # ...and no session can be minted from it any more.
        assert host._pairing_factory() is None

        time.sleep(0.3)  # let the host observe the drop and reset the session

        # A second device typing the SAME code is met with a reconnect challenge,
        # never a pairing commit. There is no ceremony left to join.
        data = _hello_or_none(host.url, host.channel_id)
        assert data is not None
        assert data["type"] == "reconnect-hello", (
            f"host offered {data['type']!r} — a used code must never re-open"
        )

        time.sleep(0.3)
        # And the thief, driving the full joiner ceremony from the stolen code,
        # completes nothing and receives no frames.
        thief = ControllerDouble(host.url, host.channel_id, code)
        assert thief.run("take over the machine", timeout=6.0) == []
    finally:
        host.stop()


def test_burning_the_code_is_idempotent_and_stops_new_sessions(tmp_path):
    """The burn is a one-way door at the unit level: once consumed, no further
    initiator session is ever minted, and burning again is a no-op."""
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="burn-worker",
        channel_id="burnchannel00",
        digits="111111",
        model_factory_override=_scripted_model,
    )
    assert host.pairing_code == "burnchannel00-111111"
    assert host._pairing_factory() is not None
    assert host._burn_pairing_code() is True
    assert host.pairing_code is None
    assert host._pairing_factory() is None
    assert host._burn_pairing_code() is False


def test_an_already_paired_host_never_mints_a_code(tmp_path):
    """A host that starts with a stored trust has no code at all — nothing is
    generated, printed, or accepted. The only way in is the signed reconnect."""
    workspace = str(tmp_path)
    host = LocalHost(
        port=0,
        workspace_dir=workspace,
        agent_name="nocode-worker",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        assert host.pairing_code is not None
        first = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        _assert_ran(first.run("run `echo hi > f.txt` then say done", timeout=15.0))
        assert host.has_stored_pairing
    finally:
        host.stop()

    host2 = LocalHost(
        port=0,
        workspace_dir=workspace,
        agent_name="nocode-worker",
        model_factory_override=_scripted_model,
    )
    assert host2.has_stored_pairing
    assert host2.pairing_code is None
    assert host2._pairing_factory() is None


def test_force_repair_mints_one_fresh_code_and_the_old_one_stays_dead(tmp_path):
    """`cowork-host --pair` is the deliberate way back to a code. It drops the
    stored trust and mints ONE new code; the old code is not reinstated."""
    workspace = str(tmp_path)
    host = LocalHost(
        port=0,
        workspace_dir=workspace,
        agent_name="repair-worker",
        channel_id="repairchannel",
        digits="222222",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        old_code = host.pairing_code
        first = ControllerDouble(host.url, host.channel_id, old_code)
        _assert_ran(first.run("run `echo hi > f.txt` then say done", timeout=15.0))
        assert host.pairing_code is None
    finally:
        host.stop()

    host2 = LocalHost(
        port=0,
        workspace_dir=workspace,
        agent_name="repair-worker",
        channel_id="repairchannel",
        force_repair=True,
        model_factory_override=_scripted_model,
    )
    host2.start()
    try:
        assert not host2.has_stored_pairing
        assert not (tmp_path / "paired.json").exists()
        new_code = host2.pairing_code
        assert new_code is not None
        assert new_code != old_code, "--pair must not reinstate the burned code"
        # A brand-new device pairs on the new code.
        second = ControllerDouble(host2.url, host2.channel_id, new_code)
        _assert_ran(second.run("run `echo hi > f.txt` then say done", timeout=15.0))
        assert host2.pairing_code is None, "the new code is single-use too"
    finally:
        host2.stop()


def test_an_imposter_device_cannot_reconnect_and_gets_no_channel(tmp_path):
    """IDENTITY, NOT ADDRESS. After pairing, an attacker who knows the channel id
    AND has stolen the channel key still cannot get in: the reconnect verifies a
    signature against the app's stored Ed25519 key, and the host builds no frame
    codec until it does. Sealed frames sent without authenticating are dropped —
    and the genuine device still reconnects afterwards."""
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="imposter-worker",
        channel_id="imposterchan",
        digits="428913",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        first = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        _assert_ran(first.run("run `echo hi > f.txt` then say done", timeout=15.0))
        trust = first.trust()
        time.sleep(0.3)

        # 1. Forged identity: the real channel + the real host key + the STOLEN
        #    channel key, but the attacker's own device key. The handshake dies.
        forged = AppTrust(
            identity=DeviceIdentity.generate(),
            host_device_id=trust.host_device_id,
            host_public_key=trust.host_public_key,
            channel_id=trust.channel_id,
            channel_key=trust.channel_key,
        )
        imposter = ControllerDouble(
            host.url, host.channel_id, reconnect_trust=forged
        )
        assert imposter.run("exfiltrate everything", timeout=6.0) == []
        time.sleep(0.3)

        # 2. Skip the handshake entirely and just push sealed frames with the
        #    stolen channel key. Without an authenticated session the host has no
        #    opener, so nothing is served and nothing comes back.
        rogue_identity = DeviceIdentity.generate()
        sealer = CoworkFrameSealer(
            channel_key=trust.channel_key,
            key_version=KEY_VERSION,
            device_id=APP_DEVICE_ID,
            signing_identity=rogue_identity,
        )

        def seal(payload: dict) -> str:
            sealed = sealer.seal(json.dumps(payload, separators=(",", ":")).encode())
            return frame_to_b64(sealed.to_bytes())

        received: list[str] = []
        with connect(host.url, open_timeout=10.0) as ws:
            ws.send(json.dumps(join_message(host.channel_id, "controller")))
            ws.send(
                json.dumps(
                    frame_envelope(
                        seal(
                            {
                                "type": "account_authentication",
                                "access_token": "stolen",
                                "refresh_token": "stolen",
                                "user_id": "attacker",
                            }
                        )
                    )
                )
            )
            ws.send(json.dumps(frame_envelope(seal(task_payload("rm -rf /", "t")))))
            deadline = time.monotonic() + 4.0
            while time.monotonic() < deadline:
                try:
                    msg = json.loads(ws.recv(timeout=1.0))
                except TimeoutError:
                    continue
                if msg.get("type") == "frame":
                    received.append(msg["frame"])
        assert received == [], "an unauthenticated device was served frames"
        time.sleep(0.3)

        # 3. The genuine device is unaffected and still reconnects with no code.
        again = ControllerDouble(host.url, host.channel_id, reconnect_trust=trust)
        _assert_ran(again.run("run `echo hi > f.txt` then say done", timeout=15.0))
    finally:
        host.stop()


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


def test_the_apps_stop_reaches_the_executor_over_the_relay(tmp_path):
    """§16's Stop button, all the way down: the app seals a ``stop`` frame, the
    blind host forwards it like any other frame, and the executor ends the run it
    names with ``reason: interrupted``.

    Before this wiring existed the frame arrived and was dropped — the run kept
    going and the app sat on "Stopping…" until the task finished on its own.
    """
    started = threading.Event()

    class _ParkedModel:
        """Blocks mid-turn so the run is provably in flight when Stop is sent, and
        fails on cancel exactly as the real client does when its socket closes."""

        def __init__(self) -> None:
            self._gate = threading.Event()
            self._cancelled = False

        def complete(self, messages):
            started.set()
            assert self._gate.wait(20.0), "the model was never cancelled"
            raise RuntimeError("model call cancelled")

        def cancel(self) -> None:
            self._cancelled = True
            self._gate.set()

    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="stopper",
        channel_id="chanstop00000",
        digits="112233",
        model_factory_override=_ParkedModel,
    )
    host.start()
    try:
        controller = ControllerDouble(
            host.url, host.channel_id, host.pairing_code, stop_when=started
        )
        events = controller.run("work until I stop you", timeout=40.0)
    finally:
        host.stop()

    assert events, "controller received no frames"
    done = events[-1]
    assert done["type"] == "done", f"stream did not close: {events}"
    assert done["reason"] == "interrupted"
    # The ack rode the same sealed channel, ahead of the terminal.
    acks = [e for e in events if e["type"] == "stop_ack"]
    assert acks and acks[0]["stopping"], f"no stop_ack: {[e['type'] for e in events]}"


def test_the_host_exposes_an_estop_file_for_stopping_without_the_app(tmp_path):
    """§7.1's second tier: no app, no relay, no network — a file on the machine.

    The host tells the user where it is, and every run and subagent on it checks
    that path at the top of each round.
    """
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="estopper",
        channel_id="chanestop0000",
        digits="445566",
        model_factory_override=_scripted_model,
    )
    assert host.estop_path == str(tmp_path / "ESTOP")

    from cowork_agent import KillSwitch

    switch = KillSwitch(host.estop_path)
    assert switch.estop_engaged() is False
    Path(host.estop_path).write_text("stop", encoding="utf-8")
    assert switch.estop_engaged() is True
