"""The Executor (task 2).

Composes the agent loop, a real sandbox, and Agents frame crypto into one unit
that:

1. receives an **encrypted** ``run_task`` frame off its transport endpoint,
2. opens it with a :class:`~chuk_agents_crypto.AgentsFrameOpener` (default deny —
   only approved devices get in),
3. runs the agent loop against a real sandbox ``BaseEnvironment``, and
4. streams every delta / tool / done event back as **encrypted** frames sealed
   with a :class:`~chuk_agents_crypto.AgentsFrameSealer`.

Streaming is genuinely incremental and needs no change to ``chuk_agents_runtime``:

- a :class:`StreamingModelClient` wraps the injected model and emits a ``delta``
  the moment a turn produces assistant text;
- the :class:`SandboxEnvironment` shim emits a ``tool`` event the moment a
  command returns.

A :class:`MockModelClient` drives the loop in tests; a real backend client is
injected in production via ``model_factory``.

Stop (§7.1, §16)
----------------
The app's Stop button is a sealed ``stop`` frame, and it is wired all the way
down:

1. **Two threads, not one.** The serve thread only parses frames; tasks run on a
   worker thread. Running a task on the serve thread — as this once did — is why
   a stop could not arrive at all: the frame sat in the transport queue until the
   run it was meant to abort had already finished.
2. **One task at a time.** The worker is a single thread over a queue, so the
   shared sandbox and session db keep exactly the serial behaviour they had.
3. **The run registry** maps the relay ``requestId`` *and* the session key of
   every accepted task to its :class:`~chuk_agents_runtime.KillSwitch`. A stop names one
   of the two and fires that switch; a stop that matches nothing is a no-op and
   says so in its ack.
4. **Cancel in flight.** The switch's listeners kill the command running in the
   sandbox and the model call in flight, so a stop pressed during a ten-minute
   ``run_command`` does not wait ten minutes. The loop then ends with
   ``StopReason.INTERRUPTED`` and the task closes with a normal ``done`` event
   carrying ``reason: "interrupted"`` — the terminal the app already renders.

Because the switch belongs to the task and is handed to ``build_runtime``, the
same interrupt reaches every subagent under it (§7.6) without this module
knowing anything about the tree.

The second way to stop a run — no app, no relay — is the file-sentinel ESTOP:
start the executor with ``estop_path`` and ``touch`` that file. See
:class:`chuk_agents_runtime.KillSwitch`.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import queue
import secrets
import sqlite3
import subprocess
import threading
import time
from collections.abc import Callable
from typing import Any
from contextlib import nullcontext
from dataclasses import dataclass, field
from pathlib import Path
from uuid import uuid4

from chuk_agents_runtime import (
    HereNowConfig,
    KillSwitch,
    StopReason,
    MCPManager,
    browser_servers,
    ModelClient,
    ModelResponse,
    PublishRequest,
    SkillSettingsStore,
    StateStore,
    SubagentConfig,
    SubagentLimits,
    TranscriptExporter,
    WorkspaceMount,
    apply_skill_control,
    build_runtime,
    close_cached_memories,
    configs_from_entries,
    open_browser_gui,
    redact_secrets,
    run_stamp_fields,
    skills_inventory,
)
from chuk_agents_runtime.trace import get_tracer
from chuk_agents_runtime.trace import run_scope as trace_run_scope
from chuk_agents_runtime.mcp_client import auto_open_enabled
from chuk_agents_runtime.runtime import SKILLS_DIRNAME
from chuk_agents_crypto import (
    AgentsFrameOpener,
    AgentsFrameRejected,
    AgentsFrameSealer,
)
from chuk_agents_manager import decode_frames, encode_frame, make_request, make_response
from chuk_agents_sandbox import BaseEnvironment, make_environment

from .environment import SandboxEnvironment
from .secrets import SecretsVault
from .shell import JobWakeRouter
from .protocol import (
    APPROVAL_BY_USER,
    APPROVAL_STOPPED,
    APPROVAL_TIMEOUT,
    INBOUND_METHODS,
    MAX_BROWSER_CHUNK,
    METHOD_EVENT,
    USER_BROWSER,
    approval_outcome_fields,
    approval_request_payload,
    b64_to_frame,
    browser_data_payload,
    browser_state_from_tool,
    browser_target,
    browser_view_payload,
    debug_context_payload,
    decode_payload,
    automation_list_payload,
    agent_list_payload,
    agent_status_payload,
    delta_payload,
    done_payload,
    encode_payload,
    error_payload,
    extension_mcp_entry,
    file_payload,
    frame_to_b64,
    heartbeat_payload,
    mcp_credentials_payload,
    mcp_tools_payload,
    reasoning_payload,
    run_state_payload,
    secret_request_payload,
    skills_list_payload,
    stop_ack_payload,
    subagent_payload,
    tool_payload,
)

logger = logging.getLogger(__name__)

# What a task's model fields read in the log and the runs row when it named
# nothing: the host decides.
HOST_DEFAULT = "host-default"

# A fresh model per task. MockModelClient is single-use (it pops a script), so
# the factory hands back a new one each time; a real client can be reused.
ModelFactory = Callable[[], ModelClient]

# A per-task model builder. Given the ``(model, provider, reasoning_effort)`` a
# task asked for, it returns the ModelClient to run that task on. Wired only in
# production; when it is None, or a task names nothing, the default ModelFactory
# is used instead. So the mock/offline path (no select wired) always runs the
# injected factory and spends no credits, and an old client that sends no model
# keeps working.
ModelSelect = Callable[[str | None, str | None, str | None], ModelClient]

# Fields of a forwarded ``mcp_servers`` entry that ROTATE without the connector
# changing (docs/WIRE_CONTRACT.md, "A rotated token is not a changed connector"):
# the device's live bearer, and inside the ``oauth`` block the refresh token and
# its informational expiry. They are dropped from the cache signature below.
# Everything else — name, url, auth kind, token_endpoint, client_id, client_secret,
# resource, scope, issuer — identifies the connector and stays in the hash.
_ROTATING_TOP_LEVEL = ("access_token",)
_ROTATING_OAUTH = ("refresh_token", "expires_at")


def _mcp_signature(mcp_servers: list[dict]) -> str:
    """The cache key for a session's MCPManager: the forwarded list, minus the
    rotating credential fields, serialized canonically.

    Hashing the raw list meant every task after a token refresh rebuilt the
    manager — transport threads torn down and restarted, tool lists re-fetched —
    although not one connector had changed. Only a real change (a connector
    added, removed, re-pointed, re-authorized with a different client) should
    do that. Non-dict entries pass through untouched; an unserializable list
    falls back to ``repr`` rather than failing the task.
    """
    projected: list = []
    for entry in mcp_servers:
        if not isinstance(entry, dict):
            projected.append(entry)
            continue
        clean = {k: v for k, v in entry.items() if k not in _ROTATING_TOP_LEVEL}
        oauth = clean.get("oauth")
        if isinstance(oauth, dict):
            clean["oauth"] = {k: v for k, v in oauth.items() if k not in _ROTATING_OAUTH}
        projected.append(clean)
    try:
        return json.dumps(projected, sort_keys=True, default=str)
    except (TypeError, ValueError):
        return repr(projected)


def _entry_meta(mcp_servers: list[dict]) -> dict[str, dict]:
    """``name -> {id?, name, url}`` from the forwarded entries: the device's own
    identity for each connector, echoed back verbatim in ``mcp_credentials`` so
    the app can match its record (``id`` is the stable connector id the client
    sends additively; an old client sends none and the app falls back to url+name).
    Python never interprets ``id``."""
    meta: dict[str, dict] = {}
    for entry in mcp_servers:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        if not name:
            continue
        item: dict = {"name": name, "url": str(entry.get("url") or "")}
        if entry.get("id"):
            item["id"] = str(entry["id"])
        meta[name] = item
    return meta


class StreamingModelClient:
    """Wraps a ``ModelClient`` and reports the assistant text as deltas and the
    model's thinking as reasoning deltas.

    If the inner client can stream (it exposes a settable ``on_delta`` /
    ``on_reasoning``, like the backend client), we hand it the callbacks so each
    chunk reaches the UI **as it arrives** — real token-by-token streaming.
    Otherwise (e.g. the mock client) we fall back to emitting the whole turn's
    text (and reasoning) once, so the UI still updates. Tool-only turns carry no
    text and emit nothing either way; a turn's reasoning is emitted regardless,
    since a thinking model reasons about its tool calls too."""

    def __init__(
        self,
        inner: ModelClient,
        *,
        on_delta: Callable[[str], None] | None = None,
        on_reasoning: Callable[[str], None] | None = None,
    ) -> None:
        self._inner = inner
        self._on_delta = on_delta
        self._on_reasoning = on_reasoning
        # Prefer live per-chunk streaming when the inner client supports it.
        self._inner_streams = False
        if on_delta is not None and hasattr(inner, "on_delta"):
            inner.on_delta = on_delta  # type: ignore[attr-defined]
            self._inner_streams = True
        # The thinking channel has its own seam and its own flag: a client that
        # streams content may still only accumulate reasoning (an older backend
        # client), in which case the fallback below emits it once at the end.
        self._inner_streams_reasoning = False
        if on_reasoning is not None and hasattr(inner, "on_reasoning"):
            inner.on_reasoning = on_reasoning  # type: ignore[attr-defined]
            self._inner_streams_reasoning = True

    def set_tools(self, tools: list[dict] | None) -> None:
        """Forward the native tool set to the inner client (§ native tool calls).
        ``build_runtime`` calls this on the model it was handed; the seam mirrors
        ``on_delta`` so the inner backend client gets its ``tools`` array."""
        inner = self._inner
        if hasattr(inner, "set_tools"):
            inner.set_tools(tools)  # type: ignore[attr-defined]

    @property
    def traced_tools(self) -> list[dict] | None:
        """Forward the inner client's wire ``tools`` array, so the run trace can
        price the tool schemas even though the loop only ever sees the wrapper."""
        return getattr(self._inner, "traced_tools", None)

    def complete(self, messages: list[dict]) -> ModelResponse:
        response = self._inner.complete(messages)
        # Fallback only: the inner already streamed each chunk, so emitting the
        # full text again here would duplicate it in the thread. Reasoning goes
        # first — that is the order the model produced it in, and the order the
        # UI shows it (thinking block above the answer).
        if self._on_reasoning is not None and not self._inner_streams_reasoning:
            reasoning = response.raw.get("reasoning") if response.raw else None
            if isinstance(reasoning, str) and reasoning:
                self._on_reasoning(reasoning)
        if (
            self._on_delta is not None
            and not self._inner_streams
            and response.text
        ):
            self._on_delta(response.text)
        return response


@dataclass
class _Run:
    """One accepted task: what a ``stop`` can name, and the switch it fires.

    It is registered when the frame is accepted, not when the worker picks it up,
    so a stop can also name a task that is still queued: the switch is already
    live and the loop's first poll ends the run without one model call.
    """

    request_id: str
    session_key: str
    prompt: str
    kill: KillSwitch
    # The forwarded UI-configured MCP connections for this task (§9, §10), or
    # ``None`` when the frame carried none. Captured at accept time so the worker
    # thread builds the session's MCPManager before the loop starts.
    mcp_servers: list[dict] | None = None
    # The forwarded here.now connector setting ({"enabled", "approval"}) or
    # ``None``. Disabled/absent -> no publish tool is registered for this task.
    herenow: dict | None = None
    # The debug "copy raw context" flag (§ debug tap). True -> the executor wires
    # a debug observer that streams one ``debug_context`` event per model round;
    # absent/false -> no observer and zero overhead.
    debug: bool = False
    # Set by the wall-clock guard (``RUN_MAX_SECONDS``) when it fired this run's
    # kill switch, so the loop's ``interrupted`` is reported as ``timeout``.
    timed_out: bool = False
    # The model this task named, its provider slug, and its reasoning effort, as
    # the app's mode selector sent them. All ``None`` -> the task named nothing
    # and runs on the executor's default ``model_factory``. Captured at accept
    # time, like everything else the frame carried.
    model: str | None = None
    provider: str | None = None
    reasoning_effort: str | None = None
    # "Replace the last answer", not "ask again": the app's Retry button sends
    # the same prompt a second time, and without this the stored conversation
    # keeps every attempt (docs/WIRE_CONTRACT.md, ``task``). Absent/false ->
    # today's behavior, so an older client is unaffected.
    regenerate: bool = False
    # docs/WIRE_CONTRACT.md: the host-side id of this run and when it was
    # accepted. The relay request id is per socket, so it cannot name a run
    # across a reconnect; this id can.
    run_id: str = ""
    started_at: float = 0.0
    # Who started this run (docs/WIRE_CONTRACT.md, "Automations"): ``app`` for
    # a task frame, ``automation`` for a fired schedule / watcher trigger. An
    # automation run is notified on even with a controller attached.
    origin: str = "app"
    automation_id: str | None = None


class _Heartbeat:
    """The repeating ``heartbeat`` emitter of one run (``protocol.py``).

    A thread, not a chain of timers: it wakes on its own switch, so stopping it
    is one ``set()`` and the run never waits on a pending timer. ``cancel``
    joins briefly, which is what keeps a beat from landing *after* the run's
    terminal — a frame for a request the app has already closed.
    """

    def __init__(self, thread: threading.Thread, stop: threading.Event) -> None:
        self._thread = thread
        self._stop = stop

    def cancel(self, *, join_timeout: float = 2.0) -> None:
        self._stop.set()
        self._thread.join(join_timeout)


#: How long a here.now publish waits for the user before it gives up and denies.
#: Long enough to walk to the phone and read the prompt; bounded so a run cannot
#: hang forever on an approval nobody will ever answer.
APPROVAL_WAIT_SECONDS = 600.0

#: Wall-clock guard for a run (Bead cowork-qxa): a run that keeps going after
#: the app detached has no other upper bound on the host. After this many
#: seconds the executor fires the run's kill switch; the loop stops at its next
#: poll and the run closes with ``reason == "timeout"`` (persisted, notified,
#: rendered by the app like a stop). Generous by default; ``0`` disables it.
RUN_MAX_SECONDS = float(os.environ.get("AGENTS_RUN_MAX_SECONDS", "7200") or 0)
#: The ``done.reason`` of a run the guard stopped (docs/WIRE_CONTRACT.md, ``done``).
RUN_TIMEOUT_REASON = "timeout"

#: How often a running task says "still here" (the ``heartbeat`` frame, see
#: ``protocol.py``). Nothing else on the stream proves a silent run is alive: a
#: model reading a 290k-token prompt sends no token until the prefill is done,
#: and a shell command sends none while it runs. Ten seconds is short enough
#: that a client can keep a tight idle window and still never mistake a working
#: run for a dead one, and cheap enough to be free (one small sealed frame).
#: ``0`` (``AGENTS_HEARTBEAT_SECONDS=0``) disables the emitter entirely.
HEARTBEAT_SECONDS = float(os.environ.get("AGENTS_HEARTBEAT_SECONDS", "10") or 0)


#: How long ``request_secrets`` waits for the user before it reports every
#: open name as missing. Same window as an approval: walk to the phone, read
#: the dialog, paste a key.
SECRET_REQUEST_TIMEOUT = 600.0


@dataclass
class _PendingSecretRequest:
    """One in-flight ``secret_request`` (docs/WIRE_CONTRACT.md, "Secrets"):
    the worker waits on ``event``, the serve thread sets it when a ``secrets``
    frame answers (by ``request_id``, or by carrying every name asked for).
    Kept in memory only — never a row — and re-sent on a replay of its
    session while the run still waits."""

    request_id: str
    session_key: str
    names: list[str]
    purpose: str
    #: The relay request id of the task whose stream carries the frame.
    stream_request_id: str
    event: threading.Event = field(default_factory=threading.Event)


@dataclass
class _PendingApproval:
    """One in-flight publish approval: the worker waits on ``event``, the serve
    thread writes ``approved`` and sets it. Default is deny, so a lost decision
    or a torn-down wait resolves to "do not publish"."""

    event: threading.Event = field(default_factory=threading.Event)
    approved: bool = False
    #: The persisted ``approval_request`` row (docs/WIRE_CONTRACT.md,
    #: cowork-266), patched with the outcome once; None when nothing was stored.
    mid: int | None = None
    closed: bool = False


class _RfbClientFramer:
    """Frames the app's client->server RFB bytes and lets only protocol through.

    The view is a sealed tunnel, but "only VNC bytes" should be a property the
    executor ENFORCES, not one it trusts the client for. Client->server RFB is
    easy to frame without decoding pixels: after the fixed handshake every
    message starts with a type byte and has a fixed or self-describing length.
    Allowed: SetPixelFormat(0), SetEncodings(2), FramebufferUpdateRequest(3),
    KeyEvent(4), PointerEvent(5). ClientCutText(6) — the one message that
    carries arbitrary host data (a clipboard) — is DROPPED. Anything else is a
    protocol violation and the framer fails closed: ``feed`` returns None and
    the owner tears the view down.

    Handshake (RFB 3.8 as our client speaks it): 12-byte ProtocolVersion, then
    a 1-byte security type — 2 (VNC auth) is followed by a 16-byte challenge
    response, 1 (None) by nothing — then a 1-byte ClientInit. Bytes may arrive
    split across sealed chunks, so the framer buffers partial messages.

    Server->client is left opaque on purpose: framing it would need the full
    Tight/raw rectangle decoder, and the client already discards ServerCutText.
    """

    _ALLOWED_FIXED = {0: 20, 3: 10, 4: 8, 5: 6}
    _SET_ENCODINGS = 2
    _CLIENT_CUT_TEXT = 6
    _MAX_BUFFER = 1024 * 1024  # a stuck partial message must not grow forever

    def __init__(self) -> None:
        self._buf = bytearray()
        self._phase = "version"
        self.dropped_cut_text = 0
        # RFB 3.3 has no client security-type selection byte (the server
        # dictates); 3.7/3.8 do. Learned from the client's version string.
        self._client_selects_security = True

    def feed(self, data: bytes) -> bytes | None:
        """Return the bytes safe to forward, or None on a protocol violation."""
        self._buf.extend(data)
        if len(self._buf) > self._MAX_BUFFER:
            return None
        out = bytearray()
        while True:
            consumed, forward = self._next()
            if consumed is None:
                return None
            if consumed == 0:
                break
            if forward:
                out.extend(self._buf[:consumed])
            del self._buf[:consumed]
        return bytes(out)

    def _next(self) -> tuple[int | None, bool]:
        """(bytes consumed, forward?) for the next complete unit; (0, _) if
        incomplete; (None, _) on violation."""
        buf = self._buf
        if self._phase == "version":
            if len(buf) < 12:
                return 0, False
            if not buf.startswith(b"RFB ") or buf[11:12] != b"\n":
                return None, False
            try:
                major = int(buf[4:7])
                minor = int(buf[8:11])
            except ValueError:
                return None, False
            # RFB 3.3 is not framable from the client side alone: the server
            # picks the security type silently, so we cannot know whether a
            # 16-byte VNC-auth response follows. Our client speaks 3.8; refuse
            # 3.3 outright (fail closed) rather than guess and desync.
            if (major, minor) < (3, 7):
                return None, False
            self._client_selects_security = True
            self._phase = "security"
            return 12, True
        if self._phase == "security":
            if len(buf) < 1:
                return 0, False
            sec = buf[0]
            if sec == 2:  # VNC auth: 16-byte DES response follows
                self._phase = "auth"
            elif sec == 1:
                self._phase = "clientinit"
            else:
                return None, False
            return 1, True
        if self._phase == "auth":
            if len(buf) < 16:
                return 0, False
            self._phase = "clientinit"
            return 16, True
        if self._phase == "clientinit":
            if len(buf) < 1:
                return 0, False
            self._phase = "messages"
            return 1, True
        # messages
        if len(buf) < 1:
            return 0, False
        mtype = buf[0]
        if mtype in self._ALLOWED_FIXED:
            n = self._ALLOWED_FIXED[mtype]
            return (n, True) if len(buf) >= n else (0, False)
        if mtype == self._SET_ENCODINGS:
            if len(buf) < 4:
                return 0, False
            n = 4 + 4 * int.from_bytes(buf[2:4], "big")
            return (n, True) if len(buf) >= n else (0, False)
        if mtype == self._CLIENT_CUT_TEXT:
            if len(buf) < 8:
                return 0, False
            n = 8 + int.from_bytes(buf[4:8], "big")
            if len(buf) < n:
                return 0, False
            self.dropped_cut_text += 1
            return n, False  # consumed, NOT forwarded
        return None, False  # unknown client message: fail closed


class _VncBridge:
    """A live byte pipe between the app and x11vnc inside the agent's container.

    One `docker exec -i <container> socat STDIO TCP:127.0.0.1:<port>` process
    reaches x11vnc's localhost RFB port (§9.1). A reader thread pumps its stdout
    out to the app as `browser_data` frames; `feed` writes the app's RFB-client
    bytes to its stdin. Nothing here parses RFB — the pipe is opaque both ways;
    the Flutter side speaks the protocol.

    Self-closing: when socat exits (the user closed the view, or x11vnc / the
    container went away) the reader drains, calls `on_closed`, and stops. The
    executor kills it on stop, on ESTOP, and on an explicit `browser_stop`.
    """

    def __init__(
        self,
        argv: list[str],
        *,
        emit: Callable[[bytes], None],
        on_closed: Callable[[], None],
        chunk_size: int = 64 * 1024,
        autostart: bool = True,
    ) -> None:
        self._emit = emit
        self._on_closed = on_closed
        self._chunk = chunk_size
        self._closed = threading.Event()
        self._write_lock = threading.Lock()
        #: True once x11vnc has said ANYTHING down this pipe. It is the line
        #: between "the view was live and the link dropped" — worth dialling
        #: back in — and "socat never reached x11vnc", where a retry is just a
        #: slower way to report the same failure (bead cowork-c0zd).
        self.saw_bytes = False
        self._proc = subprocess.Popen(  # noqa: S603 — argv is built by us, not user input
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self._reader = threading.Thread(target=self._pump, name="vnc-pump", daemon=True)
        # ``autostart=False`` lets the owner register the bridge BEFORE the pump
        # can fire ``on_closed`` — otherwise a socat that dies instantly reports
        # its close to an owner that has not stored the bridge yet, the teardown
        # finds nothing, and a dead bridge is then registered as live.
        if autostart:
            self.start()

    def start(self) -> None:
        """Start the reader thread. Idempotent."""
        if not self._reader.is_alive() and not self._closed.is_set():
            try:
                self._reader.start()
            except RuntimeError:
                pass  # already started

    def _pump(self) -> None:
        out = self._proc.stdout
        # `read1` returns as soon as ANY bytes are available (up to chunk), so a
        # framebuffer update is forwarded at once — a plain `read(n)` on a pipe
        # blocks until n bytes or EOF, which would stall the whole stream.
        read = getattr(out, "read1", None) if out is not None else None
        try:
            while not self._closed.is_set():
                chunk = read(self._chunk) if read is not None else b""
                if not chunk:
                    break  # socat closed: x11vnc/container gone or view ended
                self.saw_bytes = True
                try:
                    self._emit(chunk)
                except Exception:  # noqa: BLE001 — a send failure must not wedge the pump
                    break
        finally:
            if not self._closed.is_set():
                # The pipe died on its own (not an explicit close): tell the owner
                # so it can drop the registry entry and notify the app.
                self._closed.set()
                try:
                    self._on_closed()
                except Exception:  # noqa: BLE001
                    pass

    def feed(self, data: bytes) -> None:
        """Write the app's RFB-client bytes into the pipe. Silent if it is gone."""
        if self._closed.is_set():
            return
        stdin = self._proc.stdin
        if stdin is None:
            return
        try:
            with self._write_lock:
                stdin.write(data)
                stdin.flush()
        except (BrokenPipeError, ValueError, OSError):
            # The far end closed mid-write; the reader will report the close.
            pass

    def close(self) -> None:
        """Tear the pipe down. Idempotent."""
        self._closed.set()
        proc = self._proc
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except (subprocess.TimeoutExpired, OSError, ValueError):
            try:
                proc.kill()
            except OSError:
                pass


class _Stopwatch:
    """Milliseconds per step of one code path, for a single log line.

    Small on purpose: "where do the seconds go" is a question that has to be
    answerable on the user's own machine, from the executor log, without a
    profiler and without a rebuild.
    """

    def __init__(self) -> None:
        self._t0 = time.monotonic()
        self._last = self._t0
        self._marks: list[tuple[str, float]] = []

    def mark(self, label: str) -> None:
        now = time.monotonic()
        self._marks.append((label, (now - self._last) * 1000.0))
        self._last = now

    def report(self) -> str:
        parts = [f"{label} {ms:.0f}ms" for label, ms in self._marks]
        parts.append(f"total {(self._last - self._t0) * 1000.0:.0f}ms")
        return ", ".join(parts)


def _script_window_count(stdout: bytes | None) -> int | None:
    """The ``WINDOWS=<n>`` line ``agents-vnc-up`` prints, or ``None``.

    The fallback for a box the executor cannot count on itself. ``-1`` is the
    script's own "could not tell" and is passed through as the number it is, so
    the caller can keep treating a negative count as unknown.
    """
    try:
        for line in (stdout or b"").decode("utf-8", "replace").splitlines():
            if line.startswith("WINDOWS="):
                return int(line[len("WINDOWS=") :].strip())
    except (AttributeError, ValueError):
        return None
    return None


class Executor:
    """One executor bound to one transport endpoint and one sandbox.

    The sandbox environment and db file persist for the executor's life, so
    successive tasks resume the same session and share the same workspace. Each
    task builds a fresh loop (fresh model + registry) over that shared state.
    """

    def __init__(
        self,
        *,
        name: str,
        endpoint,  # LoopbackEndpoint (send + recv)
        opener: AgentsFrameOpener,
        sealer: AgentsFrameSealer,
        environment: BaseEnvironment,
        environment_factory: Callable[[str], BaseEnvironment] | None = None,
        db_path: str,
        model_factory: ModelFactory,
        model_select: ModelSelect | None = None,
        system_prompt: str | None = None,
        workspace: str | None = None,
        media_mount: WorkspaceMount | None = None,
        max_iterations: int = 50,
        poll_interval: float = 0.1,
        estop_path: str | None = None,
        subagent_sandbox: str | None = None,
        subagent_sandbox_options: dict | None = None,
        subagent_limits: SubagentLimits | None = None,
        on_room_frame: Callable[[dict], None] | None = None,
        account_token_provider: Callable[[], str | None] | None = None,
        account_session_provider: Callable[[], Any] | None = None,
        browser_mcp: bool = False,
        on_run_finished: Callable[[dict], None] | None = None,
        on_approval_pending: Callable[[dict], None] | None = None,
        on_account_frame: Callable[[dict], None] | None = None,
        on_run_ack: Callable[[dict], None] | None = None,
        run_max_seconds: float | None = None,
        heartbeat_seconds: float | None = None,
        secrets: SecretsVault | None = None,
        on_secret_request_pending: Callable[[dict], None] | None = None,
        automations=None,
        on_automation_frame: Callable[[dict], dict | None] | None = None,
        job_frame_sender: Callable[[dict], Any] | None = None,
        skills_seed_root: str | None = None,
        on_agent_frame: Callable[[dict], list | None] | None = None,
    ) -> None:
        self._name = name
        self._endpoint = endpoint
        self._opener = opener
        self._sealer = sealer
        self._environment = environment
        self._env_shim = SandboxEnvironment(environment)
        # One sandbox per agent (§6, bead cowork-jo2). A ``session_key`` IS an
        # agent id on the app side, so every session that is not this executor's
        # own agent gets its OWN environment from the factory — its own
        # container and its own workspace. Without the factory (tests, the
        # single-agent path) every session shares ``environment``, which is the
        # old behaviour.
        self._environment_factory = environment_factory
        self._session_envs: dict[str, BaseEnvironment] = {}
        self._session_shims: dict[str, SandboxEnvironment] = {}
        # What each session's last run really ran on (docs/WIRE_CONTRACT.md,
        # "Agent status"). Recorded from the client the executor built, so a
        # status frame never has to build one of its own to have an answer.
        self._model_identities: dict[str, dict[str, Any]] = {}
        # Re-entrant: ``_shim_for`` holds it while it asks ``_environment_for``
        # for the same session's box.
        self._env_lock = threading.RLock()
        self._db_path = db_path
        self._model_factory = model_factory
        # Per-task model selection (§ model picker). ``None`` in the offline/mock
        # path, so a task that names a model there still runs on the injected
        # factory and never builds a backend client — no credits are spent.
        self._model_select = model_select
        self._system_prompt = system_prompt
        self._workspace = workspace
        # The host directory the sandbox workspace really is, for the host-side
        # ffmpeg passthrough (§9). Left unset, the media tools are not registered
        # and cost nothing in the prompt.
        self._media_mount = media_mount
        self._max_iterations = max_iterations
        self._poll = poll_interval
        # The file-sentinel half of the kill switch (§7.1). Every task's switch is
        # built with it, so one ``touch`` stops the run and its whole subagent
        # tree with no app and no network involved.
        self._estop_path = estop_path
        # Subagents (§7.6) are opt-in per executor, because a child is a second
        # sandbox and a second model stream — a cost the operator says yes to.
        # ``subagent_sandbox`` is the *kind* ("local" / "docker"), and each child
        # is built through the sandbox factory with its own task id, so with
        # docker one subagent is one container (§6).
        self._subagent_sandbox = subagent_sandbox
        self._subagent_sandbox_options = dict(subagent_sandbox_options or {})
        self._subagent_limits = subagent_limits
        # Group-room frames (§16.1) are not this agent's own work: they carry no
        # prompt for the loop, and their responses are the host's to stream (the
        # room drives several agents, not just this one). So the executor opens
        # and validates them like any frame — default deny still applies — then
        # hands the decoded payload up to the host, which routes it to the
        # RoomService. None means rooms are not enabled on this host.
        self._on_room_frame = on_room_frame
        # The account bearer for ``appSession`` MCP connectors (§10). A callable,
        # not a fixed string, so a token refreshed on the SupabaseSession carries
        # to the next task. ``None`` -> appSession connectors get no bearer and
        # simply fail to authenticate (never a crash). ``oauth`` connectors do
        # not need this: their device token is forwarded in the frame.
        self._account_token_provider = account_token_provider
        self._account_session_provider = account_session_provider
        # Give every task the Playwright MCP (§9.1) when the sandbox is the
        # browser image: the agent drives a headed Chromium the user can watch
        # over VNC. Off on the browser-free base image, where the launcher script
        # does not exist. The server runs INSIDE the container (the runtime is
        # host-side), reached over `docker exec` stdio — see `_browser_mcp_entry`.
        self._browser_mcp = browser_mcp
        # Run-ownership hooks (docs/WIRE_CONTRACT.md). A run belongs to this
        # process, not to a socket. The host uses these to notify the user when
        # a run ends with no app attached, to react to a pending approval, to
        # re-provision tokens when a second account frame arrives mid-session,
        # and to learn that the app saw a live ``done``. All optional; a raising
        # hook is swallowed so a notifier can never take a run down.
        self._on_run_finished = on_run_finished
        self._on_approval_pending = on_approval_pending
        self._on_account_frame = on_account_frame
        self._on_run_ack = on_run_ack
        # The wall-clock guard (Bead cowork-qxa); ``None`` = the module default.
        self._run_max_seconds = RUN_MAX_SECONDS if run_max_seconds is None else float(run_max_seconds)
        # The run heartbeat (``protocol.heartbeat_payload``); ``None`` = the
        # module default, ``0`` = off.
        self._heartbeat_seconds = (
            HEARTBEAT_SECONDS if heartbeat_seconds is None else float(heartbeat_seconds)
        )
        # The user's secret set (docs/WIRE_CONTRACT.md, "Secrets"), owned by
        # the host and shared by every task: ``run_command`` / ``python`` get
        # the values as child environment, the model gets ``set`` / ``missing``,
        # and the vault's scrubber masks every value in every frame sealed
        # below (``_seal_b64``). ``None`` -> no secrets tools, no masking.
        self._secrets = secrets
        self._secret_scrubber = secrets.scrubber() if secrets is not None else None
        # In-flight ``secret_request``s, by their own request id. The worker
        # (inside the tool) registers one and blocks; the serve thread resolves
        # it when the app's ``secrets`` frame lands.
        self._secret_requests: dict[str, _PendingSecretRequest] = {}
        self._secret_requests_lock = threading.Lock()
        # Like ``on_approval_pending``: a run is blocked on the user and no app
        # may be attached to show the dialog.
        self._on_secret_request_pending = on_secret_request_pending
        # Automations (docs/WIRE_CONTRACT.md, "Automations"): the host's manager
        # (``bound(session_key)`` gives a task its session-scoped tools) and the
        # hook that answers the app's ``automation_control`` / ``automation_list``
        # frames. ``None`` -> no automation tools, those frames are unknown.
        self._automations = automations
        self._on_automation_frame = on_automation_frame
        # Coworker names (docs/WIRE_CONTRACT.md, "Coworker names"): the host
        # keeps the names the user chose in the app. The hook takes an
        # ``agent_create`` / ``agent_rename`` / ``agent_list`` payload and
        # returns the current list (each answered with one ``agent_list``).
        # ``None`` -> those frames are unknown.
        self._on_agent_frame = on_agent_frame
        # Skills (docs/WIRE_CONTRACT.md, "Skills"): the app lists and switches
        # the workspace's skills through ``skills_list`` / ``skill_control``.
        # The executor answers both itself from ``<workspace>/skills`` and the
        # ``skill_settings`` table of its own state database (the one
        # ``build_runtime`` reads); ``skills_seed_root`` (the repository's
        # shipped ``skills/``) only decides which rows are "builtin".
        self._skills_seed_root = skills_seed_root
        # Background jobs (docs/WIRE_CONTRACT.md, "Interactive shell and
        # background commands"): the host's trigger tail hands a finished
        # job to ``job_finished``; the router wakes the model — into the
        # running turn, or as a new task of the session. ``job_frame_sender``
        # streams the ``job`` frame when no run of the session is live (the
        # host's own sender to an attached app); ``None`` -> persisted only.
        self._jobs = JobWakeRouter(self, workspace=workspace, send_host=job_frame_sender)
        # The frame codec is per app session: a reconnecting app mints a fresh
        # sealer (its seq guard restarts), so the host hands us a fresh opener /
        # sealer pair through ``rebind_codec`` while the run registry, the
        # sandbox and the MCP managers stay untouched. Guarded because the serve
        # thread reads it while the party thread swaps it.
        self._codec_lock = threading.RLock()
        # Replay and a live run's stream are mutually exclusive (see
        # ``_handle_replay``). Re-entrant: a replay emits through ``_event``.
        self._emit_lock = threading.RLock()
        # MCP managers live per session (§9): one manager owns the transport
        # threads for a session's forwarded servers, is reused across that
        # session's tasks, and is closed on executor stop. Guarded because the
        # worker builds it while ``stop`` closes it.
        self._mcp_managers: dict[str, MCPManager] = {}
        self._mcp_signatures: dict[str, str] = {}
        # Per session, per connector: the refresh token the connector was
        # STARTED with (the device's forward at build time). It is the reference
        # that tells a device re-sign-in (new token ≠ baseline → adopt) apart
        # from a stale device payload after the host rotated the token itself
        # (device token == baseline while the host holds a newer one → keep).
        self._mcp_refresh_baseline: dict[str, dict[str, str | None]] = {}
        # Per session, per connector: EVERY refresh token the device has ever
        # forwarded. A token the device sends that was never seen is a genuine
        # re-sign-in; a token that was seen before is a replay of an old payload
        # and must not roll a newer grant back.
        self._mcp_refresh_seen: dict[str, dict[str, set[str]]] = {}
        # Per session, per connector: the identity the device forwarded (its
        # stable ``id`` plus name/url), echoed back verbatim in the
        # ``mcp_credentials`` back-channel so the app can match its record.
        self._mcp_entry_meta: dict[str, dict[str, dict]] = {}
        # Per session, per connector: a ``mcp_credentials`` frame the app has not
        # acknowledged yet (ack = the device forwards the rotated token back).
        # Re-sent at every task start and replay until then — there is no durable
        # outbox, and a frame sent while the controller was detached is dropped.
        self._mcp_pending_credentials: dict[str, dict[str, dict]] = {}
        # Per session: the request id of the task currently running, so a rotation
        # that happens mid-task can ride the live event stream immediately.
        self._mcp_active_request: dict[str, str] = {}
        self._mcp_lock = threading.Lock()

        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._worker: threading.Thread | None = None
        self._rx = b""

        # Accepted-but-not-finished tasks, by relay request id. Guarded because
        # the serve thread writes it (accept, stop) while the worker clears it.
        self._runs: dict[str, _Run] = {}
        self._runs_lock = threading.Lock()
        self._queue: "queue.Queue[_Run]" = queue.Queue()

        # In-flight here.now publish approvals, by approval id. The worker thread
        # (inside the publish tool) registers one and blocks on its event; the
        # serve thread resolves it when the app's ``approval_decision`` lands.
        # Guarded because the two threads touch it.
        self._approvals: dict[str, _PendingApproval] = {}
        self._approvals_lock = threading.Lock()

        # The live browser view (§9.1), at most one per executor (one agent, one
        # sandbox Chromium). Set on `browser_start`, fed by `browser_data`, torn
        # down on `browser_stop`, on the pipe dying, and on executor stop. Guarded
        # because it is touched from the serve thread and the pump's close hook.
        self._vnc: _VncBridge | None = None
        self._vnc_stream_id: str = ""
        self._vnc_framer: _RfbClientFramer | None = None
        # Bumped by every browser_start / browser_stop / executor stop. A start
        # runs OFF the serve thread (agents-vnc-up can take seconds and must not
        # stall `stop` and every other frame behind it); when it finally has a
        # bridge it only registers it if no newer start/stop happened meanwhile.
        self._vnc_generation = 0
        self._vnc_lock = threading.Lock()
        #: What a dropped pipe needs to dial back in: ``(prefix, container,
        #: request_id, session_key)`` of the live view, or None when no view is
        #: meant to be running. A mobile link drops; the view must come back by
        #: itself instead of staying dead until the user closes the page
        #: (bead cowork-c0zd). Written under ``_vnc_lock`` next to ``_vnc``.
        self._vnc_route: tuple[list[str], str, str, str | None] | None = None
        # Whether the agent has a browser window right now (Bead cowork-vzm):
        # derived from its Playwright tool calls and from what agents-vnc-up
        # counts on the display. Pushed to the app as `browser_view`
        # opened/closed on every change and carried in every `run_state`, so the
        # app shows its browser button only while there is something to see.
        self._browser_open = False
        #: ``{container: (checked_at, present)}`` of the last window probes.
        #: Per box, because one executor can watch several sandboxes and a
        #: single slot would answer for the wrong one.
        self._browser_window_probe: dict[str, tuple[float, bool]] = {}

    @property
    def name(self) -> str:
        return self._name

    # -- lifecycle -------------------------------------------------------
    def start(self) -> None:
        """Spawn the serve loop and the task worker as background daemon threads."""
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._start_worker()
        self._thread = threading.Thread(
            target=self._serve, name=f"executor-{self._name}", daemon=True
        )
        self._thread.start()
        # Jobs that ended while no executor was up (a host restart) are woken
        # now, as new tasks of their sessions. Guarded: a sweep must never keep
        # the executor from starting.
        try:
            swept = self._jobs.sweep()
            if swept:
                logger.info("woke %d background job(s) that ended while the host was down", swept)
        except Exception as exc:  # noqa: BLE001
            logger.info("job sweep failed: %s", type(exc).__name__)

    def stop(self, *, join_timeout: float = 5.0) -> None:
        """Signal both loops, join them, and release the sandbox.

        Interrupts every live run first: a task in flight would otherwise hold the
        worker for as long as the model and its commands want, and the join would
        expire while a run kept writing to a channel nobody reads.
        """
        self._stop.set()
        # A live browser view holds a `docker exec` pipe; drop it before the
        # container is released so no socat outlives the executor. Bump the
        # generation too, so a browser_start still bringing x11vnc up on its
        # own thread never registers a bridge into a stopped executor.
        with self._vnc_lock:
            self._vnc_generation += 1
        self._vnc_teardown(reason="stopped", notify=False)
        # The sandbox goes with us; the next replay's run_state says so.
        self._browser_open = False
        for run in self._live_runs():
            run.kill.interrupt()
        serve, worker = self._thread, self._worker
        self._thread = self._worker = None
        for thread in (serve, worker):
            if thread is not None:
                thread.join(join_timeout)
        # Anything still registered never ran: say so instead of leaving the
        # controller waiting for a terminal that will never come.
        for run in self._live_runs():
            self._forget(run.request_id)
            self._terminal(
                run.request_id, error_payload("executor stopped before the task ran")
            )
        # Per-session MCP managers own transport threads (and stdio subprocesses);
        # close them so nothing outlives the executor.
        self._close_mcp_managers()
        # Drain idle model sockets retained across tasks. Active leases are
        # closed, rather than recached, when their interrupted tasks unwind.
        for factory in (self._model_factory, self._model_select):
            close = getattr(factory, "close", None)
            if callable(close):
                try:
                    close()
                except Exception:  # noqa: BLE001 — teardown must not mask stop
                    pass
        # The per-workspace mem0 handles are cached for the life of the process
        # (memory.py) so a second task can reopen the same embedded Qdrant. Close
        # and forget them here, or the storage lock outlives the executor that
        # owned the workspace and the next start hits "already accessed".
        try:
            close_cached_memories()
        except Exception:  # noqa: BLE001 — teardown must not mask the stop
            pass
        for env in self._session_environments():
            try:
                env.cleanup()
            except Exception:  # noqa: BLE001 — one bad box must not block the rest
                pass

    def serve_forever(self) -> None:
        """Run the serve loop on the calling thread (for a subprocess entry
        point). Prefer :meth:`start` for in-process use."""
        self._stop.clear()
        self._start_worker()
        self._serve()

    def _start_worker(self) -> None:
        if self._worker is not None and self._worker.is_alive():
            return
        self._worker = threading.Thread(
            target=self._work, name=f"executor-{self._name}-task", daemon=True
        )
        self._worker.start()

    def rebind_codec(
        self, opener: AgentsFrameOpener, sealer: AgentsFrameSealer
    ) -> None:
        """Swap the frame codec for a new app session (docs/WIRE_CONTRACT.md).

        The app mints a fresh sealer per socket, so after a reconnect the old
        opener would reject every frame on its seq guard. Only the codec
        changes: queued and running tasks, the sandbox and the per-session MCP
        managers all stay as they are — that is what lets a run outlive the
        socket it was started from.
        """
        with self._codec_lock:
            self._opener = opener
            self._sealer = sealer

    # -- serve loop ------------------------------------------------------
    def _serve(self) -> None:
        while not self._stop.is_set():
            data = self._endpoint.recv(timeout=self._poll)
            if data is None:
                continue
            self._rx += data
            frames, self._rx = decode_frames(self._rx)
            for frame in frames:
                if (
                    frame.get("type") == "request"
                    and frame.get("method") in INBOUND_METHODS
                ):
                    self._handle_frame(frame)

    def _work(self) -> None:
        """Run accepted tasks, one at a time, off the queue.

        Serial on purpose: one executor owns one sandbox and one session db, so
        two tasks at once would interleave in both.
        """
        while not self._stop.is_set():
            try:
                run = self._queue.get(timeout=self._poll)
            except queue.Empty:
                continue
            try:
                self._run_task(run)
            except Exception as exc:  # noqa: BLE001 — one bad task must not kill the worker
                # ``_run_task`` builds the model (a per-task ``ModelSelect`` can
                # raise on an unknown model id) and the runtime BEFORE its own
                # try/finally. Left uncaught, that exception would end this
                # worker thread for the rest of the executor's life: no terminal
                # frame for the app, and every later task queued forever. So the
                # failure becomes an ``error`` terminal and the worker lives on.
                message = f"task failed: {type(exc).__name__}: {exc}"
                # The run never reached _run_task's finally, so unbind the shim
                # hook it had already pointed at this request (hygiene: the next
                # task rebinds it anyway, but a stale binding is a stale binding).
                try:
                    self._shim_for(run.session_key).on_run = None
                except Exception:  # noqa: BLE001 — never mask the real failure
                    pass
                # The durable record closes first (docs/WIRE_CONTRACT.md): an
                # app that reconnects later must see this run as failed too.
                self._record_run(run, failed=message)
                self._terminal(run.request_id, error_payload(message))
                self._call_hook(
                    self._on_run_finished,
                    self._run_summary(
                        run, reason="failed", final_answer=None, error=message
                    ),
                )
            finally:
                self._forget(run.request_id)
                # A job wake queued for this run that its turn never consumed
                # becomes a new task of the session (docs/WIRE_CONTRACT.md,
                # "The wake-up", 5). Guarded like every hook.
                try:
                    self._jobs.flush_after_run(run.session_key)
                except Exception as exc:  # noqa: BLE001
                    logger.info("job flush failed: %s", type(exc).__name__)

    # -- one sandbox per agent (§6, bead cowork-jo2) ----------------------
    def _is_primary_session(self, session_key: str | None) -> bool:
        """True when the session runs in this executor's own environment.

        ``None`` and the empty key are the executor's own box; so is every key
        when no factory was wired (the single-agent path and the tests).
        """
        return self._environment_factory is None or not session_key

    def _environment_for(self, session_key: str | None) -> BaseEnvironment:
        """The sandbox of ``session_key`` — one per agent, created on demand.

        The factory decides what "its own" means: the docker backend hands back
        a container labelled with that agent id, the local backend a directory
        of its own. Cached, because the box must be the SAME one across the
        agent's turns — that is the whole point of a per-agent sandbox.
        """
        if self._is_primary_session(session_key):
            return self._environment
        key = str(session_key)
        with self._env_lock:
            env = self._session_envs.get(key)
            if env is None:
                env = self._environment_factory(key)  # type: ignore[misc]
                self._session_envs[key] = env
            return env

    def _shim_for(self, session_key: str | None) -> SandboxEnvironment:
        """The agent-runtime adapter around :meth:`_environment_for`."""
        if self._is_primary_session(session_key):
            return self._env_shim
        key = str(session_key)
        with self._env_lock:
            shim = self._session_shims.get(key)
            if shim is None:
                shim = SandboxEnvironment(self._environment_for(key))
                self._session_shims[key] = shim
            return shim

    def _workspace_for(self, session_key: str | None) -> str | None:
        """The host directory of that agent's sandbox.

        A per-agent container bind-mounts a per-agent workspace, so the runtime
        must be told about that directory and not about the executor's own.
        """
        if self._is_primary_session(session_key):
            return self._workspace
        env = self._environment_for(session_key)
        return getattr(env, "workspace", None) or self._workspace

    def _session_environments(self) -> list[BaseEnvironment]:
        """Every sandbox this executor owns: its own plus one per served agent."""
        with self._env_lock:
            envs = list(self._session_envs.values())
        return [self._environment, *envs]

    # -- inbound frames --------------------------------------------------
    def _handle_frame(self, frame: dict) -> None:
        """Open one sealed controller frame and dispatch on its payload type."""
        request_id = frame.get("requestId", "")
        params = frame.get("params", {}) or {}
        raw_b64 = params.get("frame", "")

        try:
            sealed = b64_to_frame(raw_b64)
        except (ValueError, TypeError):
            self._terminal(request_id, error_payload("malformed envelope frame"))
            return

        # Open the encrypted frame. Default deny: an unapproved device or a bad
        # signature dies here and never reaches the loop — which is also what
        # keeps a stranger from stopping somebody else's run.
        with self._codec_lock:
            opener = self._opener
        try:
            plaintext = opener.open(sealed)
        except AgentsFrameRejected as exc:
            self._terminal(request_id, error_payload(f"rejected: {exc.rejection.value}"))
            return

        try:
            payload = decode_payload(plaintext)
            kind = payload.get("type")
        except (json.JSONDecodeError, TypeError, AttributeError):
            self._terminal(request_id, error_payload("bad payload"))
            return

        if kind == "stop":
            self._handle_stop(request_id, payload)
            return
        if kind in ("documents_list", "document_read"):
            from chuk_agents_runtime.chat_documents import DocumentStore, workspace_documents, read_workspace_document
            session_key = str(payload.get("session_key") or "default")
            try:
                documents = DocumentStore(self._db_path, session_key)
                if kind == "documents_list":
                    result = {"documents": [
                        {k: d[k] for k in ("id", "title", "kind", "version", "updated_at")}
                        for d in documents.list()
                    ] + workspace_documents(self._workspace_for(session_key))}
                else:
                    document_id = str(payload.get("id") or "")
                    session_workspace = self._workspace_for(session_key)
                    doc = (read_workspace_document(session_workspace, document_id)
                           if document_id.startswith("file:") and session_workspace
                           else documents.read(document_id))
                    result = {"selected": doc}
            except Exception as exc:
                result = {"error": str(exc), "id": payload.get("id")}
            self._terminal(request_id, {"type": "documents", "session_key": session_key, **result})
            return
        if self._handle_browser_kind(kind, request_id, payload):
            return
        if kind == "replay":
            # A reconnecting/reinstalled client re-streams a thread's transcript
            # from the server (the source of truth). It runs like a task in that
            # it opens and closes one request stream, so it keeps this request id.
            self._handle_replay(request_id, payload)
            return
        if kind == "approval_decision":
            # The user's answer to a pending here.now publish. A control frame
            # like a stop: it resolves a wait, it does not open or close a task,
            # so there is no request-scoped terminal to send.
            self._resolve_approval(payload)
            return
        if kind == "secrets":
            # The user's whole secret set (docs/WIRE_CONTRACT.md, "Secrets"):
            # replace what the vault holds and wake a tool waiting for it. A
            # control frame like approval_decision: no terminal.
            self._handle_secrets(payload)
            return
        if kind in ("automation_control", "automation_list"):
            # The user manages the automations of this host (docs/WIRE_CONTRACT.md,
            # "Automations"). A control is like a stop (no terminal; the state
            # change comes back as an ``automation`` event); a list request is
            # answered with one terminal frame, like a replay.
            self._handle_automation_frame(kind, request_id, payload)
            return
        if kind in ("agent_create", "agent_rename", "agent_list"):
            # The coworker names the host keeps (docs/WIRE_CONTRACT.md,
            # "Coworker names"). Every one of the three is answered with the
            # current list as one terminal frame, like a replay.
            self._handle_agent_frame(request_id, payload)
            return
        if kind == "agent_status":
            # What this coworker runs on, what it has spent and how long it has
            # been at it (docs/WIRE_CONTRACT.md, "Agent status"). Answered with
            # one terminal frame, like a skills list: every figure measured.
            self._handle_agent_status(request_id, payload)
            return
        if kind == "mcp_probe":
            # The app just connected a server (or opened the connector list) and
            # wants to know what it holds. Answered with one terminal
            # ``mcp_tools`` frame; the dial itself runs on its own thread.
            self._handle_mcp_probe(request_id, payload)
            return
        if kind in ("skills_list", "skill_control"):
            # The user manages the skills of this host (docs/WIRE_CONTRACT.md,
            # "Skills"). Both are answered with one terminal ``skills_list``
            # frame, like a replay: the list is the truth after any control.
            self._handle_skills_frame(kind, request_id, payload)
            return
        if kind == "run_ack":
            # The app saw a live ``done`` for this run. Record it so a later
            # replay does not flag the run as finished "while away", and tell
            # the host so it skips a completion notification.
            self._handle_run_ack(payload)
            return
        if kind == "account_authentication":
            # A second account frame mid-session (token rotation, a
            # re-provision after a reconnect). It is not a task: route it up to
            # the host, which refreshes its session in place. No terminal — it
            # is a control frame like a stop.
            self._call_hook(self._on_account_frame, payload)
            return
        if kind == "task" or kind is None:
            # ``None`` keeps the original contract: the first frames of this
            # protocol carried a prompt and no type.
            self._accept_task(request_id, payload)
            return
        if isinstance(kind, str) and kind.startswith("room_"):
            # Forwarded to the host, which owns the room. No request-scoped
            # terminal here: a room's replies (room_turn / room_done /
            # room_history) are streamed by the host on their own, not as this
            # frame's response.
            if self._on_room_frame is not None:
                self._on_room_frame(payload)
            else:
                self._terminal(request_id, error_payload("rooms not enabled"))
            return
        self._terminal(request_id, error_payload(f"unknown payload type: {kind!r}"))

    def _accept_task(self, request_id: str, payload: dict) -> None:
        try:
            prompt = payload["prompt"]
            session_key = payload.get("session_key", "default")
        except (KeyError, TypeError):
            self._terminal(request_id, error_payload("bad task payload"))
            return
        # The prompt must be text. Checked HERE, before the runs row is written:
        # a non-string prompt used to slip into the durable record under the
        # swallowing except below (or lose the record silently) and only fail
        # later in the worker. Refuse it up front with a terminal the app renders.
        if not isinstance(prompt, str):
            self._terminal(
                request_id,
                error_payload(
                    f"bad task payload: prompt must be a string, got {type(prompt).__name__}"
                ),
            )
            return
        raw_servers = payload.get("mcp_servers")
        mcp_servers = list(raw_servers) if isinstance(raw_servers, list) else None
        raw_herenow = payload.get("herenow")
        herenow = dict(raw_herenow) if isinstance(raw_herenow, dict) else None
        # What model this task asked for, exactly as the app's mode selector sends
        # it. Any of the three may be absent; absent means "the host decides".
        model = payload.get("model") or None
        provider = payload.get("provider") or None
        reasoning_effort = payload.get("reasoning_effort") or None
        run = _Run(
            request_id=request_id,
            session_key=str(session_key),
            prompt=prompt,
            # Built here, not in the loop, so a stop that arrives while the task
            # is still queued has something to fire.
            kill=KillSwitch(self._estop_path),
            mcp_servers=mcp_servers,
            herenow=herenow,
            debug=bool(payload.get("debug")),
            model=str(model) if model is not None else None,
            provider=str(provider) if provider is not None else None,
            reasoning_effort=(
                str(reasoning_effort) if reasoning_effort is not None else None
            ),
            regenerate=bool(payload.get("regenerate")),
            run_id=uuid4().hex,
            started_at=time.time(),
        )
        # One line per accepted task naming the model it will run on — never the
        # prompt. This is what makes a live run provable from the host log.
        logger.info(
            "task accepted request=%s session=%s run=%s model=%s provider=%s "
            "reasoning_effort=%s",
            request_id,
            run.session_key,
            run.run_id,
            run.model or HOST_DEFAULT,
            run.provider or HOST_DEFAULT,
            run.reasoning_effort or HOST_DEFAULT,
        )
        self._enqueue_run(run)

    def _enqueue_run(self, run: _Run) -> None:
        """Record the run, then queue it. Shared by a task frame and a fired
        automation, so both go through the ONE worker queue of this executor
        and are serialized per sandbox."""
        # Record the run before it is queued (docs/WIRE_CONTRACT.md): from here
        # on it exists on the host whether or not the socket survives. A store
        # failure never refuses the task; the run just has no durable record.
        try:
            store = StateStore(self._db_path)
            try:
                store.begin_run(
                    run.run_id,
                    store.route(run.session_key),
                    run.session_key,
                    # A key the user pasted into the prompt is masked before it
                    # becomes a row (docs/WIRE_CONTRACT.md, "Secrets").
                    self._scrub_text(run.prompt),
                    # Recorded so the run can prove later which model it ran on.
                    model=run.model,
                    provider=run.provider,
                    reasoning_effort=run.reasoning_effort,
                )
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — bookkeeping must not block a task
            pass
        with self._runs_lock:
            self._runs[run.request_id] = run
        self._queue.put(run)

    # -- automations (docs/WIRE_CONTRACT.md, "Automations") ---------------
    def submit_task(self, session_key: str, prompt: str, meta: dict | None = None) -> str:
        """Start a task that no frame asked for: a fired automation. It is a
        normal run of ``session_key`` — a ``runs`` row, the worker queue, the
        loop, a ``done`` — on the model / provider / effort of that session's
        LAST run (the user's current mode). Returns the ``run_id``."""
        meta = dict(meta or {})
        model = provider = effort = None
        try:
            store = StateStore(self._db_path)
            try:
                last = store.latest_run(session_key)
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — no history, host default
            last = None
        if last:
            model = last.get("model") or None
            provider = last.get("provider") or None
            effort = last.get("reasoning_effort") or None
        run = _Run(
            request_id=f"auto-{uuid4().hex[:12]}",
            session_key=str(session_key),
            prompt=prompt,
            kill=KillSwitch(self._estop_path),
            model=model,
            provider=provider,
            reasoning_effort=effort,
            run_id=uuid4().hex,
            started_at=time.time(),
            # ``automation`` (a fired schedule / watcher trigger) unless the
            # caller says otherwise (``job``: a background command reporting).
            origin=str(meta.get("origin") or "automation"),
            automation_id=str(meta.get("automation_id") or "") or None,
        )
        logger.info(
            "automation task accepted request=%s session=%s run=%s automation=%s model=%s",
            run.request_id,
            run.session_key,
            run.run_id,
            run.automation_id,
            run.model or HOST_DEFAULT,
        )
        self._enqueue_run(run)
        return run.run_id

    def _handle_automation_frame(self, kind: str, request_id: str, payload: dict) -> None:
        hook = self._on_automation_frame
        if hook is None:
            self._terminal(request_id, error_payload("automations not enabled"))
            return
        try:
            answer = hook(payload)
        except Exception as exc:  # noqa: BLE001 — the serve loop must survive a bad hook
            self._terminal(request_id, error_payload(f"automation frame failed: {type(exc).__name__}"))
            return
        if kind == "automation_list":
            rows = answer if isinstance(answer, list) else []
            self._terminal(request_id, automation_list_payload(rows))

    def _handle_agent_frame(self, request_id: str, payload: dict) -> None:
        hook = self._on_agent_frame
        if hook is None:
            self._terminal(request_id, error_payload("coworker names not enabled"))
            return
        try:
            rows = hook(payload)
        except Exception as exc:  # noqa: BLE001 — the serve loop must survive a bad hook
            self._terminal(request_id, error_payload(f"agent frame failed: {type(exc).__name__}"))
            return
        self._terminal(request_id, agent_list_payload(rows if isinstance(rows, list) else []))

    # -- agent status (docs/WIRE_CONTRACT.md, "Agent status") -------------
    def _handle_agent_status(self, request_id: str, payload: dict) -> None:
        """Answer one ``agent_status`` request with measured figures only."""
        session_key = str(payload.get("session_key") or "default")
        self._terminal(request_id, self._agent_status(session_key))

    def _push_agent_status(self, request_id: str, session_key: str) -> None:
        """Send the session's status on a stream that is still open.

        Fired after a run ends, so the panel's figures move with the work
        instead of only when the user reopens it. Best effort: a status frame
        must never be able to take a run down.
        """
        try:
            self._event(request_id, self._agent_status(session_key))
        except Exception:  # noqa: BLE001 — telemetry, not the result
            pass

    def _agent_status(self, session_key: str) -> dict:
        """The measured state of one session: model, spend, clock, sandbox.

        Every figure comes from a record of something that happened — the
        ``runs`` rows of this session and the sandbox this executor really
        handed that session. A block that cannot be measured is left out of the
        frame entirely, so the app never has to guess whether a zero is a zero.
        """
        rows = self._session_runs(session_key)
        model = self._status_model(session_key, rows)
        tokens = self._status_tokens(rows)
        runtime = self._status_runtime(rows)
        return agent_status_payload(
            session_key=session_key,
            model=model,
            tokens=tokens,
            runtime=runtime,
            sandbox=self._status_sandbox(session_key),
        )

    def _session_runs(self, session_key: str) -> list[dict]:
        """Every ``runs`` row of one session, oldest first.

        Read straight off the state file: the aggregate is a read of a table the
        wire contract already defines, and a failed read means "no figures",
        never a failed frame.
        """
        if not self._db_path or not os.path.exists(self._db_path):
            return []
        try:
            conn = sqlite3.connect(self._db_path)
        except sqlite3.Error:
            return []
        try:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute(
                "SELECT state, tokens_spent, started_at, finished_at, model, "
                "provider, reasoning_effort FROM runs WHERE session_key=? "
                "ORDER BY started_at, rowid",
                (session_key,),
            )
            return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error:
            return []
        finally:
            conn.close()

    def _status_model(self, session_key: str, rows: list[dict]) -> dict | None:
        """What this session last ran on.

        The run row is the first answer: it is what the task asked for. A task
        that named nothing has NULL there, and then the answer is the client the
        executor really built for that session's last run — recorded as it was
        built, so no model is ever constructed just to fill a status frame.
        ``None`` when the session has never run: the panel then shows no model
        rather than a guess.
        """
        for row in reversed(rows):
            model_id = row.get("model")
            if model_id:
                body = {"id": str(model_id), "source": "run"}
                if row.get("provider"):
                    body["provider"] = str(row["provider"])
                if row.get("reasoning_effort"):
                    body["reasoning_effort"] = str(row["reasoning_effort"])
                return body
        observed = self._model_identities.get(session_key)
        return dict(observed) if observed else None

    def _note_model_identity(self, session_key: str, client: Any) -> None:
        """Remember what a session's run actually ran on.

        Called once per task with the client the executor built, so the status
        frame can name the host's default model without building a second one.
        A client that exposes no id (a mock) records nothing.
        """
        model_id = getattr(client, "model_id", None)
        if not model_id:
            return
        body: dict[str, Any] = {"id": str(model_id), "source": "run"}
        provider = getattr(client, "provider_slug", None)
        if provider:
            body["provider"] = str(provider)
        effort = getattr(client, "reasoning_effort", None)
        if effort:
            body["reasoning_effort"] = str(effort)
        self._model_identities[session_key] = body

    @staticmethod
    def _status_tokens(rows: list[dict]) -> dict | None:
        """What the session has spent, summed off the runs it really made.

        ``None`` when the session has no run at all: an empty thread has not
        spent zero tokens, it has spent nothing that was ever measured.
        """
        if not rows:
            return None
        total = sum(int(row.get("tokens_spent") or 0) for row in rows)
        last = int(rows[-1].get("tokens_spent") or 0)
        return {"total": total, "runs": len(rows), "last_run": last}

    @staticmethod
    def _status_runtime(rows: list[dict]) -> dict | None:
        """The session's clock: when it first ran, and how long it has worked.

        ``active_seconds`` is time the agent was actually running, summed over
        its runs — not wall-clock since the thread was opened, which would only
        measure how long ago the user first said hello.
        """
        if not rows:
            return None
        now = time.time()
        started = min(float(row.get("started_at") or now) for row in rows)
        active = 0.0
        running = False
        current = 0.0
        for row in rows:
            begin = float(row.get("started_at") or 0.0)
            end = row.get("finished_at")
            if end is None:
                if row.get("state") == "running" and begin:
                    running = True
                    current = max(0.0, now - begin)
                    active += current
                continue
            active += max(0.0, float(end) - begin)
        body = {
            "started_at": started,
            "active_seconds": active,
            "runs": len(rows),
            "running": running,
        }
        if running:
            body["current_seconds"] = current
        return body

    def _status_sandbox(self, session_key: str) -> dict | None:
        """The box this session runs in — the per-agent container, or the local
        directory (§6, bead cowork-jo2). It is what makes "one container per
        coworker" visible instead of merely claimed."""
        try:
            env = self._environment_for(session_key)
        except Exception:  # noqa: BLE001 — no box to name
            return None
        workspace = getattr(env, "workspace", None)
        container = getattr(env, "container_name", None)
        body: dict[str, Any] = {"kind": "docker" if container else "local"}
        if container:
            body["container"] = str(container)
            container_id = getattr(env, "container_id", None)
            if container_id:
                body["container_id"] = str(container_id)[:12]
        if workspace:
            body["workspace"] = str(workspace)
        return body

    def _handle_skills_frame(self, kind: str, request_id: str, payload: dict) -> None:
        root = (
            str(Path(self._workspace) / SKILLS_DIRNAME) if self._workspace else None
        )
        try:
            settings = SkillSettingsStore(self._db_path)
            if kind == "skill_control":
                body = apply_skill_control(
                    root,
                    settings,
                    name=payload.get("name"),
                    action=payload.get("action"),
                    seed_root=self._skills_seed_root,
                )
            else:
                body = skills_inventory(
                    root, settings=settings, seed_root=self._skills_seed_root
                )
        except Exception as exc:  # noqa: BLE001 — the serve loop must survive a bad store
            self._terminal(request_id, error_payload(f"skills frame failed: {type(exc).__name__}"))
            return
        self._terminal(request_id, skills_list_payload(body["skills"], body["errors"]))

    def _handle_run_ack(self, payload: dict) -> None:
        run_id = payload.get("run_id")
        if not isinstance(run_id, str) or not run_id:
            return
        try:
            store = StateStore(self._db_path)
            try:
                store.mark_run_seen(run_id)
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — an ack is best-effort
            pass
        self._call_hook(self._on_run_ack, {"run_id": run_id})

    def _call_hook(self, hook: Callable[[dict], None] | None, payload: dict) -> None:
        """Call an optional host hook. A raising hook is swallowed: a notifier
        or a token refresh must never take the serve loop or a run down.

        The payload passes the secret scrubber first (docs/WIRE_CONTRACT.md,
        "Secrets"): a run summary carries the prompt and the answer, and a
        host-side consumer (a notifier, an automation log) must not be the one
        place a value slips through."""
        if hook is None:
            return
        scrubber = self._secret_scrubber
        if scrubber is not None and isinstance(payload, dict):
            payload = scrubber.scrub_obj(payload)
        try:
            hook(payload)
        except Exception:  # noqa: BLE001 — hooks are observers, not owners
            pass

    # -- transcript replay (server is the truth) -------------------------
    def _handle_replay(self, request_id: str, payload: dict) -> None:
        """Re-stream one thread's whole stored transcript to a reconnecting client.

        The server holds the authoritative transcript (see
        ``docs/PRODUCT_PHILOSOPHY``). A fresh or reinstalled client has no local
        copy, so it sends one ``replay`` frame and gets the thread back as the SAME
        ``user`` / ``delta`` / ``tool`` events a live run streams, each marked
        ``replay``. The stream closes with a ``done`` so the client leaves its
        loading state; the ``done`` is marked ``replay`` and its ``reason`` is
        ``replay``, so nothing reads it as a finished or a stopped run.

        Read only, so it runs on the serve thread and never touches the task
        worker or the shared session that a live run uses. A separate
        :class:`StateStore` opens on this thread (SQLite connections are not shared
        across threads); WAL lets it read while a task writes. Any failure ends the
        stream with an ``error`` instead of killing the serve loop.
        """
        session_key = str(payload.get("session_key", "default"))
        # The replay cursor (docs/WIRE_CONTRACT.md): a client that already holds
        # the thread up to a message id asks only for what came after it.
        try:
            after_id = max(0, int(payload.get("after_id") or 0))
        except (TypeError, ValueError):
            after_id = 0
        # Replay paging (docs/WIRE_CONTRACT.md, Bead cowork-axx): ``limit`` asks
        # for the newest N turn rows of the window only; ``before_id`` caps the
        # window for the next, older page. Absent = the whole window, as before.
        try:
            before_id = max(0, int(payload.get("before_id") or 0))
        except (TypeError, ValueError):
            before_id = 0
        try:
            limit = max(0, int(payload.get("limit") or 0))
        except (TypeError, ValueError):
            limit = 0
        has_more = False
        page_after_id = after_id
        try:
            store = StateStore(self._db_path)
        except Exception as exc:  # noqa: BLE001 — a bad db must not wedge serving
            self._terminal(
                request_id, error_payload(f"replay failed: {type(exc).__name__}")
            )
            return
        # Replay and a live run's stream never interleave: the emit lock is held
        # across the whole emission, so a turn persisted while this replay runs
        # is not sent twice (once here, once live). A large thread costs the
        # worker a few hundred milliseconds of back-pressure, which is bounded.
        with self._emit_lock:
            try:
                session_id = store.route(session_key)
                # First the state header: is a run for this thread in flight?
                self._event(request_id, self._run_state_for(store, session_key))
                if before_id == 0:
                    # A reconnecting app also gets every rotated MCP credential it
                    # has not acknowledged yet (docs/WIRE_CONTRACT.md, mcp_credentials).
                    self._flush_pending_mcp_credentials(session_key, request_id)
                    # ...and every ``secret_request`` a run in this thread is still
                    # waiting on: the frame was never a row, so this is how a
                    # reconnect mid-request shows the dialog again. An OLDER page
                    # (``before_id``) is not a reconnect: nothing pending to flush.
                    self._flush_pending_secret_requests(session_key, request_id)
                page_after_id, has_more = store.replay_page_bounds(
                    session_id, after_id=after_id, before_id=before_id, limit=limit
                )
                events = store.replay_events(
                    session_id, after_id=page_after_id, before_id=before_id
                )
                terminals = store.run_terminals(
                    session_key, after_id=page_after_id, before_id=before_id
                )
                # Merge by message id so a run's terminal comes right after its
                # last turn. Same id: the turn first, then the terminal.
                merged = sorted(
                    [(int(e.get("mid", 0)), 0, i, e) for i, e in enumerate(events)]
                    + [(int(t.get("mid", 0)), 1, i, t) for i, t in enumerate(terminals)],
                    key=lambda item: (item[0], item[1], item[2]),
                )
                for _, _, _, event in merged:
                    self._event(request_id, event)
            except Exception as exc:  # noqa: BLE001 — report, do not crash the thread
                self._terminal(
                    request_id, error_payload(f"replay failed: {type(exc).__name__}")
                )
                return
            finally:
                try:
                    store.close()
                except Exception:  # noqa: BLE001 — cleanup must not mask the result
                    pass
            # Close the stream the way a live run does. ``reason: replay`` is the
            # history-end marker: the client renders nothing for it and never
            # mistakes it for a finished or a stopped run.
            marker: dict[str, Any] = {
                **done_payload(final_answer=None, reason="replay", iterations=0),
                "replay": True,
            }
            if limit > 0 or before_id > 0:
                # Replay paging: where this page starts and whether an older one
                # exists. ``oldest_mid`` is the row to ask ``before_id`` for.
                marker["has_more"] = has_more
                marker["oldest_mid"] = page_after_id + 1
                if before_id > 0:
                    marker["before_id"] = before_id
            self._terminal(request_id, marker)

    def _run_state_for(self, store: StateStore, session_key: str) -> dict:
        """The ``run_state`` header of a replay: ``running`` when a run for the
        session is queued or in flight here, else ``idle``. The registry is the
        live truth; the store covers a run this process recorded but has since
        forgotten (it never does today, but the order of checks is safe)."""
        live: _Run | None = None
        with self._runs_lock:
            for run in self._runs.values():
                if run.session_key == session_key:
                    live = run
                    break
        if live is not None:
            return run_state_payload(
                session_key,
                "running",
                run_id=live.run_id,
                started_at=live.started_at,
                prompt=live.prompt,
                browser_open=self._browser_open,
                vnc_available=self._vnc_available(session_key),
            )
        latest = store.latest_run(session_key)
        if latest is not None and latest.get("state") == "running":
            return run_state_payload(
                session_key,
                "running",
                run_id=latest.get("run_id"),
                started_at=latest.get("started_at"),
                prompt=latest.get("prompt"),
                browser_open=self._browser_open,
                vnc_available=self._vnc_available(session_key),
            )
        return run_state_payload(
            session_key, "idle", browser_open=self._browser_open,
            vnc_available=self._vnc_available(session_key),
        )

    def _vnc_available(self, session_key: str | None = None) -> bool:
        """A current sandbox browser can be viewed; VNC is started on demand.

        Never advertise the user's extension browser or a local/headless host.
        This does not start a container, browser, or VNC process.

        The last question is asked of the display itself: is a browser window
        ON it right now? The MCP server owns the Chromium and takes it down
        with its own session, so ``_browser_open`` — which is derived from the
        agent's tool calls — outlives the window it describes. Advertising a
        screen that is not there is what made "take over" open a black page
        (bead cowork-tf1u).
        """
        if not self._browser_open or not self._browser_mcp or browser_target() == USER_BROWSER:
            return False
        env = self._environment_for(session_key)
        binary = getattr(getattr(env, "_cli", None), "binary", None)
        container = getattr(env, "container_id", None)
        if binary and container and self._browser_window_present(
            str(binary), str(container)
        ):
            return True
        # The asking session's own box has nothing on it. That is not the end of
        # the answer: with one container per agent, the browser the user means
        # is usually in the box of whichever agent opened it, and the view
        # follows it there (see :meth:`_browser_server_targets`). Advertising
        # the screen only for the asking box is why the button stayed dark
        # while browsers were open (bead cowork-qp5i).
        for prefix, box, _manager in self._browser_server_targets(
            session_key, str(container or "")
        ):
            if box == container:
                continue  # already asked, and it said no
            if self._browser_window_present(prefix[0], box):
                return True
        return False

    #: How long a window probe is trusted. A run asks for the header on every
    #: replay and every state change; the display does not move that fast.
    BROWSER_WINDOW_TTL_S = 3.0

    #: Count the PAGES on the sandbox display, not the windows. Chromium maps
    #: two helpers next to every page — a 1x1 window and a 10x10 one called
    #: "Chromium clipboard" — and neither carries a WM_CLASS. Matching the
    #: class field (the quoted pair at the end of an ``xwininfo -children``
    #: line) counts the real page and skips the helpers, which is why a display
    #: with nothing on it no longer claims a browser (measured in a live
    #: container: 2 windows by name, 1 by class, for one open page).
    BROWSER_WINDOW_COUNT_SH = (
        'DISPLAY=${AGENTS_BROWSER_DISPLAY:-:99} xwininfo -root -children '
        "2>/dev/null | grep -Eci '\\(\"[^\"]*[Cc]hrom'; exit 0"
    )

    def _browser_windows(self, binary: str, container: str) -> int | None:
        """How many browser pages are on that box's display, or ``None``.

        ``None`` is "could not tell" (no xwininfo in the image, docker refusing,
        container gone) and must never be read as "no browser": it is the
        answer an older image gives, and it may not take a working screen away.
        """
        argv = [
            binary, "exec", container, "sh", "-lc", self.BROWSER_WINDOW_COUNT_SH,
        ]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=8)
        except Exception:  # noqa: BLE001 — a probe that cannot run proves nothing
            return None
        out = (proc.stdout or "").strip()
        if proc.returncode != 0 or not out.isdigit():
            return None
        count = int(out)
        self._browser_window_probe[container] = (time.time(), count > 0)
        return count

    def _browser_window_present(self, binary: str, container: str) -> bool:
        """Is a browser window mapped on that box's display right now?

        One ``xwininfo`` per box per :data:`BROWSER_WINDOW_TTL_S`, so a burst of
        headers costs one probe. A probe that cannot run at all answers with
        what the tool calls said, so an older image is no worse off than before.
        """
        now = time.time()
        cached = self._browser_window_probe.get(container)
        if cached is not None and now - cached[0] < self.BROWSER_WINDOW_TTL_S:
            return cached[1]
        count = self._browser_windows(binary, container)
        return True if count is None else count > 0

    def _set_browser_open(
        self, open_: bool, request_id: str, session_key: str | None = None
    ) -> None:
        """Record the browser state; on a change, tell the app once
        (``browser_view`` ``opened`` / ``closed`` on the stream that learned it)."""
        with self._vnc_lock:
            if self._browser_open == open_:
                return
            self._browser_open = open_
            # The window came or went; the cached probes are about the old world.
            self._browser_window_probe.clear()
        if request_id:
            self._event(request_id, browser_view_payload(
                "opened" if open_ else "closed",
                vnc_available=self._vnc_available(session_key),
            ))

    # -- live browser view (§9.1) ----------------------------------------
    def _handle_browser_kind(self, kind: str, request_id: str, payload: dict) -> bool:
        """Dispatch the three live-view frames. Returns False for other kinds.

        `browser_start` is handed to its own thread: bringing x11vnc up can take
        seconds and must not stall `stop` and every other frame behind it. The
        generation counter lets a later stop/start win over a start still in
        flight (see `_vnc_start`).
        """
        if kind == "browser_start":
            with self._vnc_lock:
                self._vnc_generation += 1
                generation = self._vnc_generation
            threading.Thread(
                target=self._vnc_start,
                args=(request_id, payload, generation),
                name="vnc-start",
                daemon=True,
            ).start()
            return True
        if kind == "browser_stop":
            with self._vnc_lock:
                self._vnc_generation += 1
            self._vnc_teardown(reason="stopped")
            return True
        if kind == "browser_data":
            self._vnc_feed(payload)
            return True
        return False

    def _vnc_exec_prefix(
        self, session_key: str | None = None
    ) -> tuple[list[str], str] | None:
        """`docker exec` prefix + container id for that agent's box, or None.

        None means the sandbox is not the docker backend (nothing to watch) or
        the container could not be realized. Forces the container live first,
        because `container_id` is None until the first command runs.

        ``session_key`` names the agent whose box is meant: every agent has its
        own container, so a live view must never open a peer's.
        """
        env = self._environment_for(session_key)
        cli = getattr(env, "_cli", None)
        binary = getattr(cli, "binary", None)
        if binary is None or not hasattr(env, "container_id"):
            return None
        try:
            result = env.run_bash("true", internal=True)  # realize the container
            if result is not None and not result.ok:
                return None
        except Exception:  # noqa: BLE001 — no container, no view; caller reports
            return None
        cid = getattr(env, "container_id", None)
        if not cid:
            return None
        prefix = [binary, "exec", "-i"]
        user = getattr(env, "_user", None)
        if user:
            prefix += ["-u", str(user)]
        return prefix, str(cid)

    def _browser_mcp_entry(self, session_key: str | None = None) -> dict | None:
        """The browser MCP server entry for that agent, or None.

        Two targets, one entry, because the tool names are the same either way
        (``mcp__playwright__browser_*``) and everything downstream — presence,
        replay, the app's button — reads that one transcript:

        ``sandbox`` (the default)
            The Playwright MCP server INSIDE the container over ``docker exec``
            stdio, so the Chromium it launches renders to the container's Xvfb,
            the display x11vnc serves. The agent's browser and the watched
            browser are one process. None on the browser-free base image or when
            the sandbox is not docker.

        ``user_browser``
            ``agents-extension-mcp`` on this machine, talking to the add-on in
            the browser the user already has open. No container is involved, so
            this one also works on the base image and with the local sandbox.
        """
        if browser_target() == USER_BROWSER:
            return extension_mcp_entry()
        if not self._browser_mcp:
            return None
        prep = self._vnc_exec_prefix(session_key)
        if prep is None:
            return None
        prefix, cid = prep  # [binary, "exec", "-i", ("-u", user)?]
        from .browser_profile import retired_browser_hostname

        retired = retired_browser_hostname(
            prefix[0], cid, getattr(self._environment_for(session_key), "workspace", None)
        )
        if retired:
            prefix += ["-e", f"AGENTS_BROWSER_RETIRED_HOSTNAME={retired}"]
        return {
            "name": "playwright",
            "command": prefix[0],
            "args": [*prefix[1:], cid, "agents-browser-mcp"],
        }

    #: What the app is told while the nudge below brings the browser up. The
    #: wording keeps the "no page open" phrase the app matches on today; the
    #: machine-readable half is ``browser_view.reason`` (``opening``).
    BROWSER_OPENING_MESSAGE = "no page open yet — opening the browser now"
    #: ...and when nothing in this process can open one (``reason`` ``no_browser``).
    BROWSER_CLOSED_MESSAGE = (
        "no page open yet — no browser server is connected to open one"
    )
    #: The launcher every sandbox browser server is exec'd as. Its argv ends
    #: ``<container> agents-browser-mcp``, so a connected server states WHICH
    #: box its Chromium draws in — the one fact that ties a live browser to a
    #: display the view can serve.
    BROWSER_MCP_LAUNCHER = "agents-browser-mcp"

    def _browser_server_targets(
        self, session_key: str | None, container: str
    ) -> list[tuple[list[str], str, MCPManager]]:
        """Every connected sandbox browser server, as ``(prefix, box, manager)``.

        A server that is connected has already brought its box's Xvfb up: the
        launcher starts the display before it execs the MCP server. So this list
        is also the list of boxes that HAVE a display worth serving — which is
        what makes it the right search order for the view.

        Ordered: the box the view asked for, then the asking session's own box,
        then the rest. ``browser_start`` carries no ``session_key`` today, so
        the requested box is always this executor's own one, while an agent's
        browser lives in that agent's container. Watching only the requested box
        is how a user with browsers open was told no browser was open.

        Never raises, and never builds anything: two MCP servers on one profile
        is not a thing (``browser-mcp-owner.py`` refuses the second with
        "profile still has a live owner"), so a manager invented here would
        break the next real task instead of helping it.
        """
        with self._mcp_lock:
            exact = self._mcp_managers.get(str(session_key or ""))
            managers = list(self._mcp_managers.values())
        found: list[tuple[list[str], str, MCPManager]] = []
        for manager in managers:
            try:
                names = set(browser_servers(manager))
                if not names:
                    continue
                for config in manager.configs:
                    args = list(config.args or [])
                    if config.name not in names or not config.command:
                        continue
                    # `docker exec -i [-u <user>] <cid> agents-browser-mcp`.
                    # Anything else is the user's own browser over the
                    # extension bridge: no container, nothing to serve.
                    if len(args) < 2 or args[-1] != self.BROWSER_MCP_LAUNCHER:
                        continue
                    found.append(([config.command, *args[:-2]], args[-2], manager))
            except Exception:  # noqa: BLE001 — an odd manager is simply no target
                continue

        def rank(target: tuple[list[str], str, MCPManager]) -> int:
            _prefix, box, manager = target
            if box == container:
                return 0
            return 1 if manager is exact else 2

        found.sort(key=rank)
        seen: set[str] = set()
        unique: list[tuple[list[str], str, MCPManager]] = []
        for prefix, box, manager in found:
            if box in seen:
                continue
            seen.add(box)
            unique.append((prefix, box, manager))
        return unique

    def _nudge_browser_open(
        self, manager: MCPManager, request_id: str, session_key: str | None
    ) -> None:
        """Open the browser GUI on its own thread; never blocks, never raises.

        Off the critical path on purpose: launching Chromium costs a second or
        two and the view must come up now — the window grows into the stream
        that is already running. When the server answers ``ok`` the browser
        state flips, so the app stops saying the browser is closed.
        """

        def work() -> None:
            try:
                opened = open_browser_gui(manager)
            except Exception:  # noqa: BLE001 — a browser that refuses is not an error
                return
            if opened:
                self._set_browser_open(True, request_id, session_key)

        threading.Thread(target=work, name="vnc-browser-open", daemon=True).start()

    def _may_open_browser(self) -> bool:
        """``AGENTS_BROWSER_AUTO_OPEN=0`` is the documented way to keep the
        browser lazy; then the view reports an empty display instead of
        filling it."""
        try:
            return auto_open_enabled()
        except Exception:  # noqa: BLE001 — a view must never die on a switch
            return False

    def _vnc_start(
        self, request_id: str, payload: dict, generation: int | None = None
    ) -> None:
        # ``generation``: the value the dispatcher assigned this start. If a
        # newer start or a stop bumps it while we are still bringing x11vnc up,
        # this start is stale and must not register its bridge.
        if generation is None:
            with self._vnc_lock:
                self._vnc_generation += 1
                generation = self._vnc_generation
        # Only ever one live view; replace any prior one silently.
        self._vnc_teardown(reason="stopped", notify=False)

        # Where the wait before the first picture goes. The user's complaint was
        # "it loads forever" and the only way to answer it is a number per step
        # (bead cowork-c0zd). Measured on a live box the whole block below costs
        # ~300 ms — the seconds were inside x11vnc, not here — so this log is
        # what proves it is still true after a change.
        watch = _Stopwatch()

        session_key = payload.get("session_key")
        prep = self._vnc_exec_prefix(session_key)
        watch.mark("container")
        if prep is None:
            self._event(
                request_id,
                browser_view_payload(
                    "error",
                    message="live view needs the docker sandbox",
                    reason="no_sandbox",
                ),
            )
            return
        prefix, cid = prep

        # WHICH box to watch. A box whose browser server is connected has a
        # display; the box the frame asks for may well not, because the app
        # sends no session_key and every agent has its own container. So try
        # the boxes with a live browser first and keep the asked-for one as the
        # fallback, instead of reporting "no browser" at the first closed door.
        attempts: list[tuple[list[str], str, MCPManager | None]] = [
            (p, box, manager)
            for p, box, manager in self._browser_server_targets(session_key, cid)
        ]
        if all(box != cid for _p, box, _m in attempts):
            attempts.append((prefix, cid, None))
        watch.mark("targets")

        # Bring x11vnc up on the browser display (idempotent). Exit 3 = that box
        # has no browser display at all, so there is nothing to serve there.
        # Use the FULL prefix: it is [binary, "exec", "-i", ("-u", user)?] and the
        # `-u <user>` pair must stay intact. Slicing it (`prefix[:-1]`) to drop the
        # harmless `-i` also dropped the username when a user was set, producing
        # `docker exec -i -u <cid> agents-vnc-up` — a malformed command that failed
        # with "could not start the VNC server". `-i` on a captured run is a no-op.
        # Per-view VNC secret (§9.1 hardening). The sandbox runs untrusted code
        # as the `agents` user; x11vnc must not be reachable from inside it
        # without a secret. `agents-vnc-up` therefore runs as ROOT and writes
        # the secret to a root-only file that x11vnc re-reads on every client
        # connect (`-passwdfile read:`), so each view gets a fresh secret with
        # no x11vnc restart. The secret reaches the app inside the sealed
        # `started` frame and nowhere else. VNC auth keys are 8 bytes; 8
        # url-safe chars is what x11vnc/DES actually use.
        secret = secrets.token_urlsafe(6)[:8]
        chosen: tuple[list[str], str, MCPManager | None, Any] | None = None
        # What to say if no box answers. The last failure wins, and every one of
        # them names a cause instead of handing the user a chore.
        failure = (
            "no browser open: no sandbox browser is running to watch",
            "no_display",
        )
        for candidate, box, manager in attempts:
            up = self._vnc_up(candidate, box, secret)
            if up is None:
                failure = (
                    "no browser open: the sandbox could not be reached",
                    "exec_failed",
                )
                continue
            watch.mark("vnc-up")
            if up.returncode == 3:
                failure = (
                    "no browser open: no sandbox browser is running to watch",
                    "no_display",
                )
                continue
            if up.returncode != 0:
                failure = ("could not start the VNC server", "vnc_start_failed")
                continue
            chosen = (candidate, box, manager, up)
            break
        if chosen is None:
            self._event(
                request_id,
                browser_view_payload("error", message=failure[0], reason=failure[1]),
            )
            return
        prefix, cid, nudge, up = chosen

        if self._vnc_open_bridge(
            prefix, cid, request_id, session_key, generation
        ) is None:
            return
        watch.mark("bridge")
        # How many PAGES are on that display? Ask the box directly rather than
        # trust the script's count: `agents-vnc-up` counts every mapped window,
        # so Chromium's 1x1 helper and its 10x10 clipboard window read as a
        # browser — and a script inside an image cannot be fixed for a container
        # that is already running. The script's WINDOWS= line stays as the
        # fallback for a box whose image has no xwininfo.
        windows = self._browser_windows(prefix[0], cid)
        if windows is None:
            windows = _script_window_count(up.stdout)
        watch.mark("windows")
        message = ""
        reason = ""
        if windows == 0:
            # Empty display. Opening the browser is the answer, not a chore for
            # the user: one `browser_tabs list` on the box's own server puts a
            # page on the display, and it grows into the stream that is already
            # running. Only when there is nothing to poke does the view say so
            # — and then it says why.
            if nudge is not None and self._may_open_browser():
                message, reason = self.BROWSER_OPENING_MESSAGE, "opening"
            else:
                message, reason = self.BROWSER_CLOSED_MESSAGE, "no_browser"
                nudge = None
        else:
            nudge = None
        # The display is the ground truth when we have it (-1 = the script could
        # not tell): flip the browser state before `started`, so the app has
        # the verdict by the time it decides whether to show the view.
        if windows is not None and windows >= 0:
            self._set_browser_open(windows > 0, request_id, session_key)
        self._event(
            request_id,
            browser_view_payload(
                "started", message=message, password=secret, reason=reason,
                vnc_available=self._vnc_available(session_key),
            ),
        )
        logger.info("live browser view start path: %s", watch.report())
        # After `started`, so the view is live before Chromium is asked for, and
        # so an "opened" from the nudge can never overtake the frame that opens
        # the view.
        if nudge is not None:
            self._nudge_browser_open(nudge, request_id, session_key)

    #: The RFB port x11vnc binds inside every sandbox box.
    VNC_PORT = "5900"
    #: How often a dropped pipe is dialled back in before the view is given up,
    #: and how long to wait between tries. A phone under a bridge is offline for
    #: seconds, not milliseconds, so the first retry is immediate (the common
    #: case is a pipe that died for a local reason) and the rest are spaced out.
    VNC_RECONNECT_TRIES = 4
    VNC_RECONNECT_BACKOFF_S = (0.0, 0.3, 1.0, 2.0)

    def _vnc_open_bridge(
        self,
        prefix: list[str],
        cid: str,
        request_id: str,
        session_key: str | None,
        generation: int,
    ) -> _VncBridge | None:
        """Open the socat pipe to x11vnc and register it as THE live view.

        Returns the bridge, or None when it could not be opened (an ``error``
        frame is sent then) or when a newer start/stop won the race while we
        were opening (nothing is sent then — whoever bumped the generation owns
        the view now).
        """
        argv = prefix + [
            cid, "socat", "STDIO", f"TCP:127.0.0.1:{self.VNC_PORT}",
        ]

        def emit(chunk: bytes) -> None:
            self._event(request_id, browser_data_payload(chunk))

        holder: list[_VncBridge] = []

        def on_closed() -> None:
            # The pipe died on its own. That is the user closing the view, the
            # container going away — or the mobile link hiccuping, which is the
            # case that must NOT end the view. Only act if THIS bridge is still
            # the registered one: a late close from a bridge that was already
            # replaced must not kill its successor.
            if not holder:
                return
            self._vnc_recover(holder[0], generation)

        try:
            bridge = _VncBridge(argv, emit=emit, on_closed=on_closed, autostart=False)
        except (OSError, subprocess.SubprocessError) as exc:
            self._event(
                request_id,
                browser_view_payload(
                    "error",
                    message=f"vnc bridge failed: {type(exc).__name__}",
                    reason="bridge_failed",
                ),
            )
            return None
        holder.append(bridge)
        # Register first, THEN start the pump, so an instantly-dying socat is
        # torn down (and reported) instead of lingering as a dead "live" view.
        # Stale start (a stop or a newer start won while x11vnc came up): drop
        # this bridge quietly; whoever bumped the generation owns the view now.
        with self._vnc_lock:
            if generation != self._vnc_generation:
                stale = True
            else:
                stale = False
                self._vnc = bridge
                self._vnc_stream_id = request_id
                self._vnc_framer = _RfbClientFramer()
                self._vnc_route = (list(prefix), cid, request_id, session_key)
        if stale:
            bridge.close()
            return None
        bridge.start()
        return bridge

    def _vnc_recover(self, dead: _VncBridge, generation: int) -> None:
        """A live view's pipe dropped: dial back in instead of going dark.

        "The connection is bad" was, measured, a pipe that died once and stayed
        dead: the executor said ``stopped`` and the app latched its bridge shut,
        so a five-second tunnel cost the whole view (bead cowork-c0zd). x11vnc
        itself survives — it is ``-forever``, it keeps the screen, and the box
        is still there — so the honest answer to a dropped pipe is another pipe.

        The RFB SESSION cannot be resumed: the new x11vnc client starts at the
        version string with fresh zlib streams, so the app has to hand the bytes
        to a NEW RFB client. That is what ``started`` + ``reconnected`` says.
        Until it arrives the app gets ``reconnecting``, whose whole point is
        that nothing was torn down and the last picture still stands.

        Runs on its own thread: it is called from the dying pump's close hook
        and it does seconds of subprocess work.
        """
        with self._vnc_lock:
            mine = self._vnc is dead and generation == self._vnc_generation
            route = self._vnc_route
        if not mine or route is None:
            return
        if not dead.saw_bytes:
            # socat never reached x11vnc, so there was never a view to lose.
            # Retrying would only make the same failure take five seconds
            # longer to report.
            self._vnc_teardown(reason="stopped", expected=dead)
            return
        threading.Thread(
            target=self._vnc_recover_work,
            args=(dead, generation, route),
            name="vnc-recover",
            daemon=True,
        ).start()

    def _vnc_recover_work(
        self,
        dead: _VncBridge,
        generation: int,
        route: tuple[list[str], str, str, str | None],
    ) -> None:
        prefix, cid, request_id, session_key = route
        self._event(
            request_id,
            browser_view_payload(
                "reconnecting",
                message="the live view lost its connection — reconnecting",
                reason="reconnecting",
                vnc_available=self._vnc_available(session_key),
            ),
        )
        for attempt in range(self.VNC_RECONNECT_TRIES):
            delay = self.VNC_RECONNECT_BACKOFF_S[
                min(attempt, len(self.VNC_RECONNECT_BACKOFF_S) - 1)
            ]
            if delay and not self._vnc_sleep(delay, generation):
                return
            with self._vnc_lock:
                if self._vnc is not dead or generation != self._vnc_generation:
                    return  # a stop or a newer start owns the view now
            # Re-arm x11vnc with a FRESH secret. `agents-vnc-up` is idempotent
            # and rewrites the password file that x11vnc re-reads on every
            # connect, so this costs one docker exec (~80 ms measured) and never
            # restarts a healthy server. Exit 3 means the display itself is gone
            # — the browser was closed — and no number of retries brings it back.
            secret = secrets.token_urlsafe(6)[:8]
            up = self._vnc_up(prefix, cid, secret)
            if up is None or up.returncode == 3:
                break
            if up.returncode != 0:
                continue
            with self._vnc_lock:
                if self._vnc is not dead or generation != self._vnc_generation:
                    return
                self._vnc = None  # release the slot for the replacement
                self._vnc_framer = None
            bridge = self._vnc_open_bridge(
                prefix, cid, request_id, session_key, generation
            )
            if bridge is None:
                # Either the slot was taken (nothing to do) or socat refused;
                # put the dead bridge back so the next close hook still matches.
                with self._vnc_lock:
                    if self._vnc is None and generation == self._vnc_generation:
                        self._vnc = dead
                continue
            logger.info("live browser view reconnected after %d attempt(s)", attempt + 1)
            self._event(
                request_id,
                browser_view_payload(
                    "started",
                    message="",
                    password=secret,
                    reason="reconnected",
                    vnc_available=self._vnc_available(session_key),
                ),
            )
            return
        self._vnc_teardown(reason="stopped", expected=dead)

    def _vnc_sleep(self, seconds: float, generation: int) -> bool:
        """Wait, but give up the moment a stop or a newer start takes the view."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            with self._vnc_lock:
                if generation != self._vnc_generation:
                    return False
            time.sleep(min(0.1, max(0.0, deadline - time.monotonic())))
        return True

    def _vnc_up(
        self, prefix: list[str], box: str, secret: str
    ) -> subprocess.CompletedProcess | None:
        """Run ``agents-vnc-up`` on one box, or None when it could not run.

        Always as ROOT and with the per-view secret: the script writes it to a
        root-only file that x11vnc re-reads on every client connect, so a new
        view (and a reconnect) rotates the secret without restarting x11vnc.
        """
        argv = [
            prefix[0], "exec", "-i", "-u", "root",
            "-e", f"AGENTS_VNC_PASSWD={secret}",
            box, "agents-vnc-up",
        ]
        try:
            return subprocess.run(argv, capture_output=True, timeout=15)  # noqa: S603
        except (OSError, subprocess.SubprocessError):
            return None

    def _vnc_feed(self, payload: dict) -> None:
        # One lock acquisition for both: a teardown between two separate reads
        # could otherwise hand us a bridge without its framer (or vice versa).
        with self._vnc_lock:
            bridge = self._vnc
            framer = self._vnc_framer
        if bridge is None or framer is None:
            return
        raw = payload.get("data")
        if not isinstance(raw, str):
            return
        try:
            data = base64.b64decode(raw, validate=True)
        except (ValueError, TypeError):
            return
        # Mirror the outbound MAX_BROWSER_CHUNK ceiling on the way in: a single
        # RFB client message is tiny (pointer 6 B, key 8 B, a big SetEncodings
        # still well under this), so anything larger is malformed. Tear the
        # view down (fail closed): silently dropping it would leave a hole in
        # the stream that the framer later misreports as "not RFB".
        if len(data) > MAX_BROWSER_CHUNK:
            self._vnc_teardown(reason="error", expected=bridge)
            return
        # Enforce "only RFB protocol" on the way in (see _RfbClientFramer): pass
        # framed protocol messages, drop ClientCutText, and on anything that is
        # not RFB tear the view down instead of piping it into x11vnc.
        safe = framer.feed(data)
        if safe is None:
            self._vnc_teardown(reason="error")
            return
        if safe:
            bridge.feed(safe)

    def _vnc_teardown(
        self,
        *,
        reason: str = "stopped",
        notify: bool = True,
        expected: _VncBridge | None = None,
    ) -> None:
        # ``expected``: only tear down if THIS bridge is still the registered
        # one — checked and cleared under a single lock acquisition, so a late
        # close from an already-replaced bridge can never kill its successor.
        with self._vnc_lock:
            bridge = self._vnc
            if expected is not None and bridge is not expected:
                return
            stream_id = self._vnc_stream_id
            self._vnc = None
            self._vnc_stream_id = ""
            self._vnc_framer = None
            # No view is meant to be running any more, so a pipe that closes
            # after this must not try to dial back in.
            self._vnc_route = None
        if bridge is None:
            return
        bridge.close()
        if notify and stream_id:
            self._event(stream_id, browser_view_payload(reason))

    # -- stop (§7.1) -----------------------------------------------------
    def _handle_stop(self, request_id: str, payload: dict) -> None:
        """Fire the kill switch of the run the stop names, and acknowledge it.

        Runs on the serve thread — never on the worker — so it lands while the
        task it aborts is still working.
        """
        targets = self._resolve_stop(payload)
        # Acknowledge BEFORE firing, so the ack cannot lose a race with the very
        # terminal it causes: the run's ``done`` is produced on the worker thread,
        # and a stop that lands mid-turn can end the run before this thread gets
        # back to sending. Both go through one FIFO transport, so ack-then-act
        # gives the app a deterministic order.
        self._terminal(
            request_id, stop_ack_payload([run.request_id for run in targets])
        )
        for run in targets:
            run.kill.interrupt()

    def _resolve_stop(self, payload: dict) -> list[_Run]:
        """The live runs a stop names: by relay request id, else by session key.

        A stop that names neither targets nothing. See :mod:`.protocol` for why
        "stop whatever is running" is not an option.
        """
        target_id = payload.get("request_id")
        if isinstance(target_id, str) and target_id:
            with self._runs_lock:
                run = self._runs.get(target_id)
            return [run] if run is not None else []
        session_key = payload.get("session_key")
        if isinstance(session_key, str) and session_key:
            return [r for r in self._live_runs() if r.session_key == session_key]
        return []

    # -- here.now publish approval (§10-style consent) -------------------
    def _make_approval_gate(
        self, request_id: str, kill: KillSwitch, session_key: str | None = None
    ):
        """Build the here.now approval gate for one task.

        The gate runs on the worker thread inside the publish tool. It emits one
        ``approval_request`` and blocks until the app answers with a matching
        ``approval_decision`` (resolved on the serve thread), a stop fires, or
        the timeout passes. Anything but an explicit approve returns False — the
        publish does not happen.
        """

        def gate(req: PublishRequest) -> bool:
            approval_id = uuid4().hex
            pending = _PendingApproval()
            with self._approvals_lock:
                self._approvals[approval_id] = pending
            payload = approval_request_payload(
                approval_id=approval_id,
                path=req.path,
                name=req.name,
                file_count=req.file_count,
                total_bytes=req.total_bytes,
                base_url=req.base_url,
                public=req.public,
                session_key=session_key,
            )
            # The row first, the frame second (docs/WIRE_CONTRACT.md,
            # cowork-266): a replay must show the request whatever the socket
            # did, and its outcome is patched into this row below.
            pending.mid = self._persist_event(session_key, payload)
            try:
                self._event(request_id, payload)
                # The host may notify a user who is not looking at the app: the
                # run is blocked on them until they answer.
                self._call_hook(
                    self._on_approval_pending,
                    {"approval_id": approval_id, "request_id": request_id},
                )
                deadline = time.monotonic() + APPROVAL_WAIT_SECONDS
                # Poll so a Stop reaches the wait: the loop only checks the kill
                # switch between tool calls, and this call is inside one.
                while True:
                    if kill.interrupted() or kill.estop_engaged():
                        self._close_approval(pending, approved=False, reason=APPROVAL_STOPPED)
                        return False
                    if pending.event.wait(self._poll):
                        return pending.approved
                    if time.monotonic() >= deadline:
                        self._close_approval(pending, approved=False, reason=APPROVAL_TIMEOUT)
                        return False
            finally:
                with self._approvals_lock:
                    self._approvals.pop(approval_id, None)

        return gate

    def _close_approval(
        self, pending: _PendingApproval, *, approved: bool, reason: str
    ) -> None:
        """Patch the outcome into the persisted ``approval_request`` row, once.
        Best effort: a store failure loses the stamp, never the decision."""
        if pending.mid is None or pending.closed:
            return
        pending.closed = True
        try:
            store = StateStore(self._db_path)
            try:
                store.update_event(
                    pending.mid,
                    approval_outcome_fields(
                        approved=approved, reason=reason, at=time.time()
                    ),
                )
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — the run must not die on a stamp
            pass

    # -- persisted stream events (docs/WIRE_CONTRACT.md, cowork-266) ------
    def _persist_event(self, session_key: str | None, payload: dict) -> int | None:
        """Store one live ``subagent`` / ``file`` / ``approval_request`` frame
        as an ``event`` row of the thread, so a replay carries it. Returns the
        row id, or None when nothing was stored (no thread, store failure): the
        live frame still goes out, exactly as before."""
        if not session_key:
            return None
        try:
            store = StateStore(self._db_path)
            try:
                return store.append_event(store.route(session_key), payload)
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — best effort, like _record_run
            return None

    def _emit_persisted(self, request_id: str, session_key: str | None, payload: dict) -> None:
        """Persist, then stream. The row exists even if the socket is gone."""
        self._persist_event(session_key, payload)
        self._event(request_id, payload)

    def _emit_subagent(self, request_id: str, session_key: str, event: dict) -> None:
        """A supervisor event: state changes are persisted (one row each, the
        app keeps one card per child); output chunks stream live only."""
        payload = subagent_payload(event)
        if isinstance(event, dict) and event.get("type") == "subagent_state":
            self._persist_event(session_key, payload)
        self._event(request_id, payload)

    def _resolve_approval(self, payload: dict) -> None:
        """Serve-thread half: record the user's decision and wake the worker."""
        approval_id = payload.get("approval_id")
        if not isinstance(approval_id, str) or not approval_id:
            return
        with self._approvals_lock:
            pending = self._approvals.get(approval_id)
        if pending is None:
            return  # a decision for a publish that already ended: no-op
        pending.approved = bool(payload.get("approved"))
        self._close_approval(pending, approved=pending.approved, reason=APPROVAL_BY_USER)
        pending.event.set()

    # -- secrets (docs/WIRE_CONTRACT.md, "Secrets") ------------------------
    def _handle_secrets(self, payload: dict) -> None:
        """Serve-thread half of the secrets round-trip: replace the vault's set
        with the frame's, then wake every waiting ``request_secrets`` this
        frame answers — by ``request_id``, or because every name it asked for
        is now set. Names and counts are logged; values never."""
        vault = self._secrets
        if vault is None:
            return
        try:
            vault.replace(payload.get("entries"), revision=payload.get("revision"))
        except Exception as exc:  # noqa: BLE001 — a bad frame must not wedge serving
            logger.warning("secrets frame rejected: %s", type(exc).__name__)
            return
        answered = payload.get("request_id")
        have = set(vault.names())
        with self._secret_requests_lock:
            pending = list(self._secret_requests.values())
        for req in pending:
            if req.request_id == answered or all(n in have for n in req.names):
                req.event.set()

    def _flush_pending_secret_requests(self, session_key: str, request_id: str) -> None:
        """Re-send the open ``secret_request``s of ``session_key`` on the
        stream ``request_id`` (a replay), so a reconnecting app sees the
        dialog the run is still blocked on."""
        with self._secret_requests_lock:
            pending = [
                r for r in self._secret_requests.values() if r.session_key == session_key
            ]
        for req in pending:
            self._event(
                request_id,
                secret_request_payload(
                    request_id=req.request_id,
                    session_key=req.session_key,
                    names=req.names,
                    purpose=req.purpose,
                ),
            )

    def _secrets_access(self, request_id: str, kill: KillSwitch, session_key: str):
        """The :class:`chuk_agents_runtime.SecretsAccess` for one task: names and env
        from the vault; ``request`` is the round-trip to the app. Returns
        ``None`` when this executor has no vault, so nothing is registered."""
        vault = self._secrets
        if vault is None:
            return None
        executor = self

        class _Bridge:
            def names(self) -> list[str]:
                return vault.names()

            def env(self) -> dict[str, str]:
                return vault.env()

            def request(self, names: list[str], purpose: str) -> dict[str, str]:
                return executor._request_secrets(
                    request_id, kill, session_key, list(names), purpose
                )

        return _Bridge()

    def _request_secrets(
        self,
        stream_request_id: str,
        kill: KillSwitch,
        session_key: str,
        names: list[str],
        purpose: str,
    ) -> dict[str, str]:
        """Worker-thread half: emit one ``secret_request`` and block until the
        app answers, a stop fires, or the timeout passes. Whatever ends the
        wait, the model gets the vault's status for exactly these names."""
        vault = self._secrets
        assert vault is not None
        req = _PendingSecretRequest(
            request_id=uuid4().hex,
            session_key=session_key,
            names=list(names),
            purpose=purpose,
            stream_request_id=stream_request_id,
        )
        with self._secret_requests_lock:
            self._secret_requests[req.request_id] = req
        try:
            self._event(
                stream_request_id,
                secret_request_payload(
                    request_id=req.request_id,
                    session_key=session_key,
                    names=req.names,
                    purpose=purpose,
                ),
            )
            self._call_hook(
                self._on_secret_request_pending,
                {
                    "request_id": req.request_id,
                    "session_key": session_key,
                    "names": list(req.names),
                    "stream_request_id": stream_request_id,
                },
            )
            deadline = time.monotonic() + SECRET_REQUEST_TIMEOUT
            # Poll so a Stop reaches the wait: the loop only checks the kill
            # switch between tool calls, and this call is inside one.
            while True:
                if kill.interrupted() or kill.estop_engaged():
                    break
                if req.event.wait(self._poll):
                    break
                if time.monotonic() >= deadline:
                    break
        finally:
            with self._secret_requests_lock:
                self._secret_requests.pop(req.request_id, None)
        return vault.status(req.names)

    def _live_runs(self) -> list[_Run]:
        with self._runs_lock:
            return list(self._runs.values())

    def has_live_run(self, session_key: str) -> bool:
        """True while a run of ``session_key`` is queued or in flight."""
        with self._runs_lock:
            return any(r.session_key == session_key for r in self._runs.values())

    def live_request_id(self, session_key: str) -> str | None:
        """The relay request id of the run of ``session_key`` that is in
        flight right now (its stream), or None."""
        with self._mcp_lock:
            return self._mcp_active_request.get(session_key)

    # -- background jobs (docs/WIRE_CONTRACT.md, "Interactive shell ...") --
    def job_finished(self, record: dict) -> str:
        """A ``kind: job`` trigger line from the host's tail (or a swept job).
        Wakes the model; see :class:`chuk_agents_executor.shell.JobWakeRouter`."""
        return self._jobs.finished(record)

    @property
    def jobs(self) -> JobWakeRouter:
        return self._jobs

    def _forget(self, request_id: str) -> None:
        with self._runs_lock:
            self._runs.pop(request_id, None)

    # -- one task --------------------------------------------------------
    def _run_task(self, run: _Run) -> None:
        request_id, prompt, session_key = run.request_id, run.prompt, run.session_key
        # A credential rotation that happens mid-task rides this task's stream.
        with self._mcp_lock:
            self._mcp_active_request[session_key] = request_id
        # The environment's shell hook is NOT the tool stream any more
        # (docs/WIRE_CONTRACT.md, "Tool events and timestamps"): a ``write_file``
        # is one tool card, not the printf/base64 helper commands it runs. The
        # loop's dispatch is the one source — ``tool_event_observer`` below.
        env_shim = self._shim_for(session_key)
        env_shim.on_run = None
        # A task may name the model to run on and how hard it thinks. If it named
        # either and a per-task selector is wired (production), build that model;
        # otherwise fall back to the default factory — which is both the
        # offline/mock path (no select wired, so no backend client is ever built
        # and no credits are spent) and a task that named nothing at all.
        # Everything downstream — the hero ``cheap_clone``, ``set_tools``, the
        # streaming wrapper, the cancel hooks — works off this one base client
        # exactly as before; only where it comes from changed.
        # ``model``, ``provider`` and ``reasoning_effort`` are three independent
        # optional fields (docs/WIRE_CONTRACT.md); any one of them routes the
        # task through the selector.
        if (
            run.model or run.provider or run.reasoning_effort
        ) and self._model_select is not None:
            inner_model = self._model_select(
                run.model, run.provider, run.reasoning_effort
            )
            # The selector may have clamped the level to the model's catalogue
            # (an unsupported level yields no thinking at all). The run's row
            # then proves the effective level, not the request.
            effective = getattr(inner_model, "reasoning_effort", None)
            if (
                run.reasoning_effort
                and isinstance(effective, str)
                and effective != run.reasoning_effort
            ):
                logger.info(
                    "task %s: reasoning_effort %s not supported by the model; "
                    "running with %s",
                    request_id,
                    run.reasoning_effort,
                    effective,
                )
                self._record_run_effort(run, effective)
                run.reasoning_effort = effective
        else:
            inner_model = self._model_factory()
        # What this session runs on, for the app's control panel
        # (docs/WIRE_CONTRACT.md, "Agent status"). Read off the client that was
        # just built — the effective answer even when the task named nothing.
        self._note_model_identity(session_key, inner_model)
        # The browser fallback (§8) gets its own client: the loop's client is
        # wrapped to stream deltas into the chat, and a browser step's per-step
        # JSON has no business there. Built here, not inline, so the ``finally``
        # below can close it — a per-task backend client owns a socket and a
        # reader thread, and one leaked per task adds up on a long-running host.
        browser_client = self._model_factory()
        model = StreamingModelClient(
            inner_model,
            on_delta=lambda text: self._event(request_id, delta_payload(text)),
            on_reasoning=lambda text: self._event(
                request_id, reasoning_payload(text)
            ),
        )

        # The "hero"/aux model (§7.3): the SAME model on the SAME session, reasoning
        # off, small output cap. It runs tier-2/3 context compaction AND the mem0
        # fact-extraction, so both housekeeping jobs default to the cheap same-model
        # instead of the frontier client. A backend client can clone itself; the
        # mock (tests) cannot, so this is best-effort — no clone, no aux, tier-1
        # only. It owns its own socket, closed in the ``finally`` below so it never
        # leaks past the task.
        cheap_clone = getattr(inner_model, "cheap_clone", None)
        hero_model = cheap_clone() if callable(cheap_clone) else None

        # "Cancels in-flight" (§7.1): a Stop kills the command the sandbox is
        # blocked on and the model turn in flight, instead of ending the run only
        # after they return on their own. Registered on this task's switch, so the
        # listeners die with the task.
        run.kill.on_interrupt(env_shim.cancel)
        cancel_model = getattr(inner_model, "cancel", None)
        if callable(cancel_model):
            run.kill.on_interrupt(cancel_model)
        # A Stop mid-compaction/extraction must abort the hero's socket too, or it
        # would wait out the aux call instead of stopping at once.
        if hero_model is not None:
            cancel_hero = getattr(hero_model, "cancel", None)
            if callable(cancel_hero):
                run.kill.on_interrupt(cancel_hero)

        # The forwarded MCP servers (§9, §10), built into a per-session manager
        # with the right bearer attached. Best-effort: any failure here leaves
        # ``mcp_manager`` None and the task runs without those tools, never
        # crashing. ``None`` keeps ``build_runtime``'s own workspace ``mcp.json``
        # path (``enable_mcp``) exactly as it was.
        # Merge the always-on Playwright MCP (§9.1, browser image only) with the
        # UI-forwarded connectors. Appended, so a user's own server of another
        # name is untouched; on the base image `_browser_mcp_entry` is None.
        servers = list(run.mcp_servers or [])
        browser_entry = self._browser_mcp_entry(session_key)
        if browser_entry is not None:
            servers.append(browser_entry)
        mcp_manager = self._session_mcp_manager(session_key, servers or None)
        if mcp_manager is None and run.origin == "automation":
            # A fired automation carries no forwarded connectors (no frame,
            # no app). It runs with the connectors the session already has,
            # exactly as the last task of that session did.
            with self._mcp_lock:
                mcp_manager = self._mcp_managers.get(session_key)
        # Anything the device has not acknowledged yet (a rotated refresh token
        # from an earlier task) goes out again on this task's stream.
        self._flush_pending_mcp_credentials(session_key, request_id)
        # What those connectors answered with, so the app's list can stop saying
        # "0 tools" about servers that are up (docs/WIRE_CONTRACT.md mcp_tools).
        self._send_mcp_tools(session_key, request_id, mcp_manager)

        # here.now publish connector (§10-style consent): off unless the app
        # forwarded an enabled setting. ``ask`` mode binds the approval gate so a
        # public publish blocks on the user; ``auto`` publishes straight through.
        herenow_config = HereNowConfig.from_entry(run.herenow) if run.herenow else None
        herenow_gate = (
            self._make_approval_gate(request_id, run.kill, session_key)
            if herenow_config is not None and herenow_config.enabled and herenow_config.asks
            else None
        )

        # The debug "copy raw context" tap: only wired when the task asked for it,
        # so a normal run builds and streams nothing. Each round's exact outbound
        # payload and the ladder's stats go out as one sealed ``debug_context``
        # event on the same channel as the deltas.
        debug_observer = None
        if run.debug:
            def debug_observer(dbg: dict) -> None:
                self._event(
                    request_id,
                    debug_context_payload(
                        session_key=str(dbg.get("session_key", "")),
                        round=int(dbg.get("round", 0)),
                        messages=list(dbg.get("messages", [])),
                        stats=dict(dbg.get("stats", {})),
                    ),
                )

        # The user's secrets for this task (docs/WIRE_CONTRACT.md, "Secrets"):
        # env for the child processes, the two tools, the dispatch scrubber.
        # Children get the same access through the subagent config below.
        secrets_access = self._secrets_access(request_id, run.kill, session_key)
        subagents = self._subagent_config(request_id, session_key, secrets_access)
        loop = build_runtime(
            model,
            session=(self._account_session_provider()
                     if self._account_session_provider is not None else None),
            db_path=self._db_path,
            environment=env_shim,
            max_iterations=self._max_iterations,
            system_prompt=self._system_prompt,
            workspace=self._workspace_for(session_key),
            subagents=subagents,
            herenow_config=herenow_config,
            herenow_gate=herenow_gate,
            # This session's automation tools (docs/WIRE_CONTRACT.md,
            # "Automations"): bound to ``session_key`` here, so the model can
            # only ever name its own schedules and watchers.
            automations=(
                self._automations.bound(session_key)
                if self._automations is not None
                else None
            ),
            # The hero/aux client (§7.3): same model, reasoning off, cheap. Enables
            # tier-2/3 compaction and mem0 extraction by default in production.
            # ``None`` (mock model) keeps tier-1-only behaviour.
            aux_model=hero_model,
            # Off unless the task set ``debug``; ``None`` means zero overhead.
            debug_observer=debug_observer,
            # One ``tool`` frame per native tool call, after its result, with the
            # same fields a replay rebuilds (name, arguments, result, status,
            # started_at / completed_at).
            tool_event_observer=lambda fields: self._on_tool_event(
                request_id, session_key, fields
            ),
            secrets=secrets_access,
            # Background jobs (docs/WIRE_CONTRACT.md, "Interactive shell and
            # background commands"): the session a job's end is routed to, and
            # the provider that hands a finished job's output to this turn.
            shell_session_key=session_key,
            context_providers=[self._jobs.provider(session_key)],
            # A prepared manager the executor owns and closes on stop. When None,
            # build_runtime falls back to reading the workspace mcp.json itself.
            mcp=mcp_manager,
            # One switch per task, owned by the executor: the run registry fires
            # it when a stop names this task, and ``build_runtime`` hands the same
            # switch to the subagent supervisor, so one Stop reaches the tree.
            kill_switch=run.kill,
            # `send_file_to_user` (§9): the agent hands over the bytes, this
            # turns them into one sealed `file` event on the same stream as the
            # deltas. A file too large to send raises here, the agent tool
            # catches it, and the model is told — the channel is never flooded.
            file_sink=lambda sent: self._emit_persisted(
                request_id,
                session_key,
                file_payload(
                    name=sent.name, mime_type=sent.mime_type, data=sent.data,
                    document=sent.document,
                ),
            ),
            media_mount=self._media_mount,
            # The browser fallback (§8) spends its rounds on a SEPARATE client:
            # `model` above is wrapped to stream deltas into the chat, and a
            # browser session's per-step JSON has no place in the thread. A fresh
            # factory client is lazy — it opens no socket unless `browser_task`
            # actually runs, which itself needs a Chromium in the sandbox
            # (`check_fn`), so this stays out of the prompt on the browser-free
            # base image and costs nothing there.
            browser_model=browser_client,
        )

        # The wall-clock guard (Bead cowork-qxa): armed for the loop's lifetime
        # only; cancelled in the ``finally`` below whatever way the run ends.
        guard = self._arm_run_guard(run)
        # The heartbeat rides the same lifetime, for the opposite reason: the
        # guard bounds a run that runs too long, this one proves to the app that
        # a run which LOOKS stalled is working. Armed here, so it can only ever
        # beat for a run that is running.
        heartbeat = self._arm_heartbeat(run)
        try:
            # The run trace's identity (chuk_agents_runtime.trace): every line the
            # loop and the model client write inside this block carries this run
            # id and session key, so `cowork-host trace <run id>` can rebuild the
            # whole waterfall. A fresh thread starts with a fresh context, so two
            # concurrent runs never see each other's scope. Costs nothing when
            # tracing is off — it sets one ContextVar.
            self._bind_trace_scrubber()
            with trace_run_scope(run.run_id or run.request_id, session_key):
                result = loop.run(session_key, prompt, regenerate=run.regenerate)
        except Exception as exc:  # a crashing loop must not kill the serve thread
            message = f"loop failed: {type(exc).__name__}"
            # The durable record closes BEFORE the stream: it must exist even if
            # nobody is listening (docs/WIRE_CONTRACT.md).
            self._record_run(run, failed=message)
            self._terminal(request_id, error_payload(message))
            # The run is over once its terminal went out: drop it from the
            # registry now, so a replay that races the hook below reports idle.
            self._forget(request_id)
            self._call_hook(
                self._on_run_finished,
                self._run_summary(run, reason="failed", final_answer=None, error=message),
            )
            return
        finally:
            if guard is not None:
                guard.cancel()
            # Before the terminal below: the last beat must not outlive the run.
            if heartbeat is not None:
                heartbeat.cancel()
            env_shim.on_run = None
            # Children outlive the parent's turn otherwise: a leaked child keeps a
            # container and a model stream alive with nobody reading either.
            if subagents is not None and subagents.supervisor is not None:
                # Guarded like the client closes below: a raising teardown here
                # would discard the `return` of the except above and reach _work's
                # handler — a SECOND terminal, a second failed record and a second
                # notification for the same task.
                try:
                    subagents.supervisor.shutdown()
                except Exception:  # noqa: BLE001 — cleanup must not mask a result
                    pass
            # This task's stream is closing; a rotation after this point waits
            # as pending for the next task start or replay.
            with self._mcp_lock:
                if self._mcp_active_request.get(session_key) == request_id:
                    self._mcp_active_request.pop(session_key, None)
            # Release every per-task client. Backend clients return only fully
            # drained sockets to the bounded idle pool; interrupted/error
            # streams close immediately. Other clients close as before.
            for client in (hero_model, inner_model, browser_client):
                close = getattr(client, "close", None) if client is not None else None
                if callable(close):
                    try:
                        close()
                    except Exception:  # noqa: BLE001 — cleanup must not mask a result
                        pass

        # The guard fired and the loop stopped for it: that is a timeout, not the
        # user's stop. Anything else the loop reports stands as it is.
        reason = (
            RUN_TIMEOUT_REASON
            if run.timed_out and result.reason is StopReason.INTERRUPTED
            else result.reason.value
        )
        # The durable record closes BEFORE the stream, so the run's end exists on
        # the host even when the app is gone and the frame is dropped. The
        # closed row also stamps the done (clock + message rows).
        run_stamps = self._record_run(run, result=result, reason=reason)
        # The finished turn lands in <workspace>/transcript/ (read-only, the
        # agent's long-term search) before the app hears ``done``.
        self._export_transcript(session_key)
        # The control panel's figures, on the stream that is still open (a
        # terminal closes it). The run row is already closed above, so this
        # status counts the turn the user just watched.
        self._push_agent_status(request_id, session_key)
        self._terminal(
            request_id,
            done_payload(
                final_answer=result.final_answer,
                reason=reason,
                iterations=result.iterations,
                tokens_spent=result.tokens_spent,
                run_id=run.run_id,
                run_stamps=run_stamps,
                # A fired automation / job is notified on by the host itself.
                host_notified=run.origin in ("automation", "job"),
                session_key=session_key,
            ),
        )
        # The run is over once its terminal went out: drop it from the registry
        # before the hook, so a replay arriving while a notifier runs reports
        # idle. ``_work``'s own ``_forget`` is idempotent.
        self._forget(request_id)
        self._call_hook(
            self._on_run_finished,
            self._run_summary(
                run,
                reason=reason,
                final_answer=result.final_answer,
                iterations=result.iterations,
                tokens_spent=result.tokens_spent,
            ),
        )

    # -- run heartbeat (protocol.heartbeat_payload) ------------------------
    def _arm_heartbeat(self, run: _Run) -> "_Heartbeat | None":
        """Start this run's ``heartbeat`` emitter, or ``None`` when it is off.

        One small sealed frame every :attr:`_heartbeat_seconds` on the run's own
        relay request, from here until the ``finally`` in :meth:`_run_task`
        cancels it. It is the only frame that says "still running" while the
        model reads a long prompt or a command works, and it is never persisted
        — a replay carries transcript, not liveness.
        """
        interval = self._heartbeat_seconds
        if not interval or interval <= 0:
            return None
        stop = threading.Event()
        started = time.monotonic()

        def beat() -> None:
            seq = 0
            while not stop.wait(interval):
                seq += 1
                try:
                    self._event(
                        run.request_id,
                        heartbeat_payload(
                            run_id=run.run_id,
                            session_key=run.session_key,
                            seq=seq,
                            elapsed=time.monotonic() - started,
                        ),
                    )
                except Exception:  # noqa: BLE001 — a dead socket ends the beat,
                    return  # never the run

        thread = threading.Thread(
            target=beat, name=f"heartbeat-{run.request_id}", daemon=True
        )
        thread.start()
        return _Heartbeat(thread, stop)

    # -- wall-clock guard (Bead cowork-qxa) --------------------------------
    def _arm_run_guard(self, run: _Run) -> threading.Timer | None:
        """Start the run's wall-clock timer, or ``None`` when the guard is off."""
        limit = self._run_max_seconds
        if not limit or limit <= 0:
            return None
        timer = threading.Timer(limit, self._on_run_guard, args=(run,))
        timer.daemon = True
        timer.start()
        return timer

    def _on_run_guard(self, run: _Run) -> None:
        """The run outlived its wall-clock budget: stop it the way a user's stop
        does (kill switch -> the model call is cancelled, the loop ends at its
        next poll). ``timed_out`` turns the resulting ``interrupted`` into
        ``timeout`` when the run closes."""
        run.timed_out = True
        logger.warning(
            "task %s: run exceeded %.0fs wall clock; stopping it",
            run.request_id,
            self._run_max_seconds,
        )
        try:
            run.kill.interrupt()
        except Exception:  # noqa: BLE001 — the guard must never take the worker down
            pass

    # -- transcript export (the agent's long-term search) ----------------
    def _on_tool_event(self, request_id: str, session_key: str, fields: dict) -> None:
        """One finished native tool call: the wire frame to the app, then the
        transcript file catches up with the store (best-effort). A Playwright
        browser tool first updates the browser state, so a `browser_view`
        opened/closed lands before the tool frame it came from."""
        state = browser_state_from_tool(
            fields.get("name"), fields.get("arguments"), fields.get("status")
        )
        if state is not None:
            self._set_browser_open(state, request_id, session_key)
        self._event(request_id, tool_payload(**fields))
        self._export_transcript(session_key)

    def _export_transcript(self, session_key: str) -> None:
        """Append what the store holds since the last export to
        ``<workspace>/transcript/<thread>.md`` (:mod:`chuk_agents_runtime.transcript_export`).
        No workspace, no export. Never raises: the transcript is a convenience
        for the agent, the run's result must not depend on it."""
        if not self._workspace:
            return
        try:
            exporter = self._transcript_exporter
        except AttributeError:
            exporter = None
        if exporter is None:
            try:
                # The exporter's own credential-shape redaction, plus the
                # vault's exact-value masks (docs/WIRE_CONTRACT.md, "Secrets"):
                # the transcript is a file the agent can read back.
                exporter = TranscriptExporter(
                    self._workspace,
                    scrub=lambda text: self._scrub_text(redact_secrets(text)),
                )
            except Exception:  # noqa: BLE001 — an unwritable workspace: no export
                return
            self._transcript_exporter = exporter
        try:
            store = StateStore(self._db_path)
            try:
                exporter.export(store, session_key)
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — bookkeeping must not mask a result
            logger.debug("transcript export failed for %s", session_key, exc_info=True)

    # -- run records (docs/WIRE_CONTRACT.md) -----------------------------
    def _record_run_effort(self, run: _Run, effort: str) -> None:
        """Best-effort: write the clamped ``reasoning_effort`` onto the run's
        row. A store failure loses the note, never the run."""
        if not run.run_id:
            return
        try:
            store = StateStore(self._db_path)
            try:
                store.update_run_reasoning_effort(run.run_id, effort)
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — bookkeeping must not mask a result
            pass

    def _record_run(
        self,
        run: _Run,
        *,
        result=None,
        failed: str | None = None,
        reason: str | None = None,
    ) -> dict[str, Any]:
        """Close the run's ``runs`` row. Best-effort: a store failure loses the
        record, never the result the app is about to receive. Returns the closed
        row's stamps (``started_at`` / ``finished_at`` / ``first_mid`` /
        ``last_mid``) for the ``done`` frame — empty when nothing was recorded."""
        if not run.run_id:
            return {}
        try:
            store = StateStore(self._db_path)
            try:
                if failed is not None:
                    store.fail_run(run.run_id, reason=failed)
                elif result is not None:
                    store.finish_run(
                        run.run_id,
                        reason=reason or result.reason.value,
                        # Masked before it is a row; the ``done`` frame is masked
                        # again by the sealer.
                        final_answer=self._scrub_text(result.final_answer),
                        iterations=result.iterations,
                        tokens_spent=result.tokens_spent,
                        # Where the wall clock went, so a slow run is diagnosable
                        # from its row instead of from message timestamps.
                        timings=getattr(result, "timings", None)
                        and result.timings.as_row(),
                    )
                return run_stamp_fields(store.get_run(run.run_id))
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — bookkeeping must not mask a result
            return {}

    @staticmethod
    def _run_summary(
        run: _Run,
        *,
        reason: str,
        final_answer: str | None,
        iterations: int = 0,
        tokens_spent: int = 0,
        error: str | None = None,
    ) -> dict:
        """What the host's ``on_run_finished`` hook receives. No transcript: the
        host decides whether and how to notify; content stays in the store."""
        return {
            "run_id": run.run_id,
            "session_key": run.session_key,
            "request_id": run.request_id,
            "prompt": run.prompt,
            "reason": reason,
            "has_answer": bool(final_answer),
            "final_answer": final_answer,
            "iterations": iterations,
            "tokens_spent": tokens_spent,
            "error": error,
            "started_at": run.started_at,
            "finished_at": time.time(),
            # docs/WIRE_CONTRACT.md, "Automations": who started the run.
            "origin": run.origin,
            "automation_id": run.automation_id,
        }

    # -- MCP credential forwarding (§9, §10) -----------------------------
    def _forget_session_mcp(self, *, close: bool, session_key: str) -> None:
        """Drop everything cached for this session's MCP connectors.

        ``close`` also shuts the cached manager down (it joins transport threads
        and stops any stdio subprocess), which is what an empty ``mcp_servers``
        list needs: the connectors it spoke for are gone. A caller that already
        closed the manager itself passes ``close=False``.

        Never raises — shutdown must not take a task down with it.
        """
        with self._mcp_lock:
            manager = self._mcp_managers.pop(session_key, None)
            self._mcp_signatures.pop(session_key, None)
            self._mcp_refresh_baseline.pop(session_key, None)
            self._mcp_refresh_seen.pop(session_key, None)
            self._mcp_entry_meta.pop(session_key, None)
            self._mcp_pending_credentials.pop(session_key, None)
        if close and manager is not None:
            try:
                manager.close()
            except Exception:  # noqa: BLE001 — shutdown must not raise
                pass

    def _session_mcp_manager(
        self, session_key: str, mcp_servers: list[dict] | None
    ) -> MCPManager | None:
        """Get or build this session's MCPManager from the forwarded servers.

        The manager is cached per session and reused across the session's tasks,
        so the transport threads and any subprocesses live once, not per task.
        A new task whose ``mcp_servers`` differ from what built the cached manager
        rebuilds it (the UI changed the connections); an identical list reuses it.

        Best-effort by contract: a bad entry is skipped inside
        :func:`configs_from_entries`, an unreachable server is skipped inside
        ``MCPManager.start`` (via ``register_mcp_tools`` in ``build_runtime``),
        and any unexpected error here is swallowed so the task still runs — just
        without those tools. Returns ``None`` when nothing was forwarded.
        """
        if not mcp_servers:
            # The user disconnected the last connector (or a chuk_chat row went
            # away). A manager cached from an earlier task of this session holds
            # live transport threads and, for a stdio server, a subprocess: drop
            # it here rather than let it outlive the connectors it speaks for.
            self._forget_session_mcp(close=True, session_key=session_key)
            return None
        # Redacted projection: a rotated access/refresh token or a new expiry is
        # NOT a changed connector and must reuse the cached manager.
        signature = _mcp_signature(mcp_servers)
        with self._mcp_lock:
            existing = self._mcp_managers.get(session_key)
            hit = (
                existing is not None
                and self._mcp_signatures.get(session_key) == signature
            )
            stale = existing if (existing is not None and not hit) else None
        if hit:
            # Same connectors, possibly fresher credentials: the signature
            # ignores the rotating fields on purpose, so carry them into the
            # cached configs or the device's newer bearer would be ignored and
            # every connector would pay a refresh round-trip it did not need.
            self._adopt_rotating_credentials(session_key, existing, mcp_servers)
            return existing
        # Close a superseded manager outside the lock — close() joins threads.
        if stale is not None:
            try:
                stale.close()
            except Exception:  # noqa: BLE001 — shutdown must not raise
                pass
        try:
            account_token = (
                self._account_token_provider()
                if self._account_token_provider is not None
                else None
            )
            configs, errors = configs_from_entries(
                mcp_servers, account_token=account_token
            )
            if not configs:
                # Nothing usable was forwarded: record why (bad entries) and run
                # without MCP rather than caching an empty manager per signature.
                # The stale manager, if there was one, was already closed above.
                self._forget_session_mcp(close=False, session_key=session_key)
                return None
            manager = MCPManager(
                configs,
                errors=errors,
                # Fires from refresh_token() after its lock is released, only
                # when the provider issued a DIFFERENT refresh token: the
                # back-channel that brings a rotated token home (mcp_credentials).
                on_credentials_rotated=self._mcp_rotation_listener(session_key),
            )
            with self._mcp_lock:
                self._mcp_entry_meta[session_key] = _entry_meta(mcp_servers)
        except Exception:  # noqa: BLE001 — building MCP must never crash a task
            return None
        with self._mcp_lock:
            self._mcp_managers[session_key] = manager
            self._mcp_signatures[session_key] = signature
            baseline: dict[str, str | None] = {}
            seen: dict[str, set[str]] = {}
            for c in configs:
                rt = (c.oauth or {}).get("refresh_token")
                baseline[c.name] = rt
                seen[c.name] = {rt} if rt else set()
            self._mcp_refresh_baseline[session_key] = baseline
            self._mcp_refresh_seen[session_key] = seen
        return manager

    def _adopt_rotating_credentials(
        self, session_key: str, manager: MCPManager, mcp_servers: list[dict]
    ) -> None:
        """On a cache hit, MERGE the incoming credentials into the cached configs
        (bead cowork-lwc, tightened after 47's review).

        ``_mcp_signature`` drops ``access_token``, ``oauth.refresh_token`` and
        ``oauth.expires_at``, so a hit means "same connectors", not "same tokens".
        The device forwards what IT holds. That is usually fresh — but not the
        truth once the host has refreshed a connector itself: providers that
        rotate refresh tokens (Google, Okta, Auth0) issue a NEW one and kill the
        old, and the device still holds the old. Replacing the block wholesale
        would put the dead token back, and every later refresh would fail with
        ``invalid_grant`` — the connector dies for good. Hence a merge:

        - identity fields (token_endpoint, client_id, client_secret, resource,
          scope, issuer) are always taken from the device;
        - ``refresh_token`` / ``expires_at`` are taken ONLY when the device sends
          a refresh token it has NEVER sent before (``_mcp_refresh_seen``) — the
          user signed in again on the device, or the device is handing the host's
          own rotated token back. That token becomes the device's current grant
          (``_mcp_refresh_baseline``). A token seen before is a replay of an old
          payload and changes nothing;
        - ``access_token`` follows the same rule, plus: while the host has not
          rotated anything AND the payload belongs to the current grant, a
          fresher device bearer (and expiry) is welcome.

        The write happens under the connection's refresh lock, so it cannot
        interleave with a ``refresh_token()`` in flight. The config is read when
        the transport is (re)built and inside ``refresh_token()``; the headers of
        an already-open transport were frozen at connect, so an adopted bearer
        takes effect at the next (re)connect or refresh, not mid-flight. Only
        present values are adopted; best-effort — never fails the task.
        """
        try:
            account_token = (
                self._account_token_provider()
                if self._account_token_provider is not None
                else None
            )
            fresh, _errors = configs_from_entries(mcp_servers, account_token=account_token)
        except Exception:  # noqa: BLE001 — a bad list must not fail a task that has a manager
            return
        by_name = {config.name: config for config in fresh}
        with self._mcp_lock:
            baseline = self._mcp_refresh_baseline.setdefault(session_key, {})
            seen_by_name = self._mcp_refresh_seen.setdefault(session_key, {})
            # The device may have renamed/re-identified; keep the echo current.
            self._mcp_entry_meta[session_key] = _entry_meta(mcp_servers)
            pending = self._mcp_pending_credentials.setdefault(session_key, {})
        for config in manager.configs:
            incoming = by_name.get(config.name)
            if incoming is None:
                continue
            incoming_oauth = incoming.oauth or {}
            connection = manager.connections.get(config.name)
            lock = getattr(connection, "_refresh_lock", None)
            with lock if lock is not None else nullcontext():
                current_oauth = config.oauth or {}
                seen = seen_by_name.setdefault(config.name, set())
                device_grant = baseline.get(config.name)  # the device's current grant
                host_current = current_oauth.get("refresh_token")
                incoming_rt = incoming_oauth.get("refresh_token")
                # Never seen from this device -> a re-sign-in (or the host's own
                # rotated token handed back). Seen before -> a stale replay.
                device_reauth = bool(incoming_rt) and incoming_rt not in seen
                host_rotated = host_current is not None and host_current != device_grant
                same_grant = not incoming_rt or incoming_rt == device_grant

                merged = dict(current_oauth)
                for key, value in incoming_oauth.items():
                    if key not in _ROTATING_OAUTH:
                        merged[key] = value  # identity fields: device is authoritative
                if device_reauth:
                    for key in _ROTATING_OAUTH:
                        if key in incoming_oauth:
                            merged[key] = incoming_oauth[key]
                    with self._mcp_lock:
                        baseline[config.name] = incoming_rt
                        seen.add(incoming_rt)
                        # Either the device hands the host's rotated token back
                        # (the ack) or it re-signed-in and the pending frame is
                        # obsolete. Both stop the re-send.
                        pending.pop(config.name, None)
                    if incoming.auth_token:
                        config.auth_token = incoming.auth_token
                elif not host_rotated and same_grant:
                    if "expires_at" in incoming_oauth:
                        merged["expires_at"] = incoming_oauth["expires_at"]
                    if incoming.auth_token:
                        config.auth_token = incoming.auth_token
                # else: the host rotated (device stale) or the payload belongs to
                # an older grant — keep the host's refresh_token / expires_at /
                # access_token untouched.
                if merged != current_oauth:
                    config.oauth = merged

    def _mcp_rotation_listener(self, session_key: str):
        """The ``on_credentials_rotated`` hook for this session's MCPManager.

        ``refresh_token()`` calls it AFTER releasing its lock, only when the
        provider issued a different refresh token (a rotation), with the config
        already updated. The listener builds the ``mcp_credentials`` frame
        (docs/WIRE_CONTRACT.md) from the config plus the device's own identity
        echo, sends it at once on the running task's stream, and parks it as
        pending so it is re-sent at every task start and replay until the device
        forwards the rotated token back. Never raises into the tool call.
        """

        def listener(name: str, config) -> None:
            try:
                with self._mcp_lock:
                    meta = self._mcp_entry_meta.get(session_key, {}).get(name, {})
                payload = mcp_credentials_payload(
                    session_key=session_key,
                    connector_id=meta.get("id"),
                    name=str(meta.get("name") or name),
                    url=str(meta.get("url") or getattr(config, "url", "") or ""),
                    access_token=getattr(config, "auth_token", None),
                    oauth=dict(getattr(config, "oauth", None) or {}),
                )
                with self._mcp_lock:
                    self._mcp_pending_credentials.setdefault(session_key, {})[name] = payload
                    request_id = self._mcp_active_request.get(session_key)
                if request_id:
                    self._event(request_id, payload)
            except Exception:  # noqa: BLE001 — a relay problem must not kill a tool call
                pass

        return listener

    def _send_mcp_tools(
        self, session_key: str, request_id: str, manager: object | None
    ) -> None:
        """Tell the app what each connector answered with.

        The device cannot know: it forwards the connectors and the host dials
        them. Without this the connector list shows "0 tools" next to a server
        that is connected and working (and the user has no way to tell that
        apart from one that is broken). Sent once per task, after the manager is
        up — that is the moment the answer exists.

        Best-effort in every direction: no manager, no frame; a server that
        failed is reported with its error instead of being left out, because
        "tried and refused" is the thing worth showing.
        """
        servers = self._mcp_tools_servers(session_key, manager)
        if not servers:
            return
        try:
            self._event(
                request_id,
                mcp_tools_payload(session_key=session_key, servers=servers),
            )
        except Exception:  # noqa: BLE001 — a relay problem must not kill the task
            pass

    def _mcp_tools_servers(self, session_key: str, manager: object | None) -> list[dict]:
        """One entry per connector of [manager]: what it answered with.

        Shared by the task path (an event on the running stream) and the probe
        path (a terminal on its own request), so the two can never describe the
        same connector differently.
        """
        if manager is None:
            return []
        try:
            connections = dict(getattr(manager, "connections", {}) or {})
        except Exception:  # noqa: BLE001
            return []
        if not connections:
            return []
        with self._mcp_lock:
            meta = dict(self._mcp_entry_meta.get(session_key, {}))
        servers: list[dict] = []
        for name, connection in connections.items():
            entry = meta.get(name, {})
            try:
                tools = list(getattr(connection, "tools", []) or [])
            except Exception:  # noqa: BLE001
                tools = []
            error = getattr(connection, "error", None)
            servers.append(
                {
                    "id": entry.get("id"),
                    "name": str(entry.get("name") or name),
                    "url": str(entry.get("url") or ""),
                    "connected": not error and bool(tools),
                    "tools": [
                        {
                            "name": str(getattr(tool, "name", "") or ""),
                            "description": str(getattr(tool, "description", "") or ""),
                        }
                        for tool in tools
                    ],
                    **({"error": str(error)} if error else {}),
                }
            )
        return servers

    def _handle_mcp_probe(self, request_id: str, payload: dict) -> None:
        """Dial the forwarded connectors now and answer with what they hold.

        The app signs in to an MCP server itself (an OAuth consent screen needs
        a person), but it never speaks MCP: this host does. Without this frame
        the app could only learn a connector's tools as a side effect of running
        a task, so a freshly connected server sat in the list saying "0 tools"
        until the user happened to ask the coworker something.

        Answered with one terminal ``mcp_tools`` frame, the way a skills list is.
        The dial runs on its own thread: a server that is down costs a full
        connect timeout, and the frame loop must not wait for it.
        """
        servers = payload.get("mcp_servers")
        if not isinstance(servers, list) or not servers:
            self._terminal(
                request_id, mcp_tools_payload(session_key="", servers=[])
            )
            return
        session_key = str(payload.get("session_key") or "") or "mcp-probe"

        def work() -> None:
            try:
                manager = self._session_mcp_manager(session_key, servers)
                if manager is None:
                    self._terminal(
                        request_id,
                        mcp_tools_payload(session_key=session_key, servers=[]),
                    )
                    return
                try:
                    manager.start()
                except Exception:  # noqa: BLE001 — report what did answer
                    pass
                self._terminal(
                    request_id,
                    mcp_tools_payload(
                        session_key=session_key,
                        servers=self._mcp_tools_servers(session_key, manager),
                    ),
                )
            except Exception as exc:  # noqa: BLE001 — never kill the serve loop
                try:
                    self._terminal(
                        request_id,
                        error_payload(f"mcp probe failed: {type(exc).__name__}"),
                    )
                except Exception:  # noqa: BLE001
                    pass

        threading.Thread(
            target=work, name=f"mcp-probe-{request_id[:8]}", daemon=True
        ).start()

    def _flush_pending_mcp_credentials(self, session_key: str, request_id: str) -> None:
        """Re-send every unacknowledged ``mcp_credentials`` frame of this session
        on ``request_id`` (a task start or a replay). Idempotent for the app —
        last one wins — and it stops on its own once the device forwards the
        rotated token back (see ``_adopt_rotating_credentials``)."""
        with self._mcp_lock:
            payloads = list(self._mcp_pending_credentials.get(session_key, {}).values())
        for payload in payloads:
            try:
                self._event(request_id, payload)
            except Exception:  # noqa: BLE001 — best-effort
                pass

    def _close_mcp_managers(self) -> None:
        with self._mcp_lock:
            managers = list(self._mcp_managers.values())
            self._mcp_managers.clear()
            self._mcp_signatures.clear()
            self._mcp_refresh_baseline.clear()
            self._mcp_refresh_seen.clear()
            self._mcp_entry_meta.clear()
            self._mcp_pending_credentials.clear()
            self._mcp_active_request.clear()
        for manager in managers:
            try:
                manager.close()
            except Exception:  # noqa: BLE001 — shutdown must not raise
                pass

    # -- subagents (§7.6) ------------------------------------------------
    def _subagent_config(
        self, request_id: str, session_key: str, secrets_access=None
    ) -> SubagentConfig | None:
        """Build the child wiring for one task, or ``None`` when subagents are off.

        The environment factory is the isolation guarantee: it is keyed by the
        child's task id and goes through the same sandbox factory the parent's
        container came from, so "one child = one sandbox" holds locally and in
        the container backend without a second code path.
        """
        if self._subagent_sandbox is None:
            return None
        kind = self._subagent_sandbox
        options = self._subagent_sandbox_options

        def env_factory(task_id: str) -> BaseEnvironment:
            opts = dict(options)
            if kind == "docker":
                opts.setdefault("session_id", task_id)
            return make_environment(kind, **opts)

        config = SubagentConfig(
            model_factory=self._model_factory,
            env_factory=env_factory,
            task_id=session_key,
            system_prompt=self._system_prompt,
            on_event=lambda event: self._emit_subagent(request_id, session_key, event),
            # A child gets the same secrets seam as its parent: env for its
            # commands, the tools, and the dispatch scrubber — so a child's
            # output cannot carry a value up to the parent's context.
            runtime_kwargs=(
                {
                    **({"secrets": secrets_access} if secrets_access is not None else {}),
                    "session": (self._account_session_provider()
                                if self._account_session_provider is not None else None),
                }
            ),
        )
        if self._subagent_limits is not None:
            config.limits = self._subagent_limits
        return config

    def _bind_trace_scrubber(self) -> None:
        """Hand the run tracer this executor's secret scrubber.

        Content tracing is inert until a scrubber is wired — that is the safe
        default, and it is why the tracer is built by the CLI long before any
        vault exists. Structure-only tracing needs nothing from here.
        """
        tracer = get_tracer()
        setter = getattr(tracer, "set_scrubber", None)
        if setter is not None:
            setter(self._scrub_text)

    def _scrub_text(self, text):
        """Mask secret values in one text bound for a store row or a host
        hook. Non-strings pass through; no vault, no change."""
        scrubber = self._secret_scrubber
        if scrubber is None or not isinstance(text, str):
            return text
        return scrubber.scrub_text(text)

    # -- outbound (all sealed) -------------------------------------------
    def _seal_b64(self, payload: dict) -> str:
        # The second of the two scrubber chokepoints (docs/WIRE_CONTRACT.md,
        # "Secrets"): EVERYTHING that goes to the app — events, terminals,
        # replays — passes here. Raw RFB bytes (browser_data) are not text and
        # are left alone; every other frame has its strings masked.
        scrubber = self._secret_scrubber
        if scrubber is not None and payload.get("type") != "browser_data":
            payload = scrubber.scrub_obj(payload)
        with self._codec_lock:
            sealer = self._sealer
        return frame_to_b64(sealer.seal(encode_payload(payload)).to_bytes())

    def _event(self, request_id: str, payload: dict) -> None:
        """Stream a progress event as a relay notification carrying a sealed frame."""
        with self._emit_lock:
            envelope = make_request(
                METHOD_EVENT,
                {"requestId": request_id, "frame": self._seal_b64(payload)},
            )
            self._endpoint.send(encode_frame(envelope))

    def _terminal(self, request_id: str, payload: dict) -> None:
        """Close the stream with a relay response correlated to the task."""
        with self._emit_lock:
            envelope = make_response(request_id, {"frame": self._seal_b64(payload)})
            self._endpoint.send(encode_frame(envelope))
