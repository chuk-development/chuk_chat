"""The agent calls the user: ``call_user`` and ``call_status``.

This module is the agent-side half of docs/WIRE_CONTRACT.md, section "The
agent calls the user". It holds the tool schemas, the argument checks and the
registration. The host side (the call registry, the sealed ``voice_call_*``
frames, the expiry) lives in ``chuk_agents_host.calls``.

The two halves meet at :class:`CallBackend`. The executor binds one to the
task's ``session_key`` and gives it to ``build_runtime``. A call therefore
always belongs to the conversation that started it, and ``call_status`` can
only read the calls of that conversation. There is no tool argument for the
session.

``call_user`` does not wait for the answer. It starts the ring and returns at
once with ``ringing (call_id ...)``. The model reads the outcome later with
``call_status``. A declined or missed call adds nothing to the thread: the
default is silence (docs/PERSONAL_AGENT_SPEC.md §4, rule 5).
"""

from __future__ import annotations

from typing import Any, Protocol

from .registry import ToolRegistry

URGENCY_NORMAL = "normal"
URGENCY_HIGH = "high"
URGENCIES = (URGENCY_NORMAL, URGENCY_HIGH)

#: The longest reason the host keeps. The app shows a short line of it on the
#: incoming-call screen; the voice worker gets the whole text as the brief.
MAX_REASON_CHARS = 1000

CALL_TOOL_NAMES = ("call_user", "call_status")


class CallBackend(Protocol):
    """What the tools need from the host, already bound to ONE session.

    ``ring`` answers ``{"ok": True, "call_id", "state": "ringing",
    "expires_at", "delivered"}``. ``delivered`` is False when no app was
    attached to receive the ring. ``status`` answers the call's fields, or
    ``{"ok": False, "error": "not found"}`` for an id of another session.
    """

    def ring(self, reason: str, urgency: str) -> dict: ...

    def status(self, call_id: str) -> dict: ...


CALL_USER_SCHEMA = {
    "type": "object",
    "description": (
        "Ring the user's phone and desktop app like a phone call, so the user "
        "can talk to you live. Use it ONLY when the user asked you to call "
        "them (for example a reminder by call: 'remind me in 10 minutes by "
        "calling me'), or for something truly urgent. Never use it for routine "
        "updates, a finished task or a question that can wait; write a normal "
        "answer for those. The tool returns at once with 'ringing (call_id "
        "...)'. It does not wait for the user to answer. The call rings for "
        "about two minutes; read the outcome later with call_status(call_id)."
    ),
    "properties": {
        "reason": {
            "type": "string",
            "description": (
                "Why you call, in one or two short sentences for the user, "
                "e.g. 'Your pizza is ready to come out of the oven.' The app "
                "shows it on the incoming-call screen."
            ),
        },
        "urgency": {
            "type": "string",
            "enum": list(URGENCIES),
            "description": "'normal' (default) or 'high' for something that cannot wait.",
            "default": URGENCY_NORMAL,
        },
    },
    "required": ["reason"],
}

CALL_STATUS_SCHEMA = {
    "type": "object",
    "description": (
        "The state of a call you started with call_user: ringing, accepted, "
        "declined, missed (nobody answered in time) or ended. If the user "
        "declined or missed a call that mattered, send a short normal message "
        "instead of calling again."
    ),
    "properties": {
        "call_id": {"type": "string", "description": "The id call_user returned."},
    },
    "required": ["call_id"],
}


def _error(message: str) -> dict:
    return {"ok": False, "error": message}


def clean_reason(reason: Any) -> str:
    """The reason as one trimmed text of at most :data:`MAX_REASON_CHARS`."""
    if not isinstance(reason, str):
        return ""
    text = reason.strip()
    if len(text) > MAX_REASON_CHARS:
        text = text[: MAX_REASON_CHARS - 1].rstrip() + "…"
    return text


def ringing_message(result: dict) -> str:
    """What the model reads after a ring. One line, and a hint when no app was
    attached, so the model can also write a normal message."""
    call_id = str(result.get("call_id") or "")
    line = f"ringing (call_id {call_id})"
    if result.get("delivered") is False:
        return (
            f"{line}; no app is connected right now, the user may miss it. "
            "Also write the reason in your answer so the user sees it later."
        )
    return f"{line}. Check call_status(call_id) later to see if the user answered."


def make_call_user_handler(backend: CallBackend):
    def call_user(reason: str, urgency: str = URGENCY_NORMAL) -> Any:
        text = clean_reason(reason)
        if not text:
            return _error("reason must not be empty: say in one sentence why you call")
        level = (urgency or URGENCY_NORMAL).strip().lower() if isinstance(urgency, str) else ""
        if level not in URGENCIES:
            return _error("urgency must be 'normal' or 'high'")
        result = backend.ring(text, level)
        if not isinstance(result, dict) or not result.get("ok"):
            message = result.get("error") if isinstance(result, dict) else None
            return _error(str(message or "the call could not be started"))
        return ringing_message(result)

    return call_user


def make_call_status_handler(backend: CallBackend):
    def call_status(call_id: str) -> dict:
        if not isinstance(call_id, str) or not call_id.strip():
            return _error("call_id must not be empty")
        return backend.status(call_id.strip())

    return call_status


def register_call_tools(registry: ToolRegistry, backend: CallBackend | None) -> None:
    """Register ``call_user`` and ``call_status`` against one session-bound
    backend. ``None`` registers nothing: a runtime without a host has no app to
    ring, and the model must not be offered a tool that cannot work."""
    if backend is None:
        return
    registry.register("call_user", CALL_USER_SCHEMA, make_call_user_handler(backend))
    registry.register("call_status", CALL_STATUS_SCHEMA, make_call_status_handler(backend))


class RecordingCallBackend:
    """An in-memory backend for tests: records the rings, answers fixed rows."""

    def __init__(self, *, delivered: bool = True) -> None:
        self.delivered = delivered
        self.calls: list[dict] = []

    def ring(self, reason: str, urgency: str) -> dict:
        call_id = f"c{len(self.calls) + 1}"
        row = {"call_id": call_id, "reason": reason, "urgency": urgency, "state": "ringing"}
        self.calls.append(row)
        return {
            "ok": True,
            "call_id": call_id,
            "state": "ringing",
            "expires_at": 0.0,
            "delivered": self.delivered,
        }

    def status(self, call_id: str) -> dict:
        for row in self.calls:
            if row["call_id"] == call_id:
                return {"ok": True, **row}
        return _error("not found")


__all__ = [
    "CALL_STATUS_SCHEMA",
    "CALL_TOOL_NAMES",
    "CALL_USER_SCHEMA",
    "CallBackend",
    "MAX_REASON_CHARS",
    "RecordingCallBackend",
    "URGENCIES",
    "URGENCY_HIGH",
    "URGENCY_NORMAL",
    "clean_reason",
    "register_call_tools",
    "ringing_message",
]
