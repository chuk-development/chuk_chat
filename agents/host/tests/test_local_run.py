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
    CoworkFrameOpener,
    CoworkFrameSealer,
    DeviceIdentity,
    Pairing,
)

from cowork_executor import frame_to_b64, task_payload
from cowork_host import KEY_VERSION, LocalHost
from cowork_host.protocol import (
    STEP_CONFIRM_D,
    STEP_DEVICE_D,
    STEP_PUBKEY,
    frame_envelope,
    join_message,
    pairing_envelope,
)

APP_DEVICE_ID = "cowork-app"


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
    """Plays the CoWork app: joiner pairing, then a token + a task, over the relay."""

    def __init__(self, url: str, channel_id: str, pairing_code: str) -> None:
        self._url = url
        self._channel_id = channel_id
        self._identity = DeviceIdentity.generate()
        self._pairing = Pairing.joiner(
            device_id=APP_DEVICE_ID,
            device_identity=self._identity,
            pairing_code=pairing_code,
        )
        self._sealer: CoworkFrameSealer | None = None
        self._opener: CoworkFrameOpener | None = None
        self.raw_result_frames: list[str] = []

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
        self._sealer = CoworkFrameSealer(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            device_id=APP_DEVICE_ID,
            signing_identity=self._identity,
        )
        self._opener = CoworkFrameOpener(
            channel_key=channel_key,
            key_version=KEY_VERSION,
            approved_devices=self._pairing.approved_devices,
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


def test_stress_every_connection_pairs_and_completes(tmp_path):
    """One long-lived host, twenty fresh controllers back to back over the real
    localhost relay. Each must pair from the stable code and run the task to a
    clean ``done``. This is the regression net for the intermittent pairing
    stall: a fresh initiator session is minted per connection, so 20/20 pass
    deterministically instead of ~half stalling on a consumed one-shot session."""
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
        for i in range(20):
            controller = ControllerDouble(host.url, host.channel_id, host.pairing_code)
            events = controller.run(
                "run `echo hi > f.txt` then say done", timeout=15.0
            )
            assert events and events[-1]["type"] == "done", (
                f"connection {i} did not pair+complete: {[e['type'] for e in events]}"
            )
            _assert_ran(events)
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
