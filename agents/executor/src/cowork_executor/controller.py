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
    b64_to_frame,
    decode_payload,
    encode_payload,
    frame_to_b64,
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

    def collect(self, request_id: str, *, timeout: float = 10.0) -> list[dict[str, Any]]:
        """Read the executor's stream until the terminal frame for ``request_id``.

        Returns the decrypted payloads in arrival order (deltas, tools, then the
        terminal ``done`` or ``error``). Raises :class:`CoworkFrameRejected` if a
        frame fails to open — proof the channel is genuinely authenticated.
        """
        events: list[dict[str, Any]] = []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            data = self._endpoint.recv(timeout=0.2)
            if data is None:
                continue
            self._rx += data
            frames, self._rx = decode_frames(self._rx)
            for frame in frames:
                terminal = self._consume(frame, request_id, events)
                if terminal:
                    return events
        return events

    def _consume(
        self, frame: dict[str, Any], request_id: str, events: list[dict[str, Any]]
    ) -> bool:
        """Handle one envelope. Returns True when the terminal frame is seen."""
        if frame.get("type") == "response":
            match = self._corr.resolve(frame)
            if match is not None and match.request.request_id == request_id:
                events.append(self._open(match.result["frame"]))
                return True
            return False

        if frame.get("method") == METHOD_EVENT:
            params = frame.get("params", {}) or {}
            if params.get("requestId") == request_id:
                events.append(self._open(params["frame"]))
        return False

    def _open(self, frame_b64: str) -> dict[str, Any]:
        return decode_payload(self._opener.open(b64_to_frame(frame_b64)))


__all__ = ["ControllerSession", "CoworkFrameRejected"]
