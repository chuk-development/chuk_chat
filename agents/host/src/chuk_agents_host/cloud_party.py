"""One executor shared by independently authenticated cloud controllers.

Every inbound frame reports what became of it (:mod:`chuk_agents_host.relay_ledger`).
This file used to end its dispatch with a bare ``if`` and no ``else``, so a task
frame that arrived while the host was not provisioned for the *current*
controller session fell off the end of the function: no run, no log, no error
frame, nothing. From the app's side that is indistinguishable from a frame that
never left the phone, and that ambiguity is what made the 2026-09-13 lost
message undiagnosable. Nothing may leave this class silently any more.
"""

from __future__ import annotations

import base64
import json
from collections import OrderedDict

from chuk_agents_crypto.frame import AgentsFrame
from chuk_agents_crypto.frame import AgentsFrameRejected, AgentsFrameRejection
from .controller_sessions import ControllerSessions
from .party import HostParty
from .relay_ledger import (
    DECISION_CLOSED,
    DECISION_DISPATCHED_EXECUTOR,
    DECISION_DISPATCHED_RUN,
    DECISION_DUPLICATE,
    DECISION_HANDSHAKE,
    DECISION_PROVISIONED,
    DECISION_REPAIRED,
    InboundFrameLog,
    REASON_LEGACY_SUPERSEDED,
    REASON_MALFORMED,
    REASON_NOT_PROVISIONED,
    REASON_QUEUE_FULL,
    REASON_REJECTED,
)

#: The frame the host sends back for every ``task`` that named a ``task_id``
#: (docs/WIRE_CONTRACT.md, "Task acknowledgement"). Without it a send is
#: fire-and-forget: a socket that is TCP-alive but whose other end is new
#: accepts the bytes and nothing ever learns the task was lost, so nothing can
#: retry it.
TYPE_TASK_ACK = "task_ack"

ACK_ACCEPTED = "accepted"
ACK_DUPLICATE = "duplicate"
ACK_REJECTED = "rejected"

#: How many task ids are remembered for the duplicate check. The app re-sends an
#: unacknowledged task on reconnect, so the window only has to outlive one
#: reconnect, not a whole session; 256 is many minutes of ordinary chat and a
#: few kilobytes of memory.
MAX_REMEMBERED_TASKS = 256


class CloudHostParty(HostParty):
    def __init__(self, *, trust_provider, **kwargs):
        super().__init__(**kwargs)
        self._trust_provider = trust_provider
        self._controllers: ControllerSessions | None = None
        self._frames = InboundFrameLog(self._log)
        # task_id -> the executor request id it became. Ordered so the oldest
        # entry is the one that is evicted.
        self._seen_tasks: "OrderedDict[str, str]" = OrderedDict()

    def on_controller_joined(self, token):
        # Once independently authenticated controllers are active, a relay
        # reconnect must not reset the executor or another controller's codec.
        #
        # The membership test used to be ``self._controllers.sessions`` — "is
        # a controller attached right now". That is the wrong question. A
        # controller that closed its session (or whose last frame drew a
        # ``controller_offline`` from the relay) leaves the set empty, and the
        # very next frame from the app is a relay-level *join*, which then ran
        # the legacy reset and set ``self._opener`` to ``None`` while the task
        # server kept running. Every task frame after that was dropped by the
        # guard at the bottom of :meth:`_handle`, in silence, until the app's
        # next ``account_authentication`` happened to rebuild the codec. That
        # is the 2026-09-13 bug. The right question is "has this host ever
        # served a controller session", because from then on the legacy
        # ceremony is not what drives it.
        #
        # Presence is still recorded: the notifier reads ``controller_attached``
        # to decide whether a finished run needs a push, and ``_active_token``
        # is what lets the matching ``leave`` be recognised. Only the session
        # reset is skipped.
        if self._controllers is not None:
            with self._session_lock:
                self._active_token = token
                self._controller_present = True
            return
        super().on_controller_joined(token)

    def _sessions(self) -> ControllerSessions:
        if self._controllers is None:
            trust = self._trust_provider()
            if trust is None:
                raise ValueError("host must be paired before account recovery")
            self._controllers = ControllerSessions(
                trust, self._device_identity, self._device_id
            )
        return self._controllers

    def _handle(self, message):
        kind = message.get("type")
        if kind not in ("controller_resume", "controller_proof", "controller_frame"):
            if self._controllers is not None and self._controllers.sessions:
                # The §15 ceremony no longer owns this host. Saying so is the
                # point: a legacy frame arriving here means the app and the
                # host disagree about which protocol they are on, and that is
                # exactly the class of fault that used to be invisible.
                self._frames.dropped(kind, REASON_LEGACY_SUPERSEDED)
                return
            # Existing first-pairing ceremony remains supported.
            return super()._handle(message)
        try:
            sessions = self._sessions()
            if kind == "controller_resume":
                self._frames.acted(kind, DECISION_HANDSHAKE)
                self._send(sessions.challenge(message))
            elif kind == "controller_proof":
                ready = sessions.confirm(message)
                self._controller_present = True
                self._paired.set()
                self._frames.acted(kind, DECISION_HANDSHAKE)
                self._send(ready)
            else:
                self._handle_controller_frame(sessions, message)
        except AgentsFrameRejected as exc:
            # The sealed frame did not open. Name the rejection: an unapproved
            # device, a replayed sequence number and a clock that drifted past
            # the window all land here and all need different answers.
            self._frames.dropped(kind, REASON_REJECTED, rejection=exc.rejection.value)
        except Exception as exc:
            # One line, not two: the ledger line already carries the type and
            # the reason. No keys, proof bytes, account fields or message
            # contents ever reach a log — only the exception's class name.
            self._frames.dropped(kind, REASON_REJECTED, error=type(exc).__name__)

    # -- one controller_frame --------------------------------------------

    def _handle_controller_frame(self, sessions: ControllerSessions, message) -> None:
        """Open one authenticated controller frame and route its payload.

        Split out of :meth:`_handle` so every exit is visible in one screen.
        There is no silent exit left: each ``return`` below either reports what
        the frame became or reports why it became nothing.
        """
        wire = message.get("frame")
        if not isinstance(wire, str):
            self._frames.dropped("controller_frame", REASON_MALFORMED)
            return
        raw = base64.b64decode(wire, validate=True)
        frame = AgentsFrame.from_bytes(raw)
        # Authenticate here, then issue a private one-use ticket for the
        # existing executor input boundary. The shared executor's Stop,
        # approvals and run ownership work across all controllers.
        plaintext = sessions.open(frame)
        payload = json.loads(plaintext)
        kind = payload.get("type")
        device = frame.device_id
        session_key = payload.get("session_key")

        if kind == "controller_close":
            with sessions.lock:
                sessions.sessions.pop(device, None)
            self._controller_present = bool(sessions.sessions)
            self._frames.acted(kind, DECISION_CLOSED, device=device)
            return

        if kind == "account_authentication":
            self._provision_from(sessions, payload)
            self._frames.acted(kind, DECISION_PROVISIONED, device=device)
            return

        task_id = payload.get("task_id")
        task_id = task_id if isinstance(task_id, str) and task_id else None

        if self._task_server is None:
            # The app sent a task before its own ``account_authentication`` for
            # this connection. That is a real ordering bug on the app's side
            # (``sendTask`` did not wait for the provision gate the way a replay
            # does), but a host that answers it with silence is the reason it
            # cost a message. Say so, and tell the app so it can re-send.
            self._frames.dropped(
                kind, REASON_NOT_PROVISIONED, device=device, session_key=session_key
            )
            self._ack_task(sessions, device, task_id, session_key, ACK_REJECTED,
                           reason=REASON_NOT_PROVISIONED)
            return

        if not isinstance(self._opener, _OpenedFrames):
            # The codec was torn down under a running task server — the shape
            # the 2026-09-13 incident took. Rebuilding it costs one object and
            # keeps the message; dropping it costs the user their message. The
            # ticket table is process-local and carries no trust of its own, so
            # there is nothing unsafe about minting a fresh one here.
            self._opener = _OpenedFrames()
            self._sealer = sessions
            self._task_server.rebind(self._opener, sessions)
            self._frames.acted(kind, DECISION_REPAIRED, device=device)

        if task_id is not None:
            known = self._seen_tasks.get(task_id)
            if known is not None:
                # The app re-sent a task it never saw acknowledged. It did
                # arrive, so running it again would answer the same question
                # twice and bill for it twice.
                self._frames.acted(
                    kind, DECISION_DUPLICATE, device=device, task_id=task_id
                )
                self._ack_task(sessions, device, task_id, session_key, ACK_DUPLICATE,
                               request_id=known)
                return

        try:
            ticket = self._opener.put(plaintext)
        except ValueError:
            self._frames.dropped(
                kind, REASON_QUEUE_FULL, device=device, session_key=session_key
            )
            self._ack_task(sessions, device, task_id, session_key, ACK_REJECTED,
                           reason=REASON_QUEUE_FULL)
            return
        request_id = self._task_server.submit(ticket, controller_device=device)
        if task_id is not None:
            self._remember_task(task_id, request_id)
        self._frames.acted(
            kind,
            DECISION_DISPATCHED_RUN if kind == "task" else DECISION_DISPATCHED_EXECUTOR,
            device=device,
            session_key=session_key,
            request_id=request_id,
            task_id=task_id,
        )
        self._ack_task(sessions, device, task_id, session_key, ACK_ACCEPTED,
                       request_id=request_id)

    # -- provisioning -----------------------------------------------------

    def _provision_from(self, sessions: ControllerSessions, payload: dict) -> None:
        """Build or refresh the task server from an ``account_authentication``."""
        if self._task_server is None:
            # Inbound frames have already been opened once; the executor
            # receives a one-use in-process plaintext ticket.
            self._opener = _OpenedFrames()
            self._sealer = sessions
            server = self._build_task_server(self._opener, sessions, payload, self)
            server.start()
            self._task_server = server
        else:
            if not isinstance(self._opener, _OpenedFrames):
                self._opener = _OpenedFrames()
                self._sealer = sessions
                self._task_server.rebind(self._opener, sessions)
            if self._on_reprovision is not None:
                self._on_reprovision(payload)
        self._provisioned = True

    # -- acknowledgement --------------------------------------------------

    def _remember_task(self, task_id: str, request_id: str) -> None:
        self._seen_tasks[task_id] = request_id
        while len(self._seen_tasks) > MAX_REMEMBERED_TASKS:
            self._seen_tasks.popitem(last=False)

    def _ack_task(
        self,
        sessions: ControllerSessions,
        device: str,
        task_id: str | None,
        session_key,
        status: str,
        *,
        request_id: str | None = None,
        reason: str | None = None,
    ) -> None:
        """Tell the controller that sent this task what became of it.

        Only for a frame that named a ``task_id``: an app that does not use the
        contract gets exactly the old behaviour, so an older build keeps working
        against this host. The ack goes to the sending device alone — another
        phone on the same account did not ask this question.
        """
        if task_id is None:
            return
        payload = {
            "type": TYPE_TASK_ACK,
            "task_id": task_id,
            "status": status,
        }
        if isinstance(session_key, str) and session_key:
            payload["session_key"] = session_key
        if request_id:
            payload["request_id"] = request_id
        if reason:
            payload["reason"] = reason
        try:
            batch = sessions.seal(json.dumps(payload, separators=(",", ":")).encode())
        except Exception as exc:  # noqa: BLE001 - an ack must never kill the pipe
            self._log(f"could not seal a task ack: {type(exc).__name__}: {exc}")
            return
        for entry in batch.frames:
            if entry["device_id"] != device:
                continue
            self._send(
                {
                    "type": "controller_frame",
                    "connection": entry["connection"],
                    "frame": entry["frame"],
                }
            )

    def send_result_frame(self, frame_b64: str) -> None:
        self.send_routed_result(frame_b64, None)

    def send_routed_result(self, frame_b64: str, device: str | None) -> None:
        try:
            batch = json.loads(base64.b64decode(frame_b64))
        except (ValueError, UnicodeDecodeError):
            return super().send_result_frame(frame_b64)
        if "controller_frames" not in batch:
            return super().send_result_frame(frame_b64)
        for entry in batch["controller_frames"]:
            if device is None or batch["broadcast"] or entry["device_id"] == device:
                self._send(
                    {
                        "type": "controller_frame",
                        "connection": entry["connection"],
                        "frame": entry["frame"],
                    }
                )


class _OpenedFrames:
    """One-use process-local tickets after ControllerSessions verified a frame.

    These never travel over the network; only the private Executor loopback
    receives them. Random tickets prevent an external wire frame masquerading
    as already authenticated data.
    """

    def __init__(self):
        import threading

        self._lock = threading.Lock()
        self._pending = {}

    def put(self, plaintext):
        import secrets

        ticket = secrets.token_bytes(32)
        with self._lock:
            if len(self._pending) >= 1024:
                raise ValueError("executor input queue full")
            self._pending[ticket] = plaintext
        return base64.b64encode(ticket).decode()

    def open(self, raw):
        with self._lock:
            result = self._pending.pop(raw, None)
        if result is None:
            raise AgentsFrameRejected(AgentsFrameRejection.DEVICE_NOT_APPROVED)
        return result
