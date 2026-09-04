"""The Executor (task 2).

Composes the agent loop, a real sandbox, and CoWork frame crypto into one unit
that:

1. receives an **encrypted** ``run_task`` frame off its transport endpoint,
2. opens it with a :class:`~cowork_crypto.CoworkFrameOpener` (default deny —
   only approved devices get in),
3. runs the agent loop against a real sandbox ``BaseEnvironment``, and
4. streams every delta / tool / done event back as **encrypted** frames sealed
   with a :class:`~cowork_crypto.CoworkFrameSealer`.

Streaming is genuinely incremental and needs no change to ``cowork_agent``:

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
   every accepted task to its :class:`~cowork_agent.KillSwitch`. A stop names one
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
:class:`cowork_agent.KillSwitch`.
"""

from __future__ import annotations

import base64
import json
import queue
import subprocess
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from uuid import uuid4

from cowork_agent import (
    HereNowConfig,
    KillSwitch,
    MCPManager,
    ModelClient,
    ModelResponse,
    PublishRequest,
    StateStore,
    SubagentConfig,
    SubagentLimits,
    WorkspaceMount,
    build_runtime,
    configs_from_entries,
)
from cowork_crypto import (
    CoworkFrameOpener,
    CoworkFrameRejected,
    CoworkFrameSealer,
)
from cowork_manager import decode_frames, encode_frame, make_request, make_response
from cowork_sandbox import BaseEnvironment, make_environment

from .environment import SandboxEnvironment
from .protocol import (
    INBOUND_METHODS,
    MAX_BROWSER_CHUNK,
    METHOD_EVENT,
    approval_request_payload,
    b64_to_frame,
    browser_data_payload,
    browser_view_payload,
    debug_context_payload,
    decode_payload,
    delta_payload,
    done_payload,
    encode_payload,
    error_payload,
    file_payload,
    frame_to_b64,
    stop_ack_payload,
    subagent_payload,
    tool_payload,
)

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


class StreamingModelClient:
    """Wraps a ``ModelClient`` and reports the assistant text as deltas.

    If the inner client can stream (it exposes a settable ``on_delta``, like the
    backend client), we hand it the callback so each chunk reaches the UI **as it
    arrives** — real token-by-token streaming. Otherwise (e.g. the mock client)
    we fall back to emitting the whole turn's text once, so the UI still updates.
    Tool-only turns carry no text and emit nothing either way."""

    def __init__(
        self, inner: ModelClient, *, on_delta: Callable[[str], None] | None = None
    ) -> None:
        self._inner = inner
        self._on_delta = on_delta
        # Prefer live per-chunk streaming when the inner client supports it.
        self._inner_streams = False
        if on_delta is not None and hasattr(inner, "on_delta"):
            inner.on_delta = on_delta  # type: ignore[attr-defined]
            self._inner_streams = True

    def set_tools(self, tools: list[dict] | None) -> None:
        """Forward the native tool set to the inner client (§ native tool calls).
        ``build_runtime`` calls this on the model it was handed; the seam mirrors
        ``on_delta`` so the inner backend client gets its ``tools`` array."""
        inner = self._inner
        if hasattr(inner, "set_tools"):
            inner.set_tools(tools)  # type: ignore[attr-defined]

    def complete(self, messages: list[dict]) -> ModelResponse:
        response = self._inner.complete(messages)
        # Fallback only: the inner already streamed each chunk, so emitting the
        # full text again here would duplicate it in the thread.
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
    # The model this task named, its provider slug, and its reasoning effort, as
    # the app's mode selector sent them. All ``None`` -> the task named nothing
    # and runs on the executor's default ``model_factory``. Captured at accept
    # time, like everything else the frame carried.
    model: str | None = None
    provider: str | None = None
    reasoning_effort: str | None = None


#: How long a here.now publish waits for the user before it gives up and denies.
#: Long enough to walk to the phone and read the prompt; bounded so a run cannot
#: hang forever on an approval nobody will ever answer.
APPROVAL_TIMEOUT = 600.0


@dataclass
class _PendingApproval:
    """One in-flight publish approval: the worker waits on ``event``, the serve
    thread writes ``approved`` and sets it. Default is deny, so a lost decision
    or a torn-down wait resolves to "do not publish"."""

    event: threading.Event = field(default_factory=threading.Event)
    approved: bool = False


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
        opener: CoworkFrameOpener,
        sealer: CoworkFrameSealer,
        environment: BaseEnvironment,
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
        browser_mcp: bool = False,
    ) -> None:
        self._name = name
        self._endpoint = endpoint
        self._opener = opener
        self._sealer = sealer
        self._environment = environment
        self._env_shim = SandboxEnvironment(environment)
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
        # Give every task the Playwright MCP (§9.1) when the sandbox is the
        # browser image: the agent drives a headed Chromium the user can watch
        # over VNC. Off on the browser-free base image, where the launcher script
        # does not exist. The server runs INSIDE the container (the runtime is
        # host-side), reached over `docker exec` stdio — see `_browser_mcp_entry`.
        self._browser_mcp = browser_mcp
        # MCP managers live per session (§9): one manager owns the transport
        # threads for a session's forwarded servers, is reused across that
        # session's tasks, and is closed on executor stop. Guarded because the
        # worker builds it while ``stop`` closes it.
        self._mcp_managers: dict[str, MCPManager] = {}
        self._mcp_signatures: dict[str, str] = {}
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
        self._vnc_lock = threading.Lock()

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

    def stop(self, *, join_timeout: float = 5.0) -> None:
        """Signal both loops, join them, and release the sandbox.

        Interrupts every live run first: a task in flight would otherwise hold the
        worker for as long as the model and its commands want, and the join would
        expire while a run kept writing to a channel nobody reads.
        """
        self._stop.set()
        # A live browser view holds a `docker exec` pipe; drop it before the
        # container is released so no socat outlives the executor.
        self._vnc_teardown(reason="stopped", notify=False)
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
        self._environment.cleanup()

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
            finally:
                self._forget(run.request_id)

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
        try:
            plaintext = self._opener.open(sealed)
        except CoworkFrameRejected as exc:
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
        if kind == "browser_start":
            self._vnc_start(request_id, payload)
            return
        if kind == "browser_stop":
            self._vnc_teardown(reason="stopped")
            return
        if kind == "browser_data":
            self._vnc_feed(payload)
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
        )
        with self._runs_lock:
            self._runs[request_id] = run
        self._queue.put(run)

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
        try:
            store = StateStore(self._db_path)
        except Exception as exc:  # noqa: BLE001 — a bad db must not wedge serving
            self._terminal(
                request_id, error_payload(f"replay failed: {type(exc).__name__}")
            )
            return
        try:
            session_id = store.route(session_key)
            for event in store.replay_events(session_id):
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
        # Close the stream the way a live run does. ``replay`` marks it so the
        # client never renders a spurious "done" card or mistakes it for a run.
        self._terminal(
            request_id,
            {
                **done_payload(final_answer=None, reason="replay", iterations=0),
                "replay": True,
            },
        )

    # -- live browser view (§9.1) ----------------------------------------
    def _vnc_exec_prefix(self) -> tuple[list[str], str] | None:
        """`docker exec` prefix + container id for this agent's box, or None.

        None means the sandbox is not the docker backend (nothing to watch) or
        the container could not be realized. Forces the container live first,
        because `container_id` is None until the first command runs.
        """
        env = self._environment
        cli = getattr(env, "_cli", None)
        binary = getattr(cli, "binary", None)
        if binary is None or not hasattr(env, "container_id"):
            return None
        try:
            env.run_bash("true", internal=True)  # realize the container
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

    def _browser_mcp_entry(self) -> dict | None:
        """The Playwright MCP server entry for this agent's container, or None.

        Runs the server INSIDE the container over `docker exec` stdio, so the
        Chromium it launches renders to the container's Xvfb (the display x11vnc
        serves) — the agent's browser and the watched browser are one process.
        None when the browser MCP is off or the sandbox is not docker. Reuses the
        same exec prefix (and container realization) as the VNC bridge.
        """
        if not self._browser_mcp:
            return None
        prep = self._vnc_exec_prefix()
        if prep is None:
            return None
        prefix, cid = prep  # [binary, "exec", "-i", ("-u", user)?]
        return {
            "name": "playwright",
            "command": prefix[0],
            "args": [*prefix[1:], cid, "cowork-browser-mcp"],
        }

    def _vnc_start(self, request_id: str, payload: dict) -> None:
        # Only ever one live view; replace any prior one silently.
        self._vnc_teardown(reason="stopped", notify=False)

        prep = self._vnc_exec_prefix()
        if prep is None:
            self._event(
                request_id,
                browser_view_payload("error", message="live view needs the docker sandbox"),
            )
            return
        prefix, cid = prep

        # Bring x11vnc up on the browser display (idempotent). Exit 3 = the agent
        # has not opened the browser yet, so there is no display to serve.
        # Use the FULL prefix: it is [binary, "exec", "-i", ("-u", user)?] and the
        # `-u <user>` pair must stay intact. Slicing it (`prefix[:-1]`) to drop the
        # harmless `-i` also dropped the username when a user was set, producing
        # `docker exec -i -u <cid> cowork-vnc-up` — a malformed command that failed
        # with "could not start the VNC server". `-i` on a captured run is a no-op.
        try:
            up = subprocess.run(  # noqa: S603 — argv built by us
                prefix + [cid, "cowork-vnc-up"],
                capture_output=True,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            self._event(
                request_id,
                browser_view_payload("error", message=f"vnc start failed: {type(exc).__name__}"),
            )
            return
        if up.returncode == 3:
            self._event(
                request_id,
                browser_view_payload("error", message="no browser open yet — ask the agent to open a page first"),
            )
            return
        if up.returncode != 0:
            self._event(
                request_id, browser_view_payload("error", message="could not start the VNC server")
            )
            return

        port = "5900"
        argv = prefix + [cid, "socat", "STDIO", f"TCP:127.0.0.1:{port}"]

        def emit(chunk: bytes) -> None:
            self._event(request_id, browser_data_payload(chunk))

        holder: list[_VncBridge] = []

        def on_closed() -> None:
            # The pipe died on its own (view closed, x11vnc/container gone).
            # Only tear down if THIS bridge is still the registered one: a late
            # close from a bridge that was already replaced must not kill its
            # successor.
            with self._vnc_lock:
                if not holder or self._vnc is not holder[0]:
                    return
            self._vnc_teardown(reason="stopped")

        try:
            bridge = _VncBridge(argv, emit=emit, on_closed=on_closed, autostart=False)
        except (OSError, subprocess.SubprocessError) as exc:
            self._event(
                request_id,
                browser_view_payload("error", message=f"vnc bridge failed: {type(exc).__name__}"),
            )
            return
        holder.append(bridge)
        # Register first, THEN start the pump, so an instantly-dying socat is
        # torn down (and reported) instead of lingering as a dead "live" view.
        with self._vnc_lock:
            self._vnc = bridge
            self._vnc_stream_id = request_id
            self._vnc_framer = _RfbClientFramer()
        bridge.start()
        # If the display has no browser window, the stream is an all-black frame.
        # Say so, so the user knows to ask the agent to open a page rather than
        # staring at a silent black screen. The bridge stays live: the moment the
        # agent opens a browser the window appears in the same stream.
        message = ""
        try:
            for line in up.stdout.decode("utf-8", "replace").splitlines():
                if line.startswith("WINDOWS="):
                    if line[len("WINDOWS=") :].strip() == "0":
                        message = "no page open yet — ask the agent to open a browser"
                    break
        except (AttributeError, ValueError):
            pass
        self._event(request_id, browser_view_payload("started", message=message))

    def _vnc_feed(self, payload: dict) -> None:
        with self._vnc_lock:
            bridge = self._vnc
        if bridge is None:
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
        # still well under this), so anything larger is malformed and is dropped
        # rather than forwarded into x11vnc.
        if len(data) > MAX_BROWSER_CHUNK:
            return
        # Enforce "only RFB protocol" on the way in (see _RfbClientFramer): pass
        # framed protocol messages, drop ClientCutText, and on anything that is
        # not RFB tear the view down instead of piping it into x11vnc.
        with self._vnc_lock:
            framer = self._vnc_framer
        if framer is None:
            return
        safe = framer.feed(data)
        if safe is None:
            self._vnc_teardown(reason="error")
            return
        if safe:
            bridge.feed(safe)

    def _vnc_teardown(self, *, reason: str = "stopped", notify: bool = True) -> None:
        with self._vnc_lock:
            bridge = self._vnc
            stream_id = self._vnc_stream_id
            self._vnc = None
            self._vnc_stream_id = ""
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
    def _make_approval_gate(self, request_id: str, kill: KillSwitch):
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
            try:
                self._event(
                    request_id,
                    approval_request_payload(
                        approval_id=approval_id,
                        path=req.path,
                        name=req.name,
                        file_count=req.file_count,
                        total_bytes=req.total_bytes,
                        base_url=req.base_url,
                        public=req.public,
                    ),
                )
                deadline = time.monotonic() + APPROVAL_TIMEOUT
                # Poll so a Stop reaches the wait: the loop only checks the kill
                # switch between tool calls, and this call is inside one.
                while True:
                    if kill.interrupted() or kill.estop_engaged():
                        return False
                    if pending.event.wait(self._poll):
                        return pending.approved
                    if time.monotonic() >= deadline:
                        return False
            finally:
                with self._approvals_lock:
                    self._approvals.pop(approval_id, None)

        return gate

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
        pending.event.set()

    def _live_runs(self) -> list[_Run]:
        with self._runs_lock:
            return list(self._runs.values())

    def _forget(self, request_id: str) -> None:
        with self._runs_lock:
            self._runs.pop(request_id, None)

    # -- one task --------------------------------------------------------
    def _run_task(self, run: _Run) -> None:
        request_id, prompt, session_key = run.request_id, run.prompt, run.session_key
        # Bind the streaming hooks for this task.
        self._env_shim.on_run = lambda cmd, result: self._event(
            request_id,
            tool_payload(
                name="run_command",
                command=cmd,
                exit_code=result.exit_code,
                stdout=result.stdout,
                stderr=result.stderr,
                timed_out=result.timed_out,
            ),
        )
        # A task may name the model to run on and how hard it thinks. If it named
        # either and a per-task selector is wired (production), build that model;
        # otherwise fall back to the default factory — which is both the
        # offline/mock path (no select wired, so no backend client is ever built
        # and no credits are spent) and a task that named nothing at all.
        # Everything downstream — the hero ``cheap_clone``, ``set_tools``, the
        # streaming wrapper, the cancel hooks — works off this one base client
        # exactly as before; only where it comes from changed.
        if (run.model or run.reasoning_effort) and self._model_select is not None:
            inner_model = self._model_select(
                run.model, run.provider, run.reasoning_effort
            )
        else:
            inner_model = self._model_factory()
        model = StreamingModelClient(
            inner_model,
            on_delta=lambda text: self._event(request_id, delta_payload(text)),
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
        run.kill.on_interrupt(self._env_shim.cancel)
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
        browser_entry = self._browser_mcp_entry()
        if browser_entry is not None:
            servers.append(browser_entry)
        mcp_manager = self._session_mcp_manager(session_key, servers or None)

        # here.now publish connector (§10-style consent): off unless the app
        # forwarded an enabled setting. ``ask`` mode binds the approval gate so a
        # public publish blocks on the user; ``auto`` publishes straight through.
        herenow_config = HereNowConfig.from_entry(run.herenow) if run.herenow else None
        herenow_gate = (
            self._make_approval_gate(request_id, run.kill)
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

        subagents = self._subagent_config(request_id, session_key)
        loop = build_runtime(
            model,
            db_path=self._db_path,
            environment=self._env_shim,
            max_iterations=self._max_iterations,
            system_prompt=self._system_prompt,
            workspace=self._workspace,
            subagents=subagents,
            herenow_config=herenow_config,
            herenow_gate=herenow_gate,
            # The hero/aux client (§7.3): same model, reasoning off, cheap. Enables
            # tier-2/3 compaction and mem0 extraction by default in production.
            # ``None`` (mock model) keeps tier-1-only behaviour.
            aux_model=hero_model,
            # Off unless the task set ``debug``; ``None`` means zero overhead.
            debug_observer=debug_observer,
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
            file_sink=lambda sent: self._event(
                request_id,
                file_payload(
                    name=sent.name, mime_type=sent.mime_type, data=sent.data
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
            browser_model=self._model_factory(),
        )

        try:
            result = loop.run(session_key, prompt)
        except Exception as exc:  # a crashing loop must not kill the serve thread
            self._terminal(
                request_id, error_payload(f"loop failed: {type(exc).__name__}")
            )
            return
        finally:
            self._env_shim.on_run = None
            # Children outlive the parent's turn otherwise: a leaked child keeps a
            # container and a model stream alive with nobody reading either.
            if subagents is not None and subagents.supervisor is not None:
                subagents.supervisor.shutdown()
            # The hero/aux client owns its own socket; close it with the task so
            # no aux connection outlives the run.
            if hero_model is not None:
                close_hero = getattr(hero_model, "close", None)
                if callable(close_hero):
                    try:
                        close_hero()
                    except Exception:  # noqa: BLE001 — cleanup must not mask a result
                        pass

        self._terminal(
            request_id,
            done_payload(
                final_answer=result.final_answer,
                reason=result.reason.value,
                iterations=result.iterations,
                tokens_spent=result.tokens_spent,
            ),
        )

    # -- MCP credential forwarding (§9, §10) -----------------------------
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
            return None
        try:
            signature = json.dumps(mcp_servers, sort_keys=True, default=str)
        except (TypeError, ValueError):
            signature = repr(mcp_servers)
        with self._mcp_lock:
            existing = self._mcp_managers.get(session_key)
            if existing is not None and self._mcp_signatures.get(session_key) == signature:
                return existing
            stale = existing if existing is not None else None
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
                with self._mcp_lock:
                    self._mcp_managers.pop(session_key, None)
                    self._mcp_signatures.pop(session_key, None)
                return None
            manager = MCPManager(configs, errors=errors)
        except Exception:  # noqa: BLE001 — building MCP must never crash a task
            return None
        with self._mcp_lock:
            self._mcp_managers[session_key] = manager
            self._mcp_signatures[session_key] = signature
        return manager

    def _close_mcp_managers(self) -> None:
        with self._mcp_lock:
            managers = list(self._mcp_managers.values())
            self._mcp_managers.clear()
            self._mcp_signatures.clear()
        for manager in managers:
            try:
                manager.close()
            except Exception:  # noqa: BLE001 — shutdown must not raise
                pass

    # -- subagents (§7.6) ------------------------------------------------
    def _subagent_config(self, request_id: str, session_key: str) -> SubagentConfig | None:
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
            on_event=lambda event: self._event(request_id, subagent_payload(event)),
        )
        if self._subagent_limits is not None:
            config.limits = self._subagent_limits
        return config

    # -- outbound (all sealed) -------------------------------------------
    def _seal_b64(self, payload: dict) -> str:
        return frame_to_b64(self._sealer.seal(encode_payload(payload)).to_bytes())

    def _event(self, request_id: str, payload: dict) -> None:
        """Stream a progress event as a relay notification carrying a sealed frame."""
        envelope = make_request(
            METHOD_EVENT,
            {"requestId": request_id, "frame": self._seal_b64(payload)},
        )
        self._endpoint.send(encode_frame(envelope))

    def _terminal(self, request_id: str, payload: dict) -> None:
        """Close the stream with a relay response correlated to the task."""
        envelope = make_response(request_id, {"frame": self._seal_b64(payload)})
        self._endpoint.send(encode_frame(envelope))
