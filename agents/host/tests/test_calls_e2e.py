"""The agent calls the user, end to end on the real host stack, no UI
(docs/WIRE_CONTRACT.md, "The agent calls the user"; docs/PERSONAL_AGENT_SPEC.md
§6.3, M2 acceptance).

1. "remind me in a moment by calling me": the (scripted) model puts a
   one-shot schedule on the clock. The schedule fires, the fired run calls
   ``call_user``, and the app gets a sealed ``voice_call_incoming`` on the
   same socket. The app accepts with ``voice_call_state``; the host records
   it and echoes the state.
2. A call that rings while no app is attached is sent again when the app
   reconnects (after a network drop, for example).
"""

from __future__ import annotations

import json
import threading
import time
from typing import Any

from websockets.sync.client import connect

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_host import LocalHost
from chuk_agents_host.calls import STATE_ACCEPTED, STATE_RINGING
from chuk_agents_host.protocol import frame_envelope, join_message

from test_local_run import ControllerDouble

REASON = "Your pizza is ready to come out of the oven."


class _ReminderModel(MockModelClient):
    """The app's task schedules the reminder; the fired task makes the call.
    The script is picked from the LAST user message (the executor builds more
    than one client per task, so a call counter would not do)."""

    def __init__(self) -> None:
        super().__init__([])
        self._chosen = False

    def complete(self, messages: list[dict]):
        if not self._chosen:
            self._chosen = True
            last_user = next((m for m in reversed(messages) if m.get("role") == "user"), {})
            text = str(last_user.get("content") or "")
            if text.startswith("[automation "):
                self._responses = [
                    tool_call_response(("call_user", {"reason": REASON})),
                    "I am calling you about the pizza.",
                ]
            else:
                self._responses = [
                    tool_call_response(
                        (
                            "schedule_task",
                            {
                                "spec": "in 1s",
                                "prompt": f"Call the user now with call_user: {REASON}",
                                "name": "pizza reminder",
                            },
                        )
                    ),
                    "I will call you in a moment.",
                ]
        return super().complete(messages)


class _CallingDouble(ControllerDouble):
    """Plays the app: sends the task, stays on the socket, fires the due
    schedule once it exists, accepts the incoming call, and collects until the
    fired run's ``done`` AND the host's ``voice_call_state`` echo."""

    def __init__(self, *args: Any, host: LocalHost, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._host = host

    def run(self, prompt: str, *, timeout: float = 40.0) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        fired_done = echoed = False
        with connect(self._url, open_timeout=10.0) as ws:
            ws.send(json.dumps(join_message(self._channel_id, "controller")))
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline and not (fired_done and echoed):
                try:
                    raw = ws.recv(timeout=1.0)
                except TimeoutError:
                    continue
                msg = json.loads(raw)
                kind = msg.get("type")
                if kind == "pairing":
                    self._on_pairing(ws, msg.get("data") or {}, prompt)
                    continue
                if kind != "frame":
                    continue
                payload = self._open(msg["frame"])
                if payload.get("type") == "host_session_request":
                    continue
                results.append(payload)
                ptype = payload.get("type")
                if ptype == "error":
                    return results
                if ptype == "automation" and payload.get("event") == "created":
                    threading.Thread(target=self._fire_when_due, daemon=True).start()
                elif ptype == "voice_call_incoming":
                    accept = {
                        "type": "voice_call_state",
                        "call_id": payload["call_id"],
                        "state": "accepted",
                    }
                    ws.send(json.dumps(frame_envelope(self._seal(accept))))
                elif ptype == "voice_call_state" and payload.get("state") == STATE_ACCEPTED:
                    echoed = True
                elif ptype == "done" and payload.get("host_notified"):
                    fired_done = True
        return results

    def _fire_when_due(self) -> None:
        # The scheduler thread ticks every 15 s; the test does not wait for it.
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            time.sleep(0.3)
            if self._host._automations.run_scheduler_once():
                return


def test_a_reminder_by_call_rings_the_app_from_a_fired_automation(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTS_DESKTOP_NOTIFY", "0")  # no toast on the test box
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="test-worker",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=_ReminderModel,
    )
    host.start()
    try:
        controller = _CallingDouble(
            host.url, host.channel_id, host.pairing_code, host=host
        )
        started = time.time()
        events = controller.run("remind me in a moment about the pizza by calling me")
        registry = host._calls.registry
    finally:
        host.stop()

    types = [(e["type"], e.get("event") or e.get("state")) for e in events]
    scheduled = [e for e in events if e["type"] == "tool" and e["name"] == "schedule_task"]
    assert scheduled and scheduled[0]["status"] == "completed", types
    created = [e for e in events if e["type"] == "automation" and e["event"] == "created"]
    assert created and "at" in created[0]["spec"], types
    fired = [e for e in events if e["type"] == "automation" and e["event"] == "fired"]
    assert fired, f"the reminder never fired: {types}"

    # The fired run called the user, and the tool came back at once.
    calls = [e for e in events if e["type"] == "tool" and e["name"] == "call_user"]
    assert calls and calls[0]["status"] == "completed", types
    assert "ringing (call_id " in json.dumps(calls[0].get("result"))

    [incoming] = [e for e in events if e["type"] == "voice_call_incoming"]
    assert incoming["thread_id"] == "thread-1"
    assert incoming["reason"] == REASON
    assert incoming["urgency"] == "normal"
    assert incoming["agent_id"] == "host:cowork-host"
    assert incoming["agent_name"] == "Your coworker"  # never the roster codename
    assert started + 100 < incoming["expires_at"] < time.time() + 121
    assert started - 1 < incoming["created_at"] <= time.time()
    assert isinstance(incoming["ring_seconds"], int) and 100 < incoming["ring_seconds"] <= 120

    # The app accepted; the host recorded it and told every controller.
    echo = [e for e in events if e["type"] == "voice_call_state"]
    assert echo and echo[-1] == {
        "type": "voice_call_state", "call_id": incoming["call_id"], "state": STATE_ACCEPTED,
    }
    assert registry.get(incoming["call_id"]).state == STATE_ACCEPTED

    dones = [e for e in events if e["type"] == "done"]
    assert dones[-1]["host_notified"] is True
    assert dones[-1]["run_id"] == fired[0]["run_id"]


def test_a_call_that_rang_while_the_app_was_away_is_sent_on_reconnect(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTS_DESKTOP_NOTIFY", "0")

    def model() -> MockModelClient:
        return MockModelClient(["hello"])

    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="test-worker",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=model,
    )
    host.start()
    try:
        first = ControllerDouble(host.url, host.channel_id, host.pairing_code)
        assert first.run("hi")[-1]["type"] == "done"
        trust = first.trust()

        # The socket is gone: the ring reaches nobody, but the call rings.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and host.party.controller_attached:
            time.sleep(0.05)
        result = host._calls.ring("thread-1", REASON, "high")
        assert result["ok"] is True and result["delivered"] is False
        call_id = result["call_id"]

        again = ControllerDouble(
            host.url, host.channel_id, reconnect_trust=trust, replay_key="thread-1"
        )
        replayed = again.run("")
        state = host._calls.registry.get(call_id).state
    finally:
        host.stop()

    incoming = [e for e in replayed if e["type"] == "voice_call_incoming"]
    assert [e["call_id"] for e in incoming][:1] == [call_id], [e["type"] for e in replayed]
    assert incoming[0]["urgency"] == "high" and incoming[0]["reason"] == REASON
    assert state == STATE_RINGING
