"""The agent calls the user: the host's call registry and ring delivery.

docs/WIRE_CONTRACT.md, section "The agent calls the user". The model calls
``call_user(reason, urgency)`` (``chuk_agents_runtime.calls``). The executor
binds the tool to the task's session and it lands here, in
:meth:`CallService.ring`:

1. A call record goes into the registry, in memory: ``ringing``, with an
   expiry 120 s ahead. A call is short-lived, and a host restart ends every
   ring anyway, so nothing is written to disk.
2. The host seals one ``voice_call_incoming`` frame and sends it to every
   attached controller (the same sender the automation events use). The frame
   carries the reason: it is end-to-end sealed, and the app shows the reason
   on the incoming-call screen.
3. The tool returns at once. It never waits for the answer.

The app answers with ``voice_call_state`` (``accepted`` / ``declined`` /
``ended``); the host updates the record and sends the new state back to every
controller, so a second device stops ringing. A ring that nobody answers in
time becomes ``missed``. An ``accepted`` call that never reports ``ended`` (the
app died) becomes ``ended`` after ``accepted_max_seconds``.

The phone clock can differ from the host clock. So the ring frame carries
``ring_seconds`` (seconds left, computed at each send) next to ``expires_at``
(host clock); the app times the ring with ``ring_seconds``. When a controller attaches again (the app reconnects
after a network drop), every call that still rings is sent again; the app
treats a known ``call_id`` as a no-op.

A declined or missed call adds nothing to the thread. The model reads the
outcome with ``call_status(call_id)`` when it wants to know. Logs carry ids,
states and the urgency, never the reason.
"""

from __future__ import annotations

import secrets
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from chuk_agents_runtime.calls import URGENCIES, URGENCY_NORMAL, clean_reason

TYPE_VOICE_CALL_INCOMING = "voice_call_incoming"
TYPE_VOICE_CALL_STATE = "voice_call_state"

#: How long a call rings before it is ``missed``.
CALL_TTL_SECONDS = 120.0

#: How long an ``accepted`` call may last without an ``ended`` frame before the
#: host ends it itself (the app died or lost the relay mid-call).
ACCEPTED_MAX_SECONDS = 7200.0

#: How long ``call_status`` can still read a call that is no longer ringing.
FINISHED_KEEP_SECONDS = 6 * 3600.0

#: The most call records the registry holds. The oldest go first.
MAX_CALLS_KEPT = 200

STATE_RINGING = "ringing"
STATE_ACCEPTED = "accepted"
STATE_DECLINED = "declined"
STATE_MISSED = "missed"
STATE_ENDED = "ended"

#: The states the app may report in ``voice_call_state``. ``missed`` is the
#: host's own verdict: only the expiry sets it.
APP_STATES = (STATE_ACCEPTED, STATE_DECLINED, STATE_ENDED)

#: Which state may follow which. A terminal state has no successor, so a late
#: or repeated frame changes nothing.
_TRANSITIONS: dict[str, tuple[str, ...]] = {
    STATE_RINGING: (STATE_ACCEPTED, STATE_DECLINED, STATE_ENDED, STATE_MISSED),
    STATE_ACCEPTED: (STATE_ENDED,),
    STATE_DECLINED: (),
    STATE_MISSED: (),
    STATE_ENDED: (),
}

#: Title and body of the desktop toast when no app is attached. No reason in
#: it: the toast is a nudge to open the app, where the sealed frame waits.
DESKTOP_BODY = "Open the Chuk app to answer."

#: (agent_id, agent_name) for a session key.
AgentResolver = Callable[[str], tuple[str, str]]


@dataclass
class Call:
    """One call the agent started. ``thread_id`` is the session key."""

    call_id: str
    thread_id: str
    agent_id: str
    agent_name: str
    reason: str
    urgency: str
    created_at: float
    expires_at: float
    state: str = STATE_RINGING
    updated_at: float = 0.0
    answered_at: float | None = None
    ended_at: float | None = None

    def ring_seconds(self, now: float) -> int:
        """Whole seconds the call still rings at ``now`` (host clock), never
        below 0."""
        return max(0, int(round(self.expires_at - now)))

    def incoming_payload(self, now: float) -> dict:
        """The sealed host -> app ``voice_call_incoming`` frame, as sent at
        ``now``. ``ring_seconds`` is computed again for every send, so a copy
        re-sent after a reconnect carries the time that is really left."""
        return {
            "type": TYPE_VOICE_CALL_INCOMING,
            "call_id": self.call_id,
            "thread_id": self.thread_id,
            "agent_id": self.agent_id,
            "agent_name": self.agent_name,
            "reason": self.reason,
            "urgency": self.urgency,
            "created_at": self.created_at,
            "expires_at": self.expires_at,
            "ring_seconds": self.ring_seconds(now),
        }

    def state_payload(self) -> dict:
        """The sealed host -> app ``voice_call_state`` echo."""
        return {"type": TYPE_VOICE_CALL_STATE, "call_id": self.call_id, "state": self.state}

    def fields(self) -> dict:
        """What ``call_status`` shows the model."""
        row: dict[str, Any] = {
            "call_id": self.call_id,
            "state": self.state,
            "urgency": self.urgency,
            "reason": self.reason,
            "created_at": self.created_at,
            "expires_at": self.expires_at,
        }
        if self.answered_at is not None:
            row["answered_at"] = self.answered_at
        if self.ended_at is not None:
            row["ended_at"] = self.ended_at
        return row


def _new_call_id() -> str:
    return secrets.token_hex(8)


class CallRegistry:
    """The pending and recent calls, in memory. Thread-safe: the tool rings on
    the executor's worker thread, the app's state frame lands on the serve
    thread, and the expiry fires on a timer thread."""

    def __init__(
        self,
        *,
        clock: Callable[[], float] = time.time,
        ttl: float = CALL_TTL_SECONDS,
        keep: float = FINISHED_KEEP_SECONDS,
        max_calls: int = MAX_CALLS_KEPT,
        accepted_max: float = ACCEPTED_MAX_SECONDS,
    ) -> None:
        self._clock = clock
        self._ttl = ttl
        self._accepted_max = accepted_max
        self._keep = keep
        self._max = max_calls
        self._calls: dict[str, Call] = {}
        self._lock = threading.RLock()

    @property
    def ttl(self) -> float:
        return self._ttl

    @property
    def accepted_max(self) -> float:
        return self._accepted_max

    def now(self) -> float:
        """The registry's clock (the host clock)."""
        return self._clock()

    def create(
        self,
        *,
        thread_id: str,
        agent_id: str,
        agent_name: str,
        reason: str,
        urgency: str,
    ) -> Call:
        now = self._clock()
        call = Call(
            call_id=_new_call_id(),
            thread_id=thread_id,
            agent_id=agent_id,
            agent_name=agent_name,
            reason=reason,
            urgency=urgency,
            created_at=now,
            expires_at=now + self._ttl,
            updated_at=now,
        )
        with self._lock:
            self._prune(now)
            self._calls[call.call_id] = call
        return call

    def get(self, call_id: str) -> Call | None:
        with self._lock:
            return self._calls.get(call_id)

    def ringing(self) -> list[Call]:
        """The calls that still ring, oldest first. Expired ones are not."""
        now = self._clock()
        with self._lock:
            return [
                c for c in self._calls.values()
                if c.state == STATE_RINGING and c.expires_at > now
            ]

    def expire(self) -> list[Call]:
        """Mark every ringing call past its expiry as ``missed``, and every
        ``accepted`` call older than ``accepted_max`` as ``ended``. Returns the
        calls that changed now, so the caller can tell the app."""
        now = self._clock()
        changed: list[Call] = []
        with self._lock:
            for call in self._calls.values():
                if call.state == STATE_RINGING and call.expires_at <= now:
                    self._apply(call, STATE_MISSED, now)
                    changed.append(call)
                elif (
                    call.state == STATE_ACCEPTED
                    and call.answered_at is not None
                    and now - call.answered_at >= self._accepted_max
                ):
                    self._apply(call, STATE_ENDED, now)
                    changed.append(call)
        return changed

    def set_state(self, call_id: str, state: str) -> Call | None:
        """Move a call to ``state``. Returns the call when the state changed,
        ``None`` for an unknown id or a transition that is not allowed (a late
        frame for a finished call, an ``accepted`` after the expiry)."""
        now = self._clock()
        with self._lock:
            call = self._calls.get(call_id)
            if call is None:
                return None
            if call.state == STATE_RINGING and call.expires_at <= now and state != STATE_MISSED:
                # Too late: the ring was over before the answer came.
                self._apply(call, STATE_MISSED, now)
                return None
            if state not in _TRANSITIONS.get(call.state, ()):
                return None
            self._apply(call, state, now)
            return call

    @staticmethod
    def _apply(call: Call, state: str, now: float) -> None:
        call.state = state
        call.updated_at = now
        if state == STATE_ACCEPTED:
            call.answered_at = now
        elif state in (STATE_ENDED, STATE_DECLINED, STATE_MISSED):
            call.ended_at = now

    def _prune(self, now: float) -> None:
        stale = [
            cid for cid, c in self._calls.items()
            if c.state != STATE_RINGING and now - c.updated_at > self._keep
        ]
        for cid in stale:
            self._calls.pop(cid, None)
        while len(self._calls) >= self._max:
            oldest = min(self._calls.values(), key=lambda c: c.created_at)
            self._calls.pop(oldest.call_id, None)


class CallService:
    """The registry plus ring delivery. See the module docstring."""

    def __init__(
        self,
        *,
        send: Callable[[dict], bool],
        agent_resolver: AgentResolver | None = None,
        desktop: Callable[[str, str], Any] | None = None,
        logger: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.time,
        ttl: float = CALL_TTL_SECONDS,
        accepted_max: float = ACCEPTED_MAX_SECONDS,
        timers: bool = True,
    ) -> None:
        self._send = send
        self._resolve = agent_resolver or (lambda key: (key, "Your coworker"))
        self._desktop = desktop
        self._log = logger or (lambda _m: None)
        self._timers_on = timers
        self.registry = CallRegistry(clock=clock, ttl=ttl, accepted_max=accepted_max)
        self._timers: dict[str, threading.Timer] = {}
        self._timers_lock = threading.Lock()
        self._stopped = False

    # -- the tool-facing API ----------------------------------------------------

    def bound(self, session_key: str) -> "SessionCalls":
        return SessionCalls(self, session_key)

    def ring(self, session_key: str, reason: str, urgency: str = URGENCY_NORMAL) -> dict:
        """Start a call and return at once. ``delivered`` says whether an app
        was attached to receive the ring."""
        text = clean_reason(reason)
        if not text:
            return {"ok": False, "error": "reason must not be empty"}
        level = urgency if urgency in URGENCIES else None
        if level is None:
            return {"ok": False, "error": "urgency must be 'normal' or 'high'"}
        key = str(session_key or "default")
        try:
            agent_id, agent_name = self._resolve(key)
        except Exception:  # noqa: BLE001 — a name lookup must not stop a call
            agent_id, agent_name = key, "Your coworker"
        call = self.registry.create(
            thread_id=key,
            agent_id=str(agent_id or key),
            agent_name=str(agent_name or "Your coworker"),
            reason=text,
            urgency=level,
        )
        self._arm_timer(call.call_id, self.registry.ttl)
        delivered = self._deliver(call.incoming_payload(self.registry.now()))
        self._log(
            f"[calls] ringing {call.call_id} (thread {key}, urgency {level}, "
            f"{'sent to the app' if delivered else 'no app attached'})"
        )
        if not delivered and self._desktop is not None:
            try:
                self._desktop(f"{call.agent_name} is calling", DESKTOP_BODY)
            except Exception:  # noqa: BLE001 — a toast must never fail a call
                pass
        return {
            "ok": True,
            "call_id": call.call_id,
            "state": call.state,
            "expires_at": call.expires_at,
            "delivered": delivered,
        }

    def status(self, session_key: str, call_id: str) -> dict:
        """The call's fields for the model. Only the calls of ``session_key``:
        an id of another thread answers ``not found``."""
        self._expire_now()
        call = self.registry.get(str(call_id or ""))
        if call is None or call.thread_id != str(session_key or "default"):
            return {"ok": False, "error": "not found"}
        return {"ok": True, **call.fields()}

    # -- the app's side ---------------------------------------------------------

    def handle_frame(self, payload: dict) -> bool:
        """An app -> host ``voice_call_state`` frame. Returns True when the
        call changed. An unknown id, an unknown state or a late frame changes
        nothing and is logged by id only."""
        if not isinstance(payload, dict) or payload.get("type") != TYPE_VOICE_CALL_STATE:
            return False
        call_id = payload.get("call_id")
        state = payload.get("state")
        if not isinstance(call_id, str) or not call_id or state not in APP_STATES:
            self._log("[calls] ignored a voice_call_state frame without a valid call_id/state")
            return False
        call = self.registry.set_state(call_id, str(state))
        if call is None:
            self._log(f"[calls] {call_id}: state {state} not applied (unknown, finished or too late)")
            # The expiry may have just ended it: tell the app the truth.
            self._expire_now()
            known = self.registry.get(call_id)
            if known is not None:
                if known.state not in (STATE_RINGING, STATE_ACCEPTED):
                    self._cancel_expiry(call_id)
                self._deliver(known.state_payload())
            return False
        if call.state != STATE_RINGING:
            self._cancel_expiry(call.call_id)
        if call.state == STATE_ACCEPTED:
            # The app may die mid-call and never send ``ended``.
            self._arm_timer(call.call_id, self.registry.accepted_max)
        self._log(f"[calls] {call.call_id} -> {call.state}")
        self._deliver(call.state_payload())
        return True

    def resend_ringing(self) -> int:
        """A controller attached (again): send every call that still rings.
        Returns how many were sent."""
        self._expire_now()
        sent = 0
        for call in self.registry.ringing():
            if self._deliver(call.incoming_payload(self.registry.now())):
                sent += 1
        if sent:
            self._log(f"[calls] re-sent {sent} ringing call(s) to the attached app")
        return sent

    def expire(self) -> list[Call]:
        """Mark overdue rings as ``missed``, and overlong accepted calls as
        ``ended``, and tell the app. Exposed for tests with a fake clock; the
        timers call it in production."""
        return self._expire_now()

    def stop(self) -> None:
        self._stopped = True
        with self._timers_lock:
            timers = list(self._timers.values())
            self._timers.clear()
        for timer in timers:
            timer.cancel()

    # -- internals --------------------------------------------------------------

    def _deliver(self, payload: dict) -> bool:
        try:
            return bool(self._send(payload))
        except Exception as exc:  # noqa: BLE001 — a relay hiccup must not fail the tool
            self._log(f"[calls] could not send {payload.get('type')}: {type(exc).__name__}")
            return False

    def _expire_now(self) -> list[Call]:
        changed = self.registry.expire()
        for call in changed:
            self._cancel_expiry(call.call_id)
            if call.state == STATE_MISSED:
                self._log(f"[calls] {call.call_id} -> missed (nobody answered in time)")
            else:
                self._log(f"[calls] {call.call_id} -> ended (accepted, but no end reported in time)")
            self._deliver(call.state_payload())
        return changed

    def _arm_timer(self, call_id: str, delay: float) -> None:
        """Run the expiry check ``delay`` seconds from now. It replaces any
        earlier timer of the same call (the ring timer, when the call is
        accepted)."""
        if not self._timers_on or self._stopped:
            return
        # A small margin makes sure the registry's clock has passed the limit.
        timer = threading.Timer(delay + 0.05, self._expire_now)
        timer.daemon = True
        timer.name = f"agents-call-expiry-{call_id}"
        with self._timers_lock:
            old = self._timers.pop(call_id, None)
            self._timers[call_id] = timer
        if old is not None:
            old.cancel()
        timer.start()

    def _cancel_expiry(self, call_id: str) -> None:
        with self._timers_lock:
            timer = self._timers.pop(call_id, None)
        if timer is not None:
            timer.cancel()


class SessionCalls:
    """The :class:`chuk_agents_runtime.calls.CallBackend` for ONE session.
    Every call carries the bound key; there is no way to name another."""

    def __init__(self, service: CallService, session_key: str) -> None:
        self._service = service
        self._session_key = session_key

    @property
    def session_key(self) -> str:
        return self._session_key

    def ring(self, reason: str, urgency: str) -> dict:
        return self._service.ring(self._session_key, reason, urgency)

    def status(self, call_id: str) -> dict:
        return self._service.status(self._session_key, call_id)


__all__ = [
    "ACCEPTED_MAX_SECONDS",
    "APP_STATES",
    "CALL_TTL_SECONDS",
    "Call",
    "CallRegistry",
    "CallService",
    "SessionCalls",
    "STATE_ACCEPTED",
    "STATE_DECLINED",
    "STATE_ENDED",
    "STATE_MISSED",
    "STATE_RINGING",
    "TYPE_VOICE_CALL_INCOMING",
    "TYPE_VOICE_CALL_STATE",
]
