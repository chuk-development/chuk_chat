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
    {"type": "done",  "final_answer": "...",              # loop finished cleanly
     "reason": "finished", "iterations": 3}
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


def done_payload(
    *, final_answer: str | None, reason: str, iterations: int
) -> dict[str, Any]:
    return {
        "type": "done",
        "final_answer": final_answer,
        "reason": reason,
        "iterations": iterations,
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

# Relay method names. ``run_task`` opens a task; ``event`` is a server-initiated
# progress notification. The terminal is a plain relay *response* (no method).
METHOD_RUN_TASK = "run_task"
METHOD_EVENT = "event"


def frame_to_b64(sealed_bytes: bytes) -> str:
    """Wire-encode a sealed CoWork frame for the ``frame`` envelope field."""
    return base64.b64encode(sealed_bytes).decode("ascii")


def b64_to_frame(value: str) -> bytes:
    """Recover the sealed CoWork frame bytes from an envelope ``frame`` field."""
    return base64.b64decode(value)
