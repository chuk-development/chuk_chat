"""The 2026-09-13 lost message: a task frame that arrived and became nothing.

The incident. The user sent a message from the phone at 04:49. The app showed a
sent bubble and a typing indicator that never resolved. On the host there was no
run row in ``executor-state.db``, no trace line, and nothing in ``host.log`` —
the message was simply gone, and a frame that arrived and was thrown away looked
exactly like a frame that never arrived.

The mechanism, reproduced below. ``CloudHostParty._handle`` ended its dispatch
with a bare ``if`` and no ``else``::

    if self._task_server is not None and isinstance(self._opener, _OpenedFrames):
        ticket = self._opener.put(plaintext)
        self._task_server.submit(ticket, controller_device=frame.device_id)

Two states fall off the end of that function in silence: a controller session
whose account has not been provisioned yet (``_task_server is None``), and a
session whose codec was torn down under a still-running task server
(``_opener`` reset to ``None`` by the legacy ``_maybe_start_session`` reset).
Both were reachable in ordinary use, and both cost the user the message.

Every test here fails against the code as it stood that night.
"""

from __future__ import annotations

import base64
import json

import pytest
from chuk_agents_crypto import ApprovedDevices, AgentsFrameOpener, AgentsFrameSealer
from chuk_agents_crypto.device_keys import DeviceIdentity

from chuk_agents_host.cloud_party import (
    ACK_ACCEPTED,
    ACK_DUPLICATE,
    ACK_REJECTED,
    TYPE_TASK_ACK,
    CloudHostParty,
    _OpenedFrames,
)
from chuk_agents_host.controller_sessions import b64, mac, transcript
from chuk_agents_host.pairing_store import HostTrust
from chuk_agents_host.relay_ledger import REASON_NOT_PROVISIONED

CHANNEL = "shared"
CHANNEL_KEY = b"k" * 32
PHONE = "phone"


class FakeTaskServer:
    """Records what the party handed it, and nothing else.

    The real one starts a supervised Executor in a sandbox; none of that is what
    these tests are about. What matters is whether ``submit`` was reached at all.
    """

    def __init__(self) -> None:
        self.submitted: list[tuple[str, str | None]] = []
        self.rebinds = 0
        self.started = False
        self._ids = 0

    def start(self) -> None:
        self.started = True

    def submit(self, frame_b64: str, *, controller_device: str | None = None) -> str:
        self._ids += 1
        self.submitted.append((frame_b64, controller_device))
        return f"task-{self._ids}"

    def rebind(self, opener, sealer) -> None:
        self.rebinds += 1

    def stop(self) -> None:
        self.started = False


class Wire:
    """One app device on the other end of the party, with its own codec.

    Everything the party sends lands in :attr:`sent`; :meth:`frame` builds the
    ``controller_frame`` an app would send for one payload.
    """

    def __init__(self, party: CloudHostParty, host_identity: DeviceIdentity) -> None:
        self._party = party
        self.identity = DeviceIdentity.generate()
        self.sent: list[dict] = []
        party._send = self.sent.append  # type: ignore[method-assign]
        self._host_identity = host_identity
        self.sealer: AgentsFrameSealer | None = None
        self.opener: AgentsFrameOpener | None = None

    def resume(self) -> None:
        """Drive the two handshake frames the app sends on every connection."""
        request = {
            "type": "controller_resume",
            "channel": CHANNEL,
            "device_id": PHONE,
            "public_key": self.identity.export_public_key_base64(),
            "client_nonce": b64(bytes(range(32))),
        }
        self._party._handle(request)
        challenge = self.sent.pop()
        signed = transcript(
            CHANNEL,
            PHONE,
            request["public_key"],
            request["client_nonce"],
            challenge["host_nonce"],
        )
        self._party._handle(
            {
                "type": "controller_proof",
                "connection": challenge["connection"],
                "proof": b64(mac(CHANNEL_KEY, "cowork/controller/approve/", signed)),
                "signature": b64(
                    self.identity.sign(b"cowork/controller/device/" + signed)
                ),
            }
        )
        self.sent.pop()  # controller_ready
        traffic = mac(CHANNEL_KEY, "cowork/controller/traffic/", signed)
        approved = ApprovedDevices.empty()
        approved.approve("host", self._host_identity.public_key)
        self.sealer = AgentsFrameSealer(
            channel_key=traffic,
            key_version=1,
            device_id=PHONE,
            signing_identity=self.identity,
        )
        self.opener = AgentsFrameOpener(
            channel_key=traffic, key_version=1, approved_devices=approved
        )

    def send(self, payload: dict) -> None:
        assert self.sealer is not None, "resume() first"
        sealed = self.sealer.seal(json.dumps(payload).encode())
        self._party._handle(
            {
                "type": "controller_frame",
                "frame": base64.b64encode(sealed.to_bytes()).decode(),
            }
        )

    def provision(self) -> None:
        self.send(
            {
                "type": "account_authentication",
                "access_token": "a",
                "refresh_token": "r",
                "user_id": "u",
            }
        )

    def acks(self) -> list[dict]:
        """Every ``task_ack`` the party sealed back to this device."""
        assert self.opener is not None
        out = []
        for message in self.sent:
            if message.get("type") != "controller_frame":
                continue
            try:
                payload = json.loads(
                    self.opener.open(base64.b64decode(message["frame"]))
                )
            except Exception:  # noqa: BLE001 - not for us, or already opened
                continue
            if payload.get("type") == TYPE_TASK_ACK:
                out.append(payload)
        return out


@pytest.fixture
def party():
    """A cloud party wired to a fake task server and a trusted phone."""
    identity = DeviceIdentity.generate()
    servers: list[FakeTaskServer] = []

    def build(opener, sealer, token, host):
        server = FakeTaskServer()
        servers.append(server)
        return server

    trust = HostTrust(CHANNEL, CHANNEL_KEY, PHONE, DeviceIdentity.generate().public_key)
    lines: list[str] = []
    host_party = CloudHostParty(
        trust_provider=lambda: trust,
        transport=object(),
        channel_id=CHANNEL,
        pairing_factory=lambda: None,
        device_id="host",
        device_identity=identity,
        key_version=1,
        build_task_server=build,
        logger=lines.append,
    )
    host_party.log_lines = lines  # type: ignore[attr-defined]
    host_party.host_identity = identity  # type: ignore[attr-defined]
    host_party.servers = servers  # type: ignore[attr-defined]
    return host_party


def wire(party: CloudHostParty) -> Wire:
    link = Wire(party, party.host_identity)  # type: ignore[attr-defined]
    link.resume()
    return link


def test_a_task_after_the_codec_was_torn_down_still_runs(party):
    """The 04:49 shape: the codec was reset under a live task server.

    ``_maybe_start_session`` clears ``_opener`` on a legacy controller join. The
    task server is deliberately NOT reset — a run belongs to the host process,
    not to the socket — so the host was left holding a server it could no longer
    feed. Every task frame after that fell off the end of ``_handle``.
    """
    app = wire(party)
    app.provision()
    server = party.servers[0]

    # What the legacy reset did to a host that was already serving.
    party._opener = None

    app.send({"type": "task", "prompt": "und", "session_key": "s", "task_id": "t1"})

    assert server.submitted, "the task frame was dropped in silence"
    assert app.acks() == [
        {
            "type": TYPE_TASK_ACK,
            "task_id": "t1",
            "status": ACK_ACCEPTED,
            "session_key": "s",
            "request_id": "task-1",
        }
    ]


def test_a_relay_join_never_tears_down_a_live_controller_session(party):
    """The reset itself must not happen once controller sessions own the host.

    The old guard asked "is a controller attached right now", which is empty for
    a moment after a ``controller_offline`` or a ``controller_close``. The right
    question is whether this host has ever served a controller session.
    """
    app = wire(party)
    app.provision()
    opener = party._opener
    assert isinstance(opener, _OpenedFrames)

    # The executor link is up, which is what lets a join open a session at all.
    party._ws_ready = True
    # The phone says goodbye — backgrounded, or the socket went away — and the
    # session set is empty for as long as it takes to come back.
    app.send({"type": "controller_close"})
    assert not party._controllers.sessions
    # The relay derives a fresh join from the app's very next frame.
    party.on_controller_joined(7)

    assert party._opener is opener, "the codec was thrown away under a live session"
    # And the task that follows the reconnect still reaches the executor.
    app.resume()
    app.send({"type": "task", "prompt": "drei", "session_key": "s", "task_id": "t3"})
    assert party.servers[0].submitted


def test_a_task_before_the_account_frame_is_reported_and_acked(party):
    """The ordering hole: a task ahead of ``account_authentication``.

    It cannot be run — there is no task server yet — but a host that answers it
    with silence is the reason it cost a message. It must leave a line and tell
    the app, so the app can send it again once it has provisioned.
    """
    app = wire(party)

    app.send({"type": "task", "prompt": "hi", "session_key": "s", "task_id": "t9"})

    assert not party.servers, "a task must not build a task server"
    assert app.acks() == [
        {
            "type": TYPE_TASK_ACK,
            "task_id": "t9",
            "status": ACK_REJECTED,
            "session_key": "s",
            "reason": REASON_NOT_PROVISIONED,
        }
    ]
    dropped = [line for line in party.log_lines if "relay frame dropped" in line]
    assert dropped and REASON_NOT_PROVISIONED in dropped[0]
    assert "task" in dropped[0]

    # And it works the moment the app provisions and sends it again.
    app.provision()
    app.send({"type": "task", "prompt": "hi", "session_key": "s", "task_id": "t9"})
    assert len(party.servers[0].submitted) == 1


def test_a_resent_task_runs_once_and_is_acked_as_a_duplicate(party):
    """A reconnect re-sends what it never saw acknowledged. Once is enough.

    The app cannot know whether an unacknowledged task arrived, so it must be
    free to send it again; the host is the side that knows, and it answers
    ``duplicate`` instead of running — and billing — the same question twice.
    """
    app = wire(party)
    app.provision()
    server = party.servers[0]

    payload = {"type": "task", "prompt": "zwei", "session_key": "s", "task_id": "t2"}
    app.send(payload)
    app.send(payload)

    assert len(server.submitted) == 1
    assert [ack["status"] for ack in app.acks()] == [ACK_ACCEPTED, ACK_DUPLICATE]


def test_a_task_without_a_task_id_is_unchanged(party):
    """An older app sends no ``task_id``. It must behave exactly as before."""
    app = wire(party)
    app.provision()

    app.send({"type": "task", "prompt": "alt", "session_key": "s"})

    assert len(party.servers[0].submitted) == 1
    assert app.acks() == []


def test_every_dropped_frame_leaves_a_line(party):
    """A malformed controller frame used to return with no word anywhere."""
    app = wire(party)
    app.provision()
    party.log_lines.clear()

    party._handle({"type": "controller_frame", "frame": None})

    assert any("relay frame dropped" in line for line in party.log_lines)


def test_the_trace_carries_both_the_decision_and_the_drop(party):
    """Part 1 hangs off the existing trace, not a second mechanism.

    A frame the host acted on is trace-only — it is one line per user message in
    a healthy session. A frame it dropped is on the ordinary log as well, so a
    host nobody started with ``--trace`` still says what it swallowed.
    """
    from chuk_agents_runtime.trace import set_tracer

    class Recorder:
        enabled = True

        def __init__(self) -> None:
            self.lines: list[tuple[str, dict]] = []

        def emit(self, phase: str, **fields) -> None:
            self.lines.append((phase, fields))

    recorder = Recorder()
    previous = set_tracer(recorder)
    try:
        app = wire(party)
        app.provision()
        app.send({"type": "task", "prompt": "vier", "session_key": "s", "task_id": "t4"})
        party._handle({"type": "controller_frame", "frame": None})
    finally:
        set_tracer(previous)

    dispatched = [f for phase, f in recorder.lines if phase == "relay_frame_in"]
    assert {"frame_type": "task", "decision": "dispatched_run"}.items() <= next(
        f for f in dispatched if f["frame_type"] == "task"
    ).items()
    assert next(f for f in dispatched if f["frame_type"] == "task")["task_id"] == "t4"

    dropped = [f for phase, f in recorder.lines if phase == "relay_frame_dropped"]
    assert dropped and dropped[-1]["reason"] == "malformed"


def test_an_account_refresh_never_costs_the_task_around_it(party):
    """The prime suspect, ruled out with a test rather than an argument.

    The host log around the incident is full of ``account token persisted`` /
    ``account session refreshed in place`` pairs, so the refresh window was the
    obvious place to look for a dropped frame. It is not one: a re-provision
    swaps the tokens in the live session and rebinds the codec only when the
    codec is not already the right object, so a task sent between two refreshes
    goes through untouched. This test holds that property down.
    """
    app = wire(party)
    app.provision()
    server = party.servers[0]
    before = party._opener

    app.provision()
    app.send({"type": "task", "prompt": "mittendrin", "session_key": "s", "task_id": "t5"})
    app.provision()

    assert party._opener is before, "a refresh must not replace a healthy codec"
    assert len(server.submitted) == 1
    assert [ack["status"] for ack in app.acks()] == [ACK_ACCEPTED]
    assert server.rebinds == 0
    assert not [line for line in party.log_lines if "relay frame dropped" in line]
