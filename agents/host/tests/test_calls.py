"""The agent calls the user: the host's call registry and ring delivery
(docs/WIRE_CONTRACT.md, "The agent calls the user")."""

from __future__ import annotations

import threading
import time

from chuk_agents_runtime import ToolRegistry
from chuk_agents_runtime.calls import register_call_tools

from chuk_agents_host.calls import (
    CALL_TTL_SECONDS,
    STATE_ACCEPTED,
    STATE_DECLINED,
    STATE_ENDED,
    STATE_MISSED,
    STATE_RINGING,
    TYPE_VOICE_CALL_INCOMING,
    TYPE_VOICE_CALL_STATE,
    CallService,
)


class _Clock:
    def __init__(self, now: float = 1_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class _Sink:
    """The host's ``_send_host_payload``: records every sealed payload and says
    whether an app was attached to take it."""

    def __init__(self, attached: bool = True) -> None:
        self.attached = attached
        self.sent: list[dict] = []

    def __call__(self, payload: dict) -> bool:
        if not self.attached:
            return False
        self.sent.append(dict(payload))
        return True

    def of_type(self, kind: str) -> list[dict]:
        return [p for p in self.sent if p.get("type") == kind]


def _service(sink: _Sink, clock: _Clock | None = None, **kwargs) -> CallService:
    return CallService(
        send=sink,
        agent_resolver=lambda key: (f"agent:{key}", "Laptop Bot"),
        clock=clock or _Clock(),
        timers=False,
        **kwargs,
    )


# -- ring ---------------------------------------------------------------------


def test_the_tool_returns_at_once_and_does_not_wait_for_an_answer():
    sink = _Sink()
    service = _service(sink)
    registry = ToolRegistry()
    register_call_tools(registry, service.bound("thread-1"))

    started = time.monotonic()
    result = registry.dispatch("call_user", {"reason": "Your pizza is ready.", "urgency": "high"})
    elapsed = time.monotonic() - started

    assert elapsed < 1.0
    call_id = sink.of_type(TYPE_VOICE_CALL_INCOMING)[0]["call_id"]
    assert result == f"ringing (call_id {call_id}). Check call_status(call_id) later to see if the user answered."
    # Nobody answered, and the tool is already back: the call still rings.
    assert service.registry.get(call_id).state == STATE_RINGING


def test_the_ring_frame_carries_exactly_the_documented_fields():
    sink = _Sink()
    clock = _Clock(5_000.0)
    service = _service(sink, clock)

    result = service.ring("thread-1", "  Your pizza is ready.  ", "normal")

    assert result["ok"] is True and result["delivered"] is True
    assert result["state"] == STATE_RINGING
    assert result["expires_at"] == 5_000.0 + CALL_TTL_SECONDS
    [frame] = sink.sent
    assert set(frame) == {
        "type", "call_id", "thread_id", "agent_id", "agent_name", "reason", "urgency",
        "created_at", "expires_at", "ring_seconds",
    }
    assert frame == {
        "type": TYPE_VOICE_CALL_INCOMING,
        "call_id": result["call_id"],
        "thread_id": "thread-1",
        "agent_id": "agent:thread-1",
        "agent_name": "Laptop Bot",
        "reason": "Your pizza is ready.",
        "urgency": "normal",
        "created_at": 5_000.0,
        "expires_at": 5_000.0 + CALL_TTL_SECONDS,
        "ring_seconds": int(CALL_TTL_SECONDS),
    }
    assert isinstance(frame["ring_seconds"], int)


def test_a_long_reason_is_cut_to_1000_characters():
    sink = _Sink()
    service = _service(sink)
    service.ring("thread-1", "x" * 5000, "normal")
    assert len(sink.sent[0]["reason"]) == 1000


def test_an_empty_reason_or_an_unknown_urgency_starts_no_call():
    sink = _Sink()
    service = _service(sink)
    assert service.ring("thread-1", "   ", "normal")["ok"] is False
    assert service.ring("thread-1", "pizza", "whenever")["ok"] is False
    assert sink.sent == []
    assert service.registry.ringing() == []


def test_with_no_app_attached_the_call_still_rings_and_the_model_gets_a_hint():
    sink = _Sink(attached=False)
    toasts: list[tuple[str, str]] = []
    service = _service(sink, desktop=lambda title, body: toasts.append((title, body)))
    registry = ToolRegistry()
    register_call_tools(registry, service.bound("thread-1"))

    result = registry.dispatch("call_user", {"reason": "Your pizza is ready."})

    assert result.startswith("ringing (call_id ")
    assert "no app is connected right now, the user may miss it" in result
    [call] = service.registry.ringing()
    assert call.state == STATE_RINGING
    # The desktop nudge names the coworker and never the reason.
    assert toasts == [("Laptop Bot is calling", "Open the Chuk app to answer.")]


def test_with_an_app_attached_no_desktop_toast_is_shown():
    sink = _Sink()
    toasts: list = []
    service = _service(sink, desktop=lambda title, body: toasts.append((title, body)))
    service.ring("thread-1", "pizza", "normal")
    assert toasts == []


def test_a_broken_sender_does_not_fail_the_tool():
    def boom(_payload: dict) -> bool:
        raise RuntimeError("relay down")

    service = CallService(send=boom, clock=_Clock(), timers=False)
    result = service.ring("thread-1", "pizza", "normal")
    assert result["ok"] is True and result["delivered"] is False


# -- expiry -------------------------------------------------------------------


def test_a_ring_nobody_answers_becomes_missed_and_the_app_is_told():
    sink = _Sink()
    clock = _Clock()
    service = _service(sink, clock)
    call_id = service.ring("thread-1", "pizza", "normal")["call_id"]

    clock.now += CALL_TTL_SECONDS - 1
    assert service.expire() == []
    assert service.registry.get(call_id).state == STATE_RINGING

    clock.now += 2
    [missed] = service.expire()
    assert missed.call_id == call_id and missed.state == STATE_MISSED
    assert sink.of_type(TYPE_VOICE_CALL_STATE) == [
        {"type": TYPE_VOICE_CALL_STATE, "call_id": call_id, "state": STATE_MISSED}
    ]
    # The model reads the outcome; the thread gets nothing.
    status = service.status("thread-1", call_id)
    assert status["ok"] is True and status["state"] == STATE_MISSED
    assert status["ended_at"] == clock.now


def test_the_expiry_timer_marks_the_call_missed_on_its_own():
    sink = _Sink()
    service = CallService(send=sink, ttl=0.2)  # real clock, real timer
    try:
        call_id = service.ring("thread-1", "pizza", "normal")["call_id"]
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline and service.registry.get(call_id).state == STATE_RINGING:
            time.sleep(0.02)
        assert service.registry.get(call_id).state == STATE_MISSED
        assert sink.of_type(TYPE_VOICE_CALL_STATE)[-1]["state"] == STATE_MISSED
    finally:
        service.stop()


def test_an_answer_after_the_expiry_is_too_late():
    sink = _Sink()
    clock = _Clock()
    service = _service(sink, clock)
    call_id = service.ring("thread-1", "pizza", "normal")["call_id"]
    clock.now += CALL_TTL_SECONDS + 1

    changed = service.handle_frame({"type": "voice_call_state", "call_id": call_id, "state": "accepted"})

    assert changed is False
    assert service.registry.get(call_id).state == STATE_MISSED
    # The app hears the truth, so it stops showing a call that is over.
    assert sink.of_type(TYPE_VOICE_CALL_STATE)[-1] == {
        "type": TYPE_VOICE_CALL_STATE, "call_id": call_id, "state": STATE_MISSED,
    }


# -- re-send on attach ----------------------------------------------------------


def test_a_controller_that_attaches_again_gets_every_call_that_still_rings():
    sink = _Sink(attached=False)
    clock = _Clock()
    service = _service(sink, clock)
    old = service.ring("thread-1", "old", "normal")["call_id"]
    clock.now += CALL_TTL_SECONDS - 10
    fresh = service.ring("thread-2", "fresh", "high")["call_id"]
    answered = service.ring("thread-1", "answered", "normal")["call_id"]
    sink.attached = True
    service.handle_frame({"type": "voice_call_state", "call_id": answered, "state": "declined"})
    sink.sent.clear()

    clock.now += 20  # ``old`` is past its expiry now, ``fresh`` is not
    sent = service.resend_ringing()

    assert sent == 1
    incoming = sink.of_type(TYPE_VOICE_CALL_INCOMING)
    assert [p["call_id"] for p in incoming] == [fresh]
    assert incoming[0]["reason"] == "fresh" and incoming[0]["urgency"] == "high"
    # The one that ran out on the way is reported as missed, not re-sent.
    assert {"type": TYPE_VOICE_CALL_STATE, "call_id": old, "state": STATE_MISSED} in sink.sent


def test_a_resent_ring_carries_the_seconds_really_left_not_the_first_value():
    # The phone clock may run ahead of the host clock, so the app times the
    # ring with ring_seconds. Every send computes it again on the host clock.
    sink = _Sink()
    clock = _Clock(2_000.0)
    service = _service(sink, clock)
    call_id = service.ring("thread-1", "pizza", "normal")["call_id"]

    clock.now += 50.4
    assert service.resend_ringing() == 1
    first, again = sink.of_type(TYPE_VOICE_CALL_INCOMING)
    assert first["ring_seconds"] == int(CALL_TTL_SECONDS)
    assert again["call_id"] == call_id
    assert again["ring_seconds"] == int(CALL_TTL_SECONDS) - 50
    # created_at and expires_at stay the host's first values.
    assert again["created_at"] == first["created_at"] == 2_000.0
    assert again["expires_at"] == first["expires_at"]


def test_ring_seconds_never_goes_below_zero():
    sink = _Sink()
    clock = _Clock(2_000.0)
    service = _service(sink, clock)
    service.ring("thread-1", "pizza", "normal")
    [call] = service.registry.ringing()
    assert call.ring_seconds(clock.now + CALL_TTL_SECONDS + 30) == 0


def test_resend_with_nothing_ringing_sends_nothing():
    sink = _Sink()
    service = _service(sink)
    assert service.resend_ringing() == 0
    assert sink.sent == []


# -- the app's voice_call_state ---------------------------------------------------


def test_accept_then_end_updates_the_registry_and_echoes_to_every_controller():
    sink = _Sink()
    clock = _Clock()
    service = _service(sink, clock)
    call_id = service.ring("thread-1", "pizza", "normal")["call_id"]

    clock.now += 5
    assert service.handle_frame({"type": "voice_call_state", "call_id": call_id, "state": "accepted"})
    call = service.registry.get(call_id)
    assert call.state == STATE_ACCEPTED and call.answered_at == clock.now

    # An accepted call does not expire into missed.
    clock.now += CALL_TTL_SECONDS * 3
    assert service.expire() == []

    assert service.handle_frame({"type": "voice_call_state", "call_id": call_id, "state": "ended"})
    assert service.registry.get(call_id).state == STATE_ENDED
    states = [p["state"] for p in sink.of_type(TYPE_VOICE_CALL_STATE)]
    assert states == [STATE_ACCEPTED, STATE_ENDED]


def test_an_accepted_call_without_an_end_frame_ends_after_the_limit():
    # The app died mid-call and never sent "ended".
    sink = _Sink()
    clock = _Clock()
    service = _service(sink, clock, accepted_max=7200.0)
    call_id = service.ring("thread-1", "pizza", "normal")["call_id"]
    assert service.handle_frame({"type": "voice_call_state", "call_id": call_id, "state": "accepted"})

    clock.now += 7199
    assert service.expire() == []
    assert service.registry.get(call_id).state == STATE_ACCEPTED

    clock.now += 1
    [changed] = service.expire()
    call = service.registry.get(call_id)
    assert changed is call
    assert call.state == STATE_ENDED and call.ended_at == clock.now
    assert sink.of_type(TYPE_VOICE_CALL_STATE)[-1] == {
        "type": TYPE_VOICE_CALL_STATE, "call_id": call_id, "state": STATE_ENDED,
    }
    # A late "ended" from the app changes nothing more.
    assert not service.handle_frame({"type": "voice_call_state", "call_id": call_id, "state": "ended"})
    assert service.expire() == []


def test_the_accepted_limit_defaults_to_two_hours():
    from chuk_agents_host.calls import ACCEPTED_MAX_SECONDS

    assert ACCEPTED_MAX_SECONDS == 7200.0
    assert _service(_Sink()).registry.accepted_max == 7200.0


def test_a_declined_call_is_final():
    sink = _Sink()
    service = _service(sink)
    call_id = service.ring("thread-1", "pizza", "normal")["call_id"]
    assert service.handle_frame({"type": "voice_call_state", "call_id": call_id, "state": "declined"})
    assert service.registry.get(call_id).state == STATE_DECLINED
    # A late accept from a second device changes nothing.
    assert not service.handle_frame({"type": "voice_call_state", "call_id": call_id, "state": "accepted"})
    assert service.registry.get(call_id).state == STATE_DECLINED


def test_bad_state_frames_change_nothing():
    sink = _Sink()
    service = _service(sink)
    call_id = service.ring("thread-1", "pizza", "normal")["call_id"]
    sink.sent.clear()
    for frame in (
        {"type": "voice_call_state", "call_id": "nope", "state": "accepted"},
        {"type": "voice_call_state", "call_id": call_id, "state": "missed"},  # the host's verdict only
        {"type": "voice_call_state", "call_id": call_id, "state": "ringing"},
        {"type": "voice_call_state", "state": "accepted"},
        {"type": "something_else", "call_id": call_id, "state": "accepted"},
        "not a dict",
    ):
        assert service.handle_frame(frame) is False  # type: ignore[arg-type]
    assert service.registry.get(call_id).state == STATE_RINGING
    assert sink.sent == []


# -- call_status ------------------------------------------------------------------


def test_call_status_sees_only_the_calls_of_its_own_thread():
    sink = _Sink()
    service = _service(sink)
    registry = ToolRegistry()
    register_call_tools(registry, service.bound("thread-1"))
    other = ToolRegistry()
    register_call_tools(other, service.bound("thread-2"))
    call_id = service.ring("thread-1", "pizza", "high")["call_id"]

    mine = registry.dispatch("call_status", {"call_id": call_id})
    assert mine["ok"] is True and mine["state"] == STATE_RINGING
    assert mine["urgency"] == "high" and mine["reason"] == "pizza"
    assert other.dispatch("call_status", {"call_id": call_id}) == {"ok": False, "error": "not found"}
    assert registry.dispatch("call_status", {"call_id": "unknown"}) == {"ok": False, "error": "not found"}


def test_rings_from_many_threads_at_once_get_distinct_ids():
    sink = _Sink()
    service = _service(sink)
    ids: list[str] = []
    lock = threading.Lock()

    def ring(i: int) -> None:
        result = service.ring(f"thread-{i}", "pizza", "normal")
        with lock:
            ids.append(result["call_id"])

    threads = [threading.Thread(target=ring, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(set(ids)) == 20
    assert len(service.registry.ringing()) == 20


# -- host wiring ------------------------------------------------------------------


def test_the_host_resends_ringing_calls_when_a_controller_provisions_again(tmp_path):
    """Every connection sends ``account_authentication``; on the cloud pipe a
    new or returning controller lands in ``_on_reprovision``. That is the
    moment the app can take the ring again."""
    from test_reprovision import _host

    host, party = _host(tmp_path, attached=False)
    host._calls = CallService(
        send=host._send_host_payload, agent_resolver=host._call_agent, timers=False
    )
    result = host._calls.ring("thread-1", "pizza", "normal")
    assert result["delivered"] is False and party.frames == []

    party.controller_attached = True
    host._on_reprovision({"type": "account_authentication", "access_token": "a2"})

    incoming = [f for f in party.frames if f.get("type") == TYPE_VOICE_CALL_INCOMING]
    assert [f["call_id"] for f in incoming] == [result["call_id"]]
    host._on_call_frame({"type": "voice_call_state", "call_id": result["call_id"], "state": "declined"})
    assert host._calls.registry.get(result["call_id"]).state == STATE_DECLINED


def test_the_host_names_the_caller_as_the_user_named_the_coworker(tmp_path):
    from test_reprovision import _host

    host, _party = _host(tmp_path, attached=True)
    host._coworker_names.upsert("local:desk:1:7", "Crypto Desk", created_by_app=True)
    assert host._call_agent("local:desk:1:7") == ("local:desk:1:7", "Crypto Desk")
    # Any other key is this host's own coworker; unnamed, it is the generic
    # label and never the roster codename ("t" here).
    assert host._call_agent("default") == ("host:cowork-host", "Your coworker")
    host._coworker_names.upsert("host:cowork-host", "Laptop Bot", created_by_app=False)
    assert host._call_agent("thread-1") == ("host:cowork-host", "Laptop Bot")
