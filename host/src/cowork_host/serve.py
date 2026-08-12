"""The task server — runs the real Executor under the Manager's supervisor.

Once pairing and token provisioning are done, this bridges the local relay's
simple ``{"type":"frame",...}`` envelopes to the ``cowork_executor`` Executor,
which already owns the whole agent-loop-in-a-sandbox path behind encrypted
frames. Nothing here re-implements the loop:

- an incoming sealed **task** frame is wrapped in the Executor's ``run_task``
  relay envelope and pushed to it over a loopback link, and
- every ``event`` / ``response`` envelope the Executor streams back has its inner
  sealed frame unwrapped and re-emitted as a ``{"type":"frame",...}`` message to
  the app.

The Executor's own :class:`~cowork_crypto.CoworkFrameOpener` opens the task
frames (default deny — only the paired app's device gets in) and its
:class:`~cowork_crypto.CoworkFrameSealer` seals every result. Lifecycle is the
real :class:`~cowork_executor.ExecutorSupervisor`.
"""

from __future__ import annotations

import itertools
import threading
from typing import Callable

from cowork_crypto import CoworkFrameOpener, CoworkFrameSealer
from cowork_manager import RosterStore, RuntimeState, decode_frames, encode_frame, make_request
from cowork_sandbox import BaseEnvironment

from cowork_executor import (
    METHOD_EVENT,
    METHOD_RUN_TASK,
    Executor,
    ExecutorSupervisor,
    ModelFactory,
    loopback_pair,
)

# Called with the base64 of one sealed result frame, to send it to the app.
FrameSink = Callable[[str], None]


class TaskServer:
    """Bridges local-relay frame envelopes to a supervised Executor."""

    def __init__(
        self,
        *,
        roster: RosterStore,
        agent_id: str,
        opener: CoworkFrameOpener,
        sealer: CoworkFrameSealer,
        environment: BaseEnvironment,
        model_factory: ModelFactory,
        db_path: str,
        send_frame: FrameSink,
        system_prompt: str | None = None,
        max_iterations: int = 50,
    ) -> None:
        self._roster = roster
        self._agent_id = agent_id
        self._send_frame = send_frame
        self._controller_ep, self._executor_ep = loopback_pair()

        def factory(agent):
            return Executor(
                name=agent.name,
                endpoint=self._executor_ep,
                opener=opener,
                sealer=sealer,
                environment=environment,
                db_path=db_path,
                model_factory=model_factory,
                system_prompt=system_prompt,
                max_iterations=max_iterations,
            )

        self._supervisor = ExecutorSupervisor(roster, factory)
        self._ids = itertools.count(1)
        self._stop = threading.Event()
        self._pump: threading.Thread | None = None
        self._rx = b""

    # -- lifecycle -------------------------------------------------------

    def start(self) -> RuntimeState:
        """Start the Executor (via the supervisor) and the result pump."""
        state = self._supervisor.start(self._agent_id)
        self._pump = threading.Thread(
            target=self._pump_loop, name="host-result-pump", daemon=True
        )
        self._pump.start()
        return state

    def submit(self, frame_b64: str) -> str:
        """Hand one sealed task frame to the Executor. Returns its request id."""
        request_id = f"task-{next(self._ids)}"
        envelope = make_request(
            METHOD_RUN_TASK, {"frame": frame_b64}, request_id
        )
        self._controller_ep.send(encode_frame(envelope))
        return request_id

    def stop(self) -> None:
        self._stop.set()
        self._supervisor.stop(self._agent_id)
        if self._pump is not None:
            self._pump.join(timeout=2.0)
            self._pump = None

    @property
    def supervisor(self) -> ExecutorSupervisor:
        return self._supervisor

    # -- result pump -----------------------------------------------------

    def _pump_loop(self) -> None:
        while not self._stop.is_set():
            data = self._controller_ep.recv(timeout=0.2)
            if data is None:
                continue
            self._rx += data
            frames, self._rx = decode_frames(self._rx)
            for frame in frames:
                inner = self._inner_frame(frame)
                if inner is not None:
                    self._send_frame(inner)

    @staticmethod
    def _inner_frame(frame: dict) -> str | None:
        """Pull the sealed-frame base64 out of an Executor event/response envelope."""
        if frame.get("type") == "response":
            return (frame.get("result") or {}).get("frame")
        if frame.get("method") == METHOD_EVENT:
            return (frame.get("params") or {}).get("frame")
        return None
