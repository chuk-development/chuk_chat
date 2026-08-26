"""Controller endpoint (task 3, controller side).

The phone-side counterpart of the :class:`~cowork_executor.executor.Executor`.
It seals a task, sends it over the loopback transport, and collects the executor's
encrypted result stream back into decrypted payloads.

It reuses the Manager's relay pieces directly:

- :func:`cowork_manager.encode_frame` / :func:`cowork_manager.decode_frames` for
  the envelope ser/deser,
- :func:`cowork_manager.make_request` to build the ``run_task`` envelope,
- :class:`cowork_manager.CorrelationMap` to match the terminal response to the
  task it opened.
"""

from __future__ import annotations

import itertools
import time
from typing import Any

from cowork_crypto import CoworkFrameOpener, CoworkFrameRejected, CoworkFrameSealer
from cowork_manager import (
    CorrelationMap,
    decode_frames,
    encode_frame,
    make_request,
)

from .protocol import (
    METHOD_EVENT,
    METHOD_RUN_TASK,
    METHOD_STOP,
    b64_to_frame,
    decode_payload,
    encode_payload,
    frame_to_b64,
    stop_payload,
    task_payload,
)


class ControllerSession:
    """One controller talking to one executor over a loopback endpoint."""

    def __init__(
        self,
        *,
        endpoint,  # LoopbackEndpoint (send + recv)
        sealer: CoworkFrameSealer,
        opener: CoworkFrameOpener,
    ) -> None:
        self._endpoint = endpoint
        self._sealer = sealer
        self._opener = opener
        self._corr = CorrelationMap()
        self._rx = b""
        self._ids = itertools.count(1)
        # Opened payloads per request id, and the ids whose terminal has arrived.
        # Buffering by id is what lets one session have a task and a stop open at
        # the same time without either losing frames.
        self._inbox: dict[str, list[dict[str, Any]]] = {}
        self._closed: set[str] = set()

    def send_task(self, prompt: str, session_key: str = "default") -> str:
        """Seal and dispatch a task. Returns its ``requestId``."""
        request_id = f"task-{next(self._ids)}"
        sealed = self._sealer.seal(encode_payload(task_payload(prompt, session_key)))
        envelope = make_request(
            METHOD_RUN_TASK,
            {"frame": frame_to_b64(sealed.to_bytes())},
            request_id,
        )
        self._corr.register(envelope)
        self._endpoint.send(encode_frame(envelope))
        return request_id

    def send_payload(self, payload: dict) -> str:
        """Seal and dispatch an arbitrary payload dict, returning its
        ``requestId``. The generic path room frames (§16.1) ride, and what a test
        uses to send anything the typed helpers do not cover."""
        request_id = f"req-{next(self._ids)}"
        sealed = self._sealer.seal(encode_payload(payload))
        envelope = make_request(
            METHOD_RUN_TASK,
            {"frame": frame_to_b64(sealed.to_bytes())},
            request_id,
        )
        self._corr.register(envelope)
        self._endpoint.send(encode_frame(envelope))
        return request_id

    def send_stop(
        self, *, request_id: str | None = None, session_key: str | None = None
    ) -> str:
        """Seal and dispatch a ``stop`` for a running task (§7.1, §16).

        Names the target by the task's own ``requestId`` (exact) or by its session
        key (the handle the phone has). Returns the **stop's own** request id, so
        :meth:`collect` on it yields the executor's ``stop_ack``.
        """
        stop_id = f"stop-{next(self._ids)}"
        sealed = self._sealer.seal(
            encode_payload(
                stop_payload(request_id=request_id, session_key=session_key)
            )
        )
        envelope = make_request(
            METHOD_STOP,
            {"frame": frame_to_b64(sealed.to_bytes())},
            stop_id,
        )
        self._corr.register(envelope)
        self._endpoint.send(encode_frame(envelope))
        return stop_id

    def collect(self, request_id: str, *, timeout: float = 10.0) -> list[dict[str, Any]]:
        """Read the executor's stream until the terminal frame for ``request_id``.

        Returns the decrypted payloads in arrival order (deltas, tools, then the
        terminal ``done`` or ``error``). Raises :class:`CoworkFrameRejected` if a
        frame fails to open — proof the channel is genuinely authenticated.

        Works for a stop id too: its terminal is the ``stop_ack``.
        """
        deadline = time.monotonic() + timeout
        while True:
            if request_id in self._closed:
                break
            if time.monotonic() >= deadline:
                break
            data = self._endpoint.recv(timeout=0.2)
            if data is None:
                continue
            self._rx += data
            frames, self._rx = decode_frames(self._rx)
            for frame in frames:
                self._consume(frame)
        self._closed.discard(request_id)
        return self._inbox.pop(request_id, [])

    def _consume(self, frame: dict[str, Any]) -> None:
        """Sort one envelope into the inbox of the request it belongs to.

        Per request, not per call: a controller with two requests open — a task
        and the ``stop`` that aborts it — used to drop whichever terminal it was
        not currently waiting for, which made the stop's ack unobservable.
        """
        if frame.get("type") == "response":
            match = self._corr.resolve(frame)
            if match is None:
                return
            rid = match.request.request_id
            self._inbox.setdefault(rid, []).append(self._open(match.result["frame"]))
            self._closed.add(rid)
            return

        if frame.get("method") == METHOD_EVENT:
            params = frame.get("params", {}) or {}
            rid = params.get("requestId")
            if isinstance(rid, str):
                self._inbox.setdefault(rid, []).append(self._open(params["frame"]))

    def _open(self, frame_b64: str) -> dict[str, Any]:
        return decode_payload(self._opener.open(b64_to_frame(frame_b64)))


__all__ = ["ControllerSession", "CoworkFrameRejected"]
