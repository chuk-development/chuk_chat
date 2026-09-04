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

    {"type": "task", "prompt": "...", "session_key": "...",
     "model": "anthropic/claude-x",                      # optional: this task's
     "provider": "anthropic",                            #   model, its provider,
     "reasoning_effort": "low",                          #   and its think level
     "mcp_servers": [                                    # optional (§9, §10)
       {"name": "github", "url": "https://api.example/v1/mcp/github",
        "transport": "http", "auth": "appSession"},
       {"name": "tickets", "url": "https://mcp.acme.com/mcp",
        "transport": "http", "auth": "oauth", "access_token": "..."}]}

``mcp_servers`` is additive and optional. The Flutter host resolves each
UI-configured connection's live bearer at task launch and forwards the list
*inside* this sealed frame; the executor builds a per-session ``MCPManager``
from it, attaching ``Authorization: Bearer <token>`` to the HTTP targets. An
``appSession`` connector uses the executor's own account token (server-side,
never in the frame); an ``oauth`` connector forwards its device token here. A
frame with no ``mcp_servers`` is byte-for-byte the old one.

Controller -> executor (any time after it, aborts a run — §7.1, §16)::

    {"type": "stop", "request_id": "task-3"}        # exact: one relay request
    {"type": "stop", "session_key": "default"}      # thread-level: that thread's run
    {"type": "approval_decision",                   # answer a here.now publish ask
     "approval_id": "ap-1", "approved": true}
    {"type": "replay", "session_key": "default"}    # re-stream a thread's transcript

A ``replay`` asks the executor to re-send a thread's whole stored transcript. The
server is the source of truth, so a reconnecting or reinstalled client sends this
and rebuilds the thread from the answer. The executor streams the stored turns as
the SAME ``user`` / ``delta`` / ``tool`` events a live run uses, each carrying
``"replay": true``, and closes with a ``done`` (``reason`` ``"replay"``, also
marked ``replay``). An unknown ``session_key`` replays an empty thread: just the
``done``.

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
    {"type": "approval_request",                          # ask before a public publish
     "approval_id": "ap-1", "action": "herenow_publish",
     "path": "site", "name": "My Page", "file_count": 2,
     "total_bytes": 1024, "base_url": "https://here.now", "public": true}
    {"type": "done",  "final_answer": "...",              # loop finished cleanly
     "reason": "finished", "iterations": 3, "tokens_spent": 1234}
    {"type": "error", "message": "..."}                   # rejected / crashed

The ``approval_request`` event is the one place the executor **waits** on the
app: the run blocks on its worker thread until an ``approval_decision`` with the
matching ``approval_id`` comes back (a stop or a timeout ends the wait as a
denial). It is what makes here.now publishing user-gated (§10-style consent) —
the only executor->app frame that expects a reply.

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


def task_payload(
    prompt: str,
    session_key: str = "default",
    *,
    mcp_servers: list[dict] | None = None,
    herenow: dict | None = None,
    debug: bool = False,
    model: str | None = None,
    provider: str | None = None,
    reasoning_effort: str | None = None,
) -> dict[str, Any]:
    """Build the ``task`` frame that opens a run.

    ``mcp_servers`` is optional and additive: when the Flutter host has
    UI-configured MCP connections for this session, it puts them here so the
    executor can build an authenticated ``MCPManager`` before the loop starts.
    Each entry is ``{name, url, transport, auth, access_token?}`` (``headers``
    and ``env`` are honored too, as in ``mcp.json``); ``auth`` is one of
    ``appSession`` (use the executor's account bearer, resolved server-side),
    ``oauth`` (forward this entry's ``access_token``), or ``none``. Absent or
    empty -> the frame is byte-for-byte the old one, and behavior is unchanged.

    ``herenow`` is the here.now publish connector's setting, forwarded the same
    additive way: ``{"enabled": bool, "approval": "ask"|"auto"}``. Absent or
    disabled, the executor registers no publish tool at all. When enabled with
    ``approval == "ask"`` (the default), a public publish blocks on an
    ``approval_request`` the app must answer with ``approval_decision``.

    ``debug`` (optional, off by default) turns on the "copy raw context" tap: the
    executor wires a debug observer that streams one ``debug_context`` event per
    model round. Absent or false -> no observer, and the frame is unchanged.

    ``model`` / ``provider`` / ``reasoning_effort`` name the model this one task
    runs on, and how hard it thinks. They are what the app's mode selector sends:
    ``model`` is the model id, ``provider`` its provider slug (empty -> the host
    routes), ``reasoning_effort`` the Fast/Thinking level. All three are optional
    and additive; absent, the host uses its default model and default effort, so
    an older client that sends none keeps working unchanged. The keys ride
    *inside* the sealed frame, so this does not touch the frame crypto.
    """
    payload: dict[str, Any] = {
        "type": "task",
        "prompt": prompt,
        "session_key": session_key,
    }
    if mcp_servers:
        payload["mcp_servers"] = list(mcp_servers)
    if herenow:
        payload["herenow"] = dict(herenow)
    if debug:
        payload["debug"] = True
    if model:
        payload["model"] = model
    if provider:
        payload["provider"] = provider
    if reasoning_effort:
        payload["reasoning_effort"] = reasoning_effort
    return payload


def run_state_payload(
    session_key: str,
    state: str,
    *,
    run_id: str | None = None,
    started_at: float | None = None,
    prompt: str | None = None,
) -> dict[str, Any]:
    """Build the ``run_state`` event that opens every replay response (see
    ``docs/WIRE_CONTRACT.md``). ``state`` is ``running`` when a run for the
    session is in flight on the host, else ``idle``."""
    payload: dict[str, Any] = {
        "type": "run_state",
        "session_key": session_key,
        "state": state,
    }
    if run_id:
        payload["run_id"] = run_id
    if started_at is not None:
        payload["started_at"] = started_at
    if prompt is not None:
        payload["prompt"] = prompt
    return payload


def run_ack_payload(run_id: str) -> dict[str, Any]:
    """Build a ``run_ack`` frame: the app confirms it rendered a live ``done``
    for ``run_id``, so the host can skip a completion notification."""
    return {"type": "run_ack", "run_id": run_id}


def replay_payload(session_key: str = "default", *, after_id: int = 0) -> dict[str, Any]:
    """Build a ``replay`` frame: ask the executor to re-stream a thread's whole
    stored transcript (the server is the truth — see ``docs/PRODUCT_PHILOSOPHY``).

    A reconnecting or reinstalled client has no local transcript for the thread.
    It sends this one frame, and the executor answers with the same ``user`` /
    ``delta`` / ``tool`` events a live run streams, each marked ``replay``, then
    closes the stream with a ``done`` (also marked ``replay``). The client rebuilds
    the thread as history, not as a running task.

    A frame with an unknown ``session_key`` replays an empty thread: no events, a
    ``done`` at once. So a client can always ask, and never has to know first
    whether the thread has any stored turns.
    """
    payload: dict[str, Any] = {"type": "replay", "session_key": session_key}
    if after_id > 0:
        # The replay cursor: only the rows after this message id come back.
        payload["after_id"] = int(after_id)
    return payload


def approval_request_payload(
    *,
    approval_id: str,
    path: str,
    name: str,
    file_count: int,
    total_bytes: int,
    base_url: str,
    public: bool = True,
) -> dict[str, Any]:
    """Executor -> app: ask the user to approve one public here.now publish.

    Sent when the here.now connector is in ``ask`` mode and the model calls
    ``herenow_publish``. The run **blocks** on the worker thread until the app
    answers with an :func:`approval_decision_payload`; a stop or a timeout
    counts as a denial. The fields are what a human needs to decide — what is
    going out (``path``/``name``), how much (``file_count``/``total_bytes``),
    and where (``base_url``) — and ``public`` records that an anonymous site is
    an open, link-shareable URL.
    """
    return {
        "type": "approval_request",
        "approval_id": approval_id,
        "action": "herenow_publish",
        "path": path,
        "name": name,
        "file_count": file_count,
        "total_bytes": total_bytes,
        "base_url": base_url,
        "public": public,
    }


def approval_decision_payload(*, approval_id: str, approved: bool) -> dict[str, Any]:
    """App -> executor: the user's answer to one ``approval_request``.

    Correlated by ``approval_id`` (an ``approval_request`` the app never saw, or
    a decision that arrives after the run already ended, matches nothing and is
    a no-op). ``approved`` True publishes; False (or no answer) does not.
    """
    return {
        "type": "approval_decision",
        "approval_id": approval_id,
        "approved": bool(approved),
    }


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
    *,
    final_answer: str | None,
    reason: str,
    iterations: int,
    tokens_spent: int = 0,
    run_id: str | None = None,
    while_away: bool = False,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "type": "done",
        "final_answer": final_answer,
        "reason": reason,
        "iterations": iterations,
        # Prompt + completion tokens the run spent, so the app can show a cost
        # (§7.6). Zero when the backend reported no usage.
        "tokens_spent": tokens_spent,
    }
    # docs/WIRE_CONTRACT.md: which run ended, and whether it ended with no app
    # attached (so the app shows "answer ready" instead of a live end).
    if run_id:
        payload["run_id"] = run_id
    if while_away:
        payload["while_away"] = True
    return payload


def error_payload(message: str) -> dict[str, Any]:
    return {"type": "error", "message": message}


def debug_context_payload(
    *,
    session_key: str,
    round: int,
    messages: list[dict],
    stats: dict[str, Any],
) -> dict[str, Any]:
    """The debug "copy raw context" event (opt-in per task via ``debug``).

    Carries the EXACT message list the loop sent to the model for this round and
    the context ladder's stats (``tier`` / ``pressure`` / ``tokens_before`` /
    ``tokens_after``), so the app can show and copy what really went on the wire.
    Streamed once per model round; never sent unless the task asked for it.
    """
    return {
        "type": "debug_context",
        "session_key": session_key,
        "round": round,
        "messages": messages,
        "stats": stats,
    }


# -- live browser view (§9.1) -------------------------------------------------
#
# The user watches and controls the agent's sandbox Chromium over a raw RFB
# (VNC) byte stream tunneled inside the sealed channel — no new ports, no RFB
# parsing on either the host or the executor. The executor runs x11vnc in the
# container and a `docker exec socat` pipe to its localhost RFB port; the bytes
# in both directions are these payloads. The Flutter side speaks RFB (via
# flutter_rfb over a loopback socket), so nothing here interprets the stream —
# `browser_data` is an opaque chunk each way.
#
# `browser_start` / `browser_stop` are app -> executor control frames (parsed,
# not built here). `browser_data` flows BOTH ways: executor -> app carries the
# RFB server's bytes, app -> executor carries the RFB client's bytes (its
# handshake and every pointer/key event). `browser_view` is executor -> app
# status (started / stopped / error), so the app can show or dismiss the view.

#: A single RFB chunk is small (a framebuffer tile or a burst of client input),
#: so the whole-file 8 MiB ceiling would be absurd here. Bound each chunk so a
#: runaway read cannot seal a giant frame; the pump simply sends more payloads.
MAX_BROWSER_CHUNK = 512 * 1024


def browser_data_payload(data: bytes, *, max_bytes: int = MAX_BROWSER_CHUNK) -> dict[str, Any]:
    """One raw RFB byte chunk, base64'd (JSON cannot hold bytes). Bidirectional."""
    if not isinstance(data, (bytes, bytearray)):
        raise TypeError("browser data must be bytes")
    size = len(data)
    if size == 0:
        raise ValueError("browser chunk is empty")
    if size > max_bytes:
        raise PayloadTooLarge(
            f"browser chunk is {size} bytes, over the {max_bytes} byte limit"
        )
    return {
        "type": "browser_data",
        "size": size,
        "data": base64.b64encode(bytes(data)).decode("ascii"),
    }


def browser_view_payload(
    status: str, *, message: str = "", password: str | None = None
) -> dict[str, Any]:
    """Executor -> app status for the live browser view.

    ``status`` is ``"started"`` (the stream is live, the app may show the view),
    ``"stopped"`` (torn down — user asked, or the pipe/container went away), or
    ``"error"`` (could not bring the view up; ``message`` says why).

    ``password`` rides only on ``"started"``: the per-view VNC secret x11vnc was
    (re)armed with. It travels inside the sealed frame, so only the paired app
    ever sees it; inside the sandbox the secret sits in a root-only file, so the
    agent's own code cannot read the screen or inject input (§9.1 hardening).
    """
    payload: dict[str, Any] = {"type": "browser_view", "status": status, "message": message}
    if password is not None:
        payload["password"] = password
    return payload


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
