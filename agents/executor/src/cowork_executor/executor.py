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

import json
import queue
import threading
from collections.abc import Callable
from dataclasses import dataclass

from cowork_agent import (
    KillSwitch,
    ModelClient,
    ModelResponse,
    SubagentConfig,
    SubagentLimits,
    WorkspaceMount,
    build_runtime,
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
    METHOD_EVENT,
    b64_to_frame,
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


class StreamingModelClient:
    """Wraps a ``ModelClient`` and reports each turn's assistant text as a delta.
    Tool-only turns carry no text and emit nothing."""

    def __init__(
        self, inner: ModelClient, *, on_delta: Callable[[str], None] | None = None
    ) -> None:
        self._inner = inner
        self._on_delta = on_delta

    def complete(self, messages: list[dict]) -> ModelResponse:
        response = self._inner.complete(messages)
        if self._on_delta is not None and response.text:
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
    ) -> None:
        self._name = name
        self._endpoint = endpoint
        self._opener = opener
        self._sealer = sealer
        self._environment = environment
        self._env_shim = SandboxEnvironment(environment)
        self._db_path = db_path
        self._model_factory = model_factory
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

        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._worker: threading.Thread | None = None
        self._rx = b""

        # Accepted-but-not-finished tasks, by relay request id. Guarded because
        # the serve thread writes it (accept, stop) while the worker clears it.
        self._runs: dict[str, _Run] = {}
        self._runs_lock = threading.Lock()
        self._queue: "queue.Queue[_Run]" = queue.Queue()

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
        run = _Run(
            request_id=request_id,
            session_key=str(session_key),
            prompt=prompt,
            # Built here, not in the loop, so a stop that arrives while the task
            # is still queued has something to fire.
            kill=KillSwitch(self._estop_path),
        )
        with self._runs_lock:
            self._runs[request_id] = run
        self._queue.put(run)

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
        inner_model = self._model_factory()
        model = StreamingModelClient(
            inner_model,
            on_delta=lambda text: self._event(request_id, delta_payload(text)),
        )

        # "Cancels in-flight" (§7.1): a Stop kills the command the sandbox is
        # blocked on and the model turn in flight, instead of ending the run only
        # after they return on their own. Registered on this task's switch, so the
        # listeners die with the task.
        run.kill.on_interrupt(self._env_shim.cancel)
        cancel_model = getattr(inner_model, "cancel", None)
        if callable(cancel_model):
            run.kill.on_interrupt(cancel_model)

        subagents = self._subagent_config(request_id, session_key)
        loop = build_runtime(
            model,
            db_path=self._db_path,
            environment=self._env_shim,
            max_iterations=self._max_iterations,
            system_prompt=self._system_prompt,
            workspace=self._workspace,
            subagents=subagents,
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

        self._terminal(
            request_id,
            done_payload(
                final_answer=result.final_answer,
                reason=result.reason.value,
                iterations=result.iterations,
                tokens_spent=result.tokens_spent,
            ),
        )

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
