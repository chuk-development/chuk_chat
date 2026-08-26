"""The wire protocol that runs *inside* the encrypted frames, plus the relay
envelope that carries them (tasks 2 and 3).

Two layers, from outside in:

1. **Relay envelope** (``cowork_manager.relay``): newline-delimited JSON-RPC
   frames correlated by ``requestId``. The relay is blind — it never sees past
   this layer. A controller opens a task with a ``run_task`` *request*; the
   executor streams progress back as ``event`` *requests* (notifications) and
   closes with a *response* correlated to the original ``requestId``.

2. **Sealed CoWork frame** (``cowork_crypto``): the ``frame`` field of every
   envelope is base64 of a sealed frame. Opening it yields the JSON payload
   below. This is the only layer that is authenticated and encrypted.

In-frame payload protocol
--------------------------
Controller -> executor (one, opens the task)::

    {"type": "task", "prompt": "...", "session_key": "..."}

Controller -> executor (any time after it, aborts a run — §7.1, §16)::

    {"type": "stop", "request_id": "task-3"}        # exact: one relay request
    {"type": "stop", "session_key": "default"}      # thread-level: that thread's run

A stop is a frame like every other one: sealed, signed, replay-checked. That is
deliberate — the kill switch is reachable only by an **approved device**, so a
stranger who can talk to the relay cannot end other people's runs, and the
executor's default-deny opener is the whole enforcement (no extra check).

A stop **names its target**, and a stop that names nothing stops nothing. The
alternative ("abort whatever is running") loses a race it cannot see: the run the
user meant can finish while the frame is in flight, and the stop would then kill
the *next* task in that thread. ``request_id`` is the exact handle for a
controller that speaks the relay layer itself; ``session_key`` is the handle the
app has, because the app chose it when it sent the task, and it knows it before
the first event of the run comes back. The executor answers every stop with::

    {"type": "stop_ack", "stopping": ["task-3"]}   # [] = nothing matched

so a lost stop and a stop that matched nothing are distinguishable instead of
both looking like silence.

Executor -> controller (a stream, closed by ``done`` or ``error``)::

    {"type": "delta", "text": "..."}                     # an assistant text turn
    {"type": "tool",  "name": "run_command",             # a tool that just ran
     "command": "...", "exit_code": 0,
     "stdout": "...", "stderr": "...", "timed_out": false}
    {"type": "file",  "name": "report.csv",               # a file for the user
     "mime_type": "text/csv", "size": 1234,
     "data": "<base64>"}
    {"type": "subagent",                                  # a child agent (§7.6)
     "event": {"type": "subagent_state", ...}}            #   state or streamed output
    {"type": "room_create",                               # app -> host: create a room
     "room_id": "...", "name": "...",
     "members": [{"agent_id": "...", "handle": "amber"}]}
    {"type": "room_task",                                 # app -> host: start a room
     "room_id": "...", "message": "..."}
    {"type": "room_add_member",                           # app -> host: add member
     "room_id": "...", "agent_id": "...", "handle": "..."}
    {"type": "room_remove_member",                        # app -> host: remove member
     "room_id": "...", "agent_id": "..."}
    {"type": "room_rename", "room_id": "...", "name": "..."}  # app -> host: rename
    {"type": "room_delete", "room_id": "..."}             # app -> host: forget a room
    {"type": "room_history_request", "room_id": "..."}    # app -> host: replay it
    {"type": "room_history",                              # host -> app: stored turns
     "room_id": "...", "turns": [{"round": 1, ...}]}
    {"type": "room_turn",                                 # one member's turn (§16.1)
     "room_id": "...", "round": 1, "agent_id": "...",
     "handle": "amber", "text": "..."}
    {"type": "room_done",                                 # the room exchange ended
     "room_id": "...", "reason": "no_more_mentions",
     "messages_sent": 3, "rounds": 2}
    {"type": "done",  "final_answer": "...",              # loop finished cleanly
     "reason": "finished", "iterations": 3, "tokens_spent": 1234}
    {"type": "error", "message": "..."}                   # rejected / crashed

The ``file`` event (§9, ``send_file_to_user``) is how a produced file reaches the
chat thread. It rides the same sealed frame as every other event, so a file the
agent made is encrypted end to end exactly like the text around it, and the relay
sees nothing. It is the one event with an unbounded-by-nature body, so it is the
one event with a **hard size gate**: :func:`file_payload` refuses anything over
:data:`MAX_FILE_BYTES` rather than pushing a hundred megabytes through a phone
connection. The agent-side tool checks the same ceiling before it moves a byte;
this second gate is what makes that a guarantee instead of a convention.
"""

from __future__ import annotations

import base64
import json
from typing import Any

# Hard ceiling for one ``file`` event, in raw bytes. Base64 inside the sealed
# frame and base64 again in the relay envelope put an 8 MiB file at roughly
# 15 MiB on the wire — the most that is reasonable to move in one frame.
# Mirrors ``cowork_agent.files_out.MAX_FILE_BYTES``.
MAX_FILE_BYTES = 8 * 1024 * 1024


class PayloadTooLarge(ValueError):
    """A file event exceeded :data:`MAX_FILE_BYTES` and was not built."""

# -- in-frame payload builders ------------------------------------------------


def task_payload(prompt: str, session_key: str = "default") -> dict[str, Any]:
    return {"type": "task", "prompt": prompt, "session_key": session_key}


def stop_payload(
    *, request_id: str | None = None, session_key: str | None = None
) -> dict[str, Any]:
    """Build a ``stop``: abort the run named by ``request_id`` or ``session_key``.

    Raises :class:`ValueError` when neither is given — a stop with no target is a
    stop that would have to guess, and guessing kills the wrong run.
    """
    if not request_id and not session_key:
        raise ValueError("a stop must name a request_id or a session_key")
    payload: dict[str, Any] = {"type": "stop"}
    if request_id:
        payload["request_id"] = request_id
    if session_key:
        payload["session_key"] = session_key
    return payload


def stop_ack_payload(stopping: list[str]) -> dict[str, Any]:
    """Answer a ``stop``: the request ids that were told to stop (possibly none)."""
    return {"type": "stop_ack", "stopping": list(stopping)}


def delta_payload(text: str) -> dict[str, Any]:
    return {"type": "delta", "text": text}


def tool_payload(
    *,
    name: str,
    command: str,
    exit_code: int,
    stdout: str,
    stderr: str,
    timed_out: bool,
) -> dict[str, Any]:
    return {
        "type": "tool",
        "name": name,
        "command": command,
        "exit_code": exit_code,
        "stdout": stdout,
        "stderr": stderr,
        "timed_out": timed_out,
    }


def file_payload(
    *,
    name: str,
    mime_type: str,
    data: bytes,
    max_bytes: int = MAX_FILE_BYTES,
) -> dict[str, Any]:
    """Build a ``file`` event: one produced file on its way to the user.

    ``size`` is the raw byte count and ``data`` is that same content base64'd,
    so a receiver can check the decode against the declared length instead of
    trusting it. Raises :class:`PayloadTooLarge` past ``max_bytes``; the caller
    reports that to the model as a normal tool failure.
    """
    if not isinstance(data, (bytes, bytearray)):
        raise TypeError("file data must be bytes")
    size = len(data)
    if size == 0:
        raise ValueError("file is empty")
    if size > max_bytes:
        raise PayloadTooLarge(
            f"file is {size} bytes, over the {max_bytes} byte event limit"
        )
    return {
        "type": "file",
        "name": name,
        "mime_type": mime_type,
        "size": size,
        "data": base64.b64encode(bytes(data)).decode("ascii"),
    }


def subagent_payload(event: dict[str, Any]) -> dict[str, Any]:
    """Wrap one supervisor event (§7.6) as an in-frame ``subagent`` event.

    Nested rather than flattened: the supervisor's own events already carry a
    ``type`` (``subagent_state`` / ``subagent_output``), and merging two type
    fields into one dict is how a wire format starts lying about itself. The app
    renders the subagent list from ``event``.
    """
    return {"type": "subagent", "event": event}


def room_create_payload(
    *, room_id: str, name: str, members: list[dict]
) -> dict[str, Any]:
    """App -> host: create a room on the host so ``room_task`` can drive it
    (§16.1). ``members`` is ``[{"agent_id": ..., "handle": ...}]`` in room order;
    the app owns the ``room_id`` and the host stores the room under it."""
    return {
        "type": "room_create",
        "room_id": room_id,
        "name": name,
        "members": members,
    }


def room_add_member_payload(
    *, room_id: str, agent_id: str, handle: str
) -> dict[str, Any]:
    """App -> host: add a coworker to an existing room (§16.1)."""
    return {
        "type": "room_add_member",
        "room_id": room_id,
        "agent_id": agent_id,
        "handle": handle,
    }


def room_remove_member_payload(*, room_id: str, agent_id: str) -> dict[str, Any]:
    """App -> host: remove a coworker from a room (§16.1)."""
    return {"type": "room_remove_member", "room_id": room_id, "agent_id": agent_id}


def room_rename_payload(*, room_id: str, name: str) -> dict[str, Any]:
    """App -> host: rename a room (§16.1)."""
    return {"type": "room_rename", "room_id": room_id, "name": name}


def room_delete_payload(*, room_id: str) -> dict[str, Any]:
    """App -> host: forget a room (§16.1) — drop it from the store and its stored
    transcript, so nothing about it is left behind."""
    return {"type": "room_delete", "room_id": room_id}


def room_history_request_payload(*, room_id: str) -> dict[str, Any]:
    """App -> host: replay a reopened room's stored transcript (§16.1). The host
    answers with one ``room_history`` frame."""
    return {"type": "room_history_request", "room_id": room_id}


def room_history_payload(*, room_id: str, turns: list[dict]) -> dict[str, Any]:
    """Host -> app: a room's stored turns, in spoken order. Each turn is the same
    shape a live ``room_turn`` carries, minus its own ``type`` wrapper."""
    return {"type": "room_history", "room_id": room_id, "turns": turns}


def room_task_payload(*, room_id: str, message: str) -> dict[str, Any]:
    """The app -> host frame that starts a group-room exchange (§16.1). Names the
    room and carries the user's message; the host looks the room's members up in
    its RoomStore and drives them, streaming ``room_turn`` / ``room_done`` back."""
    return {"type": "room_task", "room_id": room_id, "message": message}


def room_turn_payload(
    *, room_id: str, round: int, agent_id: str, handle: str, text: str
) -> dict[str, Any]:
    """One member's turn in a group room (§16.1). Streamed as it happens, so the
    app renders the back-and-forth live rather than after the whole exchange.

    ``room_id`` names which room the turn belongs to, so the app routes it to the
    right open room — several rooms can run at once."""
    return {
        "type": "room_turn",
        "room_id": room_id,
        "round": round,
        "agent_id": agent_id,
        "handle": handle,
        "text": text,
    }


def room_done_payload(
    *, room_id: str, reason: str, messages_sent: int, rounds: int
) -> dict[str, Any]:
    """The room exchange ended. ``reason`` is a RoomSession/RoomRunner stop
    string (``no_more_mentions`` / ``rounds_exhausted`` / ``messages_exhausted``
    / ``stopped`` / ``turn_failed``) so the app can name why without guessing."""
    return {
        "type": "room_done",
        "room_id": room_id,
        "reason": reason,
        "messages_sent": messages_sent,
        "rounds": rounds,
    }


def done_payload(
    *, final_answer: str | None, reason: str, iterations: int, tokens_spent: int = 0
) -> dict[str, Any]:
    return {
        "type": "done",
        "final_answer": final_answer,
        "reason": reason,
        "iterations": iterations,
        # Prompt + completion tokens the run spent, so the app can show a cost
        # (§7.6). Zero when the backend reported no usage.
        "tokens_spent": tokens_spent,
    }


def error_payload(message: str) -> dict[str, Any]:
    return {"type": "error", "message": message}


def encode_payload(payload: dict[str, Any]) -> bytes:
    """Serialize an in-frame payload to the bytes a sealer seals."""
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def decode_payload(plaintext: bytes) -> dict[str, Any]:
    """Parse the plaintext an opener returns back into a payload dict."""
    return json.loads(plaintext.decode("utf-8"))


# -- relay envelope <-> sealed frame ------------------------------------------

# Relay method names. ``run_task`` opens a task; ``stop`` aborts one; ``event`` is
# a server-initiated progress notification. The terminal is a plain relay
# *response* (no method).
#
# The method is only a routing hint. What the executor acts on is the **payload
# type inside the sealed frame**, because the host that forwards app frames is
# blind by design: it cannot read a frame, so it cannot label it, and it wraps
# everything as ``run_task``. Trusting the cleartext method would mean trusting
# the one layer that is neither encrypted nor signed.
METHOD_RUN_TASK = "run_task"
METHOD_STOP = "stop"
METHOD_EVENT = "event"

#: Envelope methods the executor accepts a sealed controller frame on.
INBOUND_METHODS = (METHOD_RUN_TASK, METHOD_STOP)


def frame_to_b64(sealed_bytes: bytes) -> str:
    """Wire-encode a sealed CoWork frame for the ``frame`` envelope field."""
    return base64.b64encode(sealed_bytes).decode("ascii")


def b64_to_frame(value: str) -> bytes:
    """Recover the sealed CoWork frame bytes from an envelope ``frame`` field."""
    return base64.b64decode(value)
