"""The wire protocol that runs *inside* the encrypted frames, plus the relay
envelope that carries them (tasks 2 and 3).

Two layers, from outside in:

1. **Relay envelope** (``chuk_agents_manager.relay``): newline-delimited JSON-RPC
   frames correlated by ``requestId``. The relay is blind — it never sees past
   this layer. A controller opens a task with a ``run_task`` *request*; the
   executor streams progress back as ``event`` *requests* (notifications) and
   closes with a *response* correlated to the original ``requestId``.

2. **Sealed Agents frame** (``chuk_agents_crypto``): the ``frame`` field of every
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
    {"type": "agent_status",                              # what this coworker
     "session_key": "...",                                #   runs on and spent
     "model": {"id": "...", "provider": "...", "reasoning_effort": "..."},
     "tokens": {"total": 1234, "runs": 3, "last_run": 456},
     "runtime": {"started_at": 1.0, "active_seconds": 12.5, "running": false},
     "sandbox": {"kind": "docker", "container": "agents-...", "workspace": "..."}}
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
import os
import sys
from pathlib import Path
from typing import Any

# Hard ceiling for one ``file`` event, in raw bytes. Base64 inside the sealed
# frame and base64 again in the relay envelope put an 8 MiB file at roughly
# 15 MiB on the wire — the most that is reasonable to move in one frame.
# Mirrors ``chuk_agents_runtime.files_out.MAX_FILE_BYTES``.
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
    regenerate: bool = False,
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

    ``regenerate`` (optional, off by default) says this task REPLACES the last
    answer instead of asking a new question — the app's Retry button. The
    executor then drops the turn being retried before it appends this prompt, so
    the conversation holds the question once and the newest answer, not one copy
    per attempt. Absent or false -> the frame and the behavior are unchanged.

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
    if regenerate:
        payload["regenerate"] = True
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
    browser_open: bool | None = None,
    vnc_available: bool = False,
) -> dict[str, Any]:
    """Build the ``run_state`` event that opens every replay response (see
    ``docs/WIRE_CONTRACT.md``). ``state`` is ``running`` when a run for the
    session is in flight on the host, else ``idle``. ``browser_open`` is the
    host's word on whether the agent has a browser open (Bead cowork-vzm);
    left out when the caller does not know."""
    payload: dict[str, Any] = {
        "type": "run_state",
        "session_key": session_key,
        "state": state,
        "vnc_available": vnc_available,
    }
    if browser_open is not None:
        payload["browser_open"] = bool(browser_open)
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
    session_key: str | None = None,
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
        # The thread the run belongs to, so the app shows the prompt over the
        # right conversation and never over another one (P8 review F9).
        **({"session_key": session_key} if session_key else {}),
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


def reasoning_payload(text: str) -> dict[str, Any]:
    """One chunk of the model's thinking (docs/WIRE_CONTRACT.md, ``reasoning``).

    A separate channel from ``delta``: the app renders it as the collapsible
    thinking block above the answer and never folds it into the reply text.
    Streamed live per chunk as the backend relays ``kind: "reasoning"`` frames;
    replayed as one event per stored assistant turn (see
    ``StateStore.replay_events``)."""
    return {"type": "reasoning", "text": text}


def tool_payload(**fields: Any) -> dict[str, Any]:
    """One native tool call, after its result is known (docs/WIRE_CONTRACT.md,
    "Tool events and timestamps"). ``fields`` is what
    :func:`chuk_agents_runtime.tool_events.tool_event_fields` built: ``name``,
    ``arguments``, ``call_id``?, ``command``?, ``result``, the projected
    ``exit_code`` / ``stdout`` / ``stderr`` / ``timed_out`` when the result had
    them, ``status``, ``started_at``, ``completed_at``, ``duration_ms``. Live
    and replay share that shape, so the app draws the same card for both."""
    return {"type": "tool", **fields}


def file_payload(
    *,
    name: str,
    mime_type: str,
    data: bytes,
    max_bytes: int = MAX_FILE_BYTES,
    document: dict | None = None,
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
        **({"document": document} if document is not None else {}),
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
    run_stamps: dict[str, Any] | None = None,
    host_notified: bool = False,
    session_key: str | None = None,
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
    # "Run timestamps on done": the run's clock and message rows from its
    # ``runs`` row (``started_at`` / ``finished_at`` / ``first_mid`` /
    # ``last_mid``). ``last_mid`` is what moves the app's replay cursor past a
    # live run, so the next replay does not send that run again.
    if run_stamps:
        payload.update(run_stamps)
    # docs/WIRE_CONTRACT.md, "Automations": the host itself notifies on this
    # run (a fired automation), so the app skips its own local toast.
    if session_key is not None:
        payload["session_key"] = session_key
    if host_notified:
        payload["host_notified"] = True
    return payload


# -- automations (docs/WIRE_CONTRACT.md, "Automations") ----------------------


def automation_list_payload(automations: list[dict[str, Any]]) -> dict[str, Any]:
    """Host -> app: the answer to an ``automation_list`` request. One entry per
    automation, in the ``automation`` event's field shape minus ``event``."""
    return {"type": "automation_list", "automations": list(automations)}


def automation_control_payload(*, automation_id: str, action: str) -> dict[str, Any]:
    """App -> host: pause / resume / cancel one automation."""
    return {"type": "automation_control", "id": automation_id, "action": action}


def automation_list_request_payload(session_key: str | None = None) -> dict[str, Any]:
    """App -> host: list the automations (of one session, or all)."""
    payload: dict[str, Any] = {"type": "automation_list"}
    if session_key:
        payload["session_key"] = session_key
    return payload


def agent_create_payload(*, agent_id: str, name: str) -> dict[str, Any]:
    """App -> host: the user created a coworker in the app (docs/WIRE_CONTRACT.md,
    "Coworker names"). The app owns the id; the host keeps the name."""
    return {"type": "agent_create", "agent_id": agent_id, "name": name}


def agent_rename_payload(*, agent_id: str, name: str) -> dict[str, Any]:
    """App -> host: the user renamed a coworker (the host agent included)."""
    return {"type": "agent_rename", "agent_id": agent_id, "name": name}


def agent_list_request_payload() -> dict[str, Any]:
    """App -> host: list every coworker name this host keeps."""
    return {"type": "agent_list"}


def agent_list_payload(agents: list[dict[str, Any]]) -> dict[str, Any]:
    """Host -> app: the coworker names. One entry per id:
    ``{"agent_id", "name", "host"}`` — ``host`` marks the coworker that runs
    on this host. Answers ``agent_list`` and follows every applied
    ``agent_create`` / ``agent_rename``."""
    return {"type": "agent_list", "agents": list(agents)}


def skills_list_payload(
    skills: list[dict[str, Any]], errors: list[str] | tuple[str, ...] = ()
) -> dict[str, Any]:
    """Host -> app: the answer to a ``skills_list`` request AND to a
    ``skill_control`` (docs/WIRE_CONTRACT.md, "Skills"). Every skill on the
    host, enabled or not; ``errors`` names what could not be loaded or what a
    control refused."""
    return {"type": "skills_list", "skills": list(skills), "errors": list(errors)}


def skill_control_payload(*, name: str, action: str) -> dict[str, Any]:
    """App -> host: switch one skill ``enable`` / ``disable``."""
    return {"type": "skill_control", "name": name, "action": action}


def skills_list_request_payload() -> dict[str, Any]:
    """App -> host: list every skill of the host."""
    return {"type": "skills_list"}


def agent_status_request_payload(session_key: str = "default") -> dict[str, Any]:
    """App -> host: what is this coworker running on, what has it spent, how
    long has it been at it (docs/WIRE_CONTRACT.md, "Agent status")."""
    return {"type": "agent_status", "session_key": session_key}


def agent_status_payload(
    *,
    session_key: str,
    model: dict[str, Any] | None = None,
    tokens: dict[str, Any] | None = None,
    runtime: dict[str, Any] | None = None,
    sandbox: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Host -> app: the answer to an ``agent_status`` request, and the same
    frame the host pushes after every run of that session.

    Every block is measured, never guessed. A block the host cannot measure is
    **absent**, so the app can tell "nothing to report" from "zero": the panel
    shows a figure only for a block that is here.
    """
    body: dict[str, Any] = {"type": "agent_status", "session_key": session_key}
    if model:
        body["model"] = dict(model)
    if tokens:
        body["tokens"] = dict(tokens)
    if runtime:
        body["runtime"] = dict(runtime)
    if sandbox:
        body["sandbox"] = dict(sandbox)
    return body


def mcp_tools_payload(
    *,
    session_key: str,
    servers: list[dict[str, Any]],
) -> dict[str, Any]:
    """Build an ``mcp_tools`` frame (docs/WIRE_CONTRACT.md, inbound to the app):
    what each forwarded connector actually answered with when the host dialled
    it.

    The app never connects to an MCP server itself — the host does, at task time
    — so without this frame the connector list can only say "0 tools" about a
    server that is working perfectly. One frame carries every server of the
    session, because they are discovered together.

    Each entry is ``{id?, name, connected, tools: [{name, description}], error?}``.
    ``id`` is the device's own connector id, echoed when the device sent one, so
    the app can match without guessing on the name.
    """
    return {
        "type": "mcp_tools",
        "session_key": session_key,
        "servers": list(servers),
    }


def mcp_credentials_payload(
    *,
    session_key: str,
    name: str,
    url: str,
    oauth: dict[str, Any],
    access_token: str | None = None,
    connector_id: str | None = None,
    rotated_at: str | None = None,
) -> dict[str, Any]:
    """Build a ``mcp_credentials`` frame (docs/WIRE_CONTRACT.md, inbound to the
    app): the host refreshed a connector and the provider ROTATED its refresh
    token, so the device's copy is dead. The app overwrites its record's
    refresh_token / expires_at / access_token (only when ``oauth.client_id``
    matches its record) and forwards the new token next time.

    Field names are exactly those of the outgoing ``mcp_servers`` entry, so both
    sides share one projection. ``client_secret`` is never sent back — the device
    is where it came from. ``id`` is echoed verbatim when the device sent one.
    """
    from datetime import UTC, datetime

    clean_oauth = {k: v for k, v in (oauth or {}).items() if k != "client_secret"}
    payload: dict[str, Any] = {
        "type": "mcp_credentials",
        "session_key": session_key,
        "name": name,
        "url": url,
        "oauth": clean_oauth,
        "rotated_at": rotated_at or datetime.now(UTC).isoformat(),
    }
    if connector_id:
        payload["id"] = connector_id
    if access_token:
        payload["access_token"] = access_token
    return payload


def error_payload(message: str) -> dict[str, Any]:
    return {"type": "error", "message": message}


# -- secrets (docs/WIRE_CONTRACT.md, "Secrets") -------------------------------


def secrets_payload(
    entries: dict[str, str] | list[dict[str, str]],
    *,
    revision: int = 0,
    request_id: str | None = None,
) -> dict[str, Any]:
    """App -> host: the user's WHOLE secret set. The host replaces what it
    holds; a name missing here is gone on the host too. ``request_id`` ties
    the frame to the ``secret_request`` it answers (also on cancel, with the
    set unchanged). Built here so a test and a controller send the exact
    shape the app sends."""
    if isinstance(entries, dict):
        listed = [{"name": k, "value": v} for k, v in entries.items()]
    else:
        listed = [dict(e) for e in entries]
    payload: dict[str, Any] = {
        "type": "secrets",
        "entries": listed,
        "revision": int(revision),
    }
    if request_id:
        payload["request_id"] = request_id
    return payload


def secret_request_payload(
    *, request_id: str, session_key: str, names: list[str], purpose: str
) -> dict[str, Any]:
    """Host -> app: the model asked for these secrets by name. The run BLOCKS
    until a ``secrets`` frame with this ``request_id`` arrives, a stop fires,
    or the timeout passes. The app shows one field per name over the thread
    ``session_key`` names."""
    return {
        "type": "secret_request",
        "request_id": request_id,
        "session_key": session_key,
        "names": list(names),
        "purpose": purpose,
    }


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


#: Machine-readable ``browser_view.reason`` codes (bead cowork-qp5i). The app
#: used to read the English ``message`` ("no page open", "no browser open") to
#: decide whether a browser is there; these codes say the same thing without a
#: substring match, and they say WHY when there is nothing to show.
#:
#: On ``started``:
#:   ``""``          the view is live and a page is on the display
#:   ``opening``     live, but empty: the browser is being opened right now and
#:                   the picture grows into this same stream
#:   ``no_browser``  live and empty, and nothing here can open a page
#:   ``reconnected`` the pipe had dropped and is live again. The RFB SESSION is
#:                   new — x11vnc starts its protocol from the version string
#:                   again — so the app must dial a fresh RFB client at the
#:                   loopback socket instead of feeding the old one. The picture
#:                   on screen may stay until the new one paints over it.
#: On ``reconnecting``:
#:   ``reconnecting`` the pipe dropped and the executor is dialling back in.
#:                   Nothing is wrong yet and nothing was torn down; the last
#:                   picture is still the truth about the remote screen, so the
#:                   app should keep showing it rather than go black.
#: On ``error``:
#:   ``no_sandbox``        this executor has no docker sandbox to watch
#:   ``no_display``        no box has a browser display (nothing is running)
#:   ``vnc_start_failed``  x11vnc did not come up
#:   ``exec_failed``       the sandbox could not be reached at all
#:   ``bridge_failed``     the byte pipe to x11vnc could not be opened
BROWSER_VIEW_REASONS = (
    "opening", "no_browser", "no_sandbox", "no_display",
    "vnc_start_failed", "exec_failed", "bridge_failed",
    "reconnecting", "reconnected",
)


def browser_view_payload(
    status: str, *, message: str = "", password: str | None = None,
    vnc_available: bool = False, reason: str = "",
) -> dict[str, Any]:
    """Executor -> app status for the live browser view.

    ``status`` is ``"started"`` (the stream is live, the app may show the view),
    ``"reconnecting"`` (the pipe dropped and the executor is dialling back in —
    nothing is torn down and the last picture still stands), ``"stopped"``
    (torn down — user asked, or the pipe/container went away for good), or
    ``"error"`` (could not bring the view up; ``message`` says why). Two more
    are unsolicited and about the BROWSER, not the stream (Bead cowork-vzm):
    ``"opened"`` — the agent has a browser window now — and ``"closed"``. They
    are sent once per change, so the app can show its button only while there
    is something to look at; see :func:`browser_state_from_tool`.

    ``reason`` is the machine-readable half of ``message``
    (:data:`BROWSER_VIEW_REASONS`): empty when there is nothing to explain, and
    otherwise a stable code, so the app never has to match English text.

    ``password`` rides only on ``"started"``: the per-view VNC secret x11vnc was
    (re)armed with. It travels inside the sealed frame, so only the paired app
    ever sees it; inside the sandbox the secret sits in a root-only file, so the
    agent's own code cannot read the screen or inject input (§9.1 hardening).
    """
    payload: dict[str, Any] = {
        "type": "browser_view", "status": status, "message": message,
        "vnc_available": vnc_available, "reason": reason,
    }
    if password is not None:
        payload["password"] = password
    return payload


# The Playwright MCP server is the agent's browser: Chromium comes up on the
# first ``browser_*`` tool and goes away on ``browser_close``. Its tools reach
# the loop as ``mcp__playwright__browser_<x>`` (``chuk_agents_runtime.mcp_client
# .tool_name``), or wrapped in ``tool_call`` when deferred.
BROWSER_TOOL_PREFIX = "mcp__playwright__"
BROWSER_CLOSE_TOOL = "browser_close"
_TOOL_CALL_WRAPPER = "tool_call"


def _tool_part(name: str) -> str:
    idx = name.rfind("__")
    return name if idx < 0 else name[idx + 2 :]


def browser_state_from_tool(name: Any, arguments: Any, status: Any) -> bool | None:
    """What one finished tool call says about the agent's browser.

    ``True`` = a page is open (any completed Playwright ``browser_*`` tool other
    than ``browser_close``), ``False`` = it is gone (a completed
    ``browser_close``), ``None`` = nothing: not a browser tool, or a call that
    failed and so proves nothing. A ``tool_call`` wrapper is looked through to
    ``arguments["name"]``. Mirrors the app's ``BrowserPresence`` so both sides
    read the same transcript the same way.
    """
    if not isinstance(name, str) or not name:
        return None
    if name == _TOOL_CALL_WRAPPER and isinstance(arguments, dict):
        inner = arguments.get("name")
        if not isinstance(inner, str) or not inner:
            return None
        name = inner
    part = _tool_part(name)
    if not (name.startswith(BROWSER_TOOL_PREFIX) or part.startswith("browser_")):
        return None
    if status != "completed":
        return None
    return part != BROWSER_CLOSE_TOOL


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
    """Wire-encode a sealed Agents frame for the ``frame`` envelope field."""
    return base64.b64encode(sealed_bytes).decode("ascii")


def b64_to_frame(value: str) -> bytes:
    """Recover the sealed Agents frame bytes from an envelope ``frame`` field."""
    return base64.b64decode(value)


# -- persisted approval outcome (docs/WIRE_CONTRACT.md, bead cowork-266) ------

APPROVAL_APPROVED = "approved"
APPROVAL_DENIED = "denied"
APPROVAL_BY_USER = "user"
APPROVAL_TIMEOUT = "timeout"
APPROVAL_STOPPED = "stopped"


def approval_outcome_fields(
    *, approved: bool, reason: str, at: float
) -> dict[str, Any]:
    """The fields the host patches into a stored ``approval_request`` row once
    the outcome is known: ``decision`` (``approved`` / ``denied``),
    ``decision_reason`` (``user`` / ``timeout`` / ``stopped``) and
    ``decided_at`` (epoch seconds). A replayed request that carries them is an
    informational card, never a prompt (docs/WIRE_CONTRACT.md, "Persisted
    subagent / file / approval events")."""
    if reason not in (APPROVAL_BY_USER, APPROVAL_TIMEOUT, APPROVAL_STOPPED):
        raise ValueError(f"unknown approval reason: {reason!r}")
    return {
        "decision": APPROVAL_APPROVED if approved else APPROVAL_DENIED,
        "decision_reason": reason,
        "decided_at": float(at),
    }


# -- browser target: the sandbox, or the browser the user already has open ----

#: Which browser a task drives. ``sandbox`` is the default and the old behaviour.
SANDBOX_BROWSER = "sandbox"
USER_BROWSER = "user_browser"
BROWSER_TARGETS = (SANDBOX_BROWSER, USER_BROWSER)

#: Env var a host sets to point every task at the add-on instead of the sandbox.
BROWSER_TARGET_ENV = "AGENTS_BROWSER_TARGET"

#: Where ``agents-extension-mcp`` lives, overridable for a packaged install.
EXTENSION_MCP_ENV = "AGENTS_EXTENSION_MCP"


def browser_target(value: str | None = None) -> str:
    """``user_browser`` only when asked for it; anything else means the sandbox.

    An unknown value is not an error: a task from a newer app naming a target
    this executor does not have must still run, on the target it does have.
    """
    raw = value if value is not None else os.environ.get(BROWSER_TARGET_ENV)
    return USER_BROWSER if (raw or "").strip() == USER_BROWSER else SANDBOX_BROWSER


def extension_mcp_script() -> Path | None:
    """The add-on's MCP server on this machine, or None when it is not there."""
    override = os.environ.get(EXTENSION_MCP_ENV)
    if override:
        path = Path(override).expanduser()
        return path if path.exists() else None
    # agents/executor/src/chuk_agents_executor/protocol.py -> repository root
    root = Path(__file__).resolve().parents[4]
    path = root / "tools" / "agents-extension-mcp" / "agents_extension_mcp.py"
    return path if path.exists() else None


def extension_mcp_entry() -> dict | None:
    """The MCP server entry for the user's own browser.

    Named ``playwright`` on purpose: the agent builds its tool names as
    ``mcp__<server>__<tool>``, and every other part of Agents matches on
    ``mcp__playwright__browser_*``. The name is the compatibility seam, not a
    claim about what drives the page — behind it is the add-on, over a unix
    socket, with no Playwright anywhere.
    """
    script = extension_mcp_script()
    if script is None:
        return None
    return {"name": "playwright", "command": sys.executable, "args": [str(script)]}
