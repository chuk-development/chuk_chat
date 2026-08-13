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
"""

from __future__ import annotations

import json
import threading
from collections.abc import Callable

from cowork_agent import (
    ModelClient,
    ModelResponse,
    WorkspaceMount,
    build_runtime,
)
from cowork_crypto import (
    CoworkFrameOpener,
    CoworkFrameRejected,
    CoworkFrameSealer,
)
from cowork_manager import decode_frames, encode_frame, make_request, make_response
from cowork_sandbox import BaseEnvironment

from .environment import SandboxEnvironment
from .protocol import (
    METHOD_EVENT,
    METHOD_RUN_TASK,
    b64_to_frame,
    decode_payload,
    delta_payload,
    done_payload,
    encode_payload,
    error_payload,
    file_payload,
    frame_to_b64,
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

        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._rx = b""

    @property
    def name(self) -> str:
        return self._name

    # -- lifecycle -------------------------------------------------------
    def start(self) -> None:
        """Spawn the serve loop in a background daemon thread."""
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._serve, name=f"executor-{self._name}", daemon=True
        )
        self._thread.start()

    def stop(self, *, join_timeout: float = 5.0) -> None:
        """Signal the serve loop, join it, and release the sandbox."""
        self._stop.set()
        thread = self._thread
        if thread is not None:
            thread.join(join_timeout)
            self._thread = None
        self._environment.cleanup()

    def serve_forever(self) -> None:
        """Run the serve loop on the calling thread (for a subprocess entry
        point). Prefer :meth:`start` for in-process use."""
        self._serve()

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
                    and frame.get("method") == METHOD_RUN_TASK
                ):
                    self._handle_task(frame)

    # -- one task --------------------------------------------------------
    def _handle_task(self, frame: dict) -> None:
        request_id = frame.get("requestId", "")
        params = frame.get("params", {}) or {}
        raw_b64 = params.get("frame", "")

        try:
            sealed = b64_to_frame(raw_b64)
        except (ValueError, TypeError):
            self._terminal(request_id, error_payload("malformed envelope frame"))
            return

        # Open the encrypted task frame. Default deny: an unapproved device or a
        # bad signature dies here and never reaches the loop.
        try:
            plaintext = self._opener.open(sealed)
        except CoworkFrameRejected as exc:
            self._terminal(request_id, error_payload(f"rejected: {exc.rejection.value}"))
            return

        try:
            task = decode_payload(plaintext)
            prompt = task["prompt"]
            session_key = task.get("session_key", "default")
        except (json.JSONDecodeError, KeyError, TypeError):
            self._terminal(request_id, error_payload("bad task payload"))
            return

        self._run_task(request_id, prompt, session_key)

    def _run_task(self, request_id: str, prompt: str, session_key: str) -> None:
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
        model = StreamingModelClient(
            self._model_factory(),
            on_delta=lambda text: self._event(request_id, delta_payload(text)),
        )

        loop = build_runtime(
            model,
            db_path=self._db_path,
            environment=self._env_shim,
            max_iterations=self._max_iterations,
            system_prompt=self._system_prompt,
            workspace=self._workspace,
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

        self._terminal(
            request_id,
            done_payload(
                final_answer=result.final_answer,
                reason=result.reason.value,
                iterations=result.iterations,
            ),
        )

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
