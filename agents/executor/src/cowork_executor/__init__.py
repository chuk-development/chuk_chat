"""CoWork executor vertical.

Joins the four foundation packages into one fully local, encrypted path:

    ControllerSession  --sealed run_task-->  Executor  --sealed events-->  back
         (crypto)          (loopback)      (agent+sandbox)   (loopback)

- :class:`SandboxEnvironment` — the agent<->sandbox adapter (task 1).
- :class:`Executor` — agent loop + sandbox + frame crypto (task 2).
- :func:`loopback_pair` / :class:`LoopbackEndpoint` / :class:`ControllerSession`
  — the in-process transport (task 3).
- :class:`ExecutorSupervisor` — the real ``AgentSupervisor`` (task 4).
"""

from __future__ import annotations

from .backend import make_backend_model_factory, resolve_backend_model_factory
from .controller import ControllerSession
from .environment import SandboxEnvironment
from .executor import Executor, ModelFactory, StreamingModelClient
from .protocol import (
    INBOUND_METHODS,
    MAX_FILE_BYTES,
    METHOD_EVENT,
    METHOD_RUN_TASK,
    METHOD_STOP,
    PayloadTooLarge,
    b64_to_frame,
    decode_payload,
    delta_payload,
    done_payload,
    encode_payload,
    error_payload,
    file_payload,
    frame_to_b64,
    stop_ack_payload,
    stop_payload,
    subagent_payload,
    room_turn_payload,
    room_done_payload,
    task_payload,
    tool_payload,
)
from .supervisor import ExecutorFactory, ExecutorSupervisor
from .transport import LoopbackEndpoint, loopback_pair

__all__ = [
    "ControllerSession",
    "INBOUND_METHODS",
    "Executor",
    "ExecutorFactory",
    "ExecutorSupervisor",
    "LoopbackEndpoint",
    "MAX_FILE_BYTES",
    "ModelFactory",
    "PayloadTooLarge",
    "SandboxEnvironment",
    "StreamingModelClient",
    "METHOD_EVENT",
    "METHOD_RUN_TASK",
    "METHOD_STOP",
    "b64_to_frame",
    "decode_payload",
    "delta_payload",
    "done_payload",
    "encode_payload",
    "error_payload",
    "file_payload",
    "frame_to_b64",
    "stop_ack_payload",
    "stop_payload",
    "subagent_payload",
    "room_turn_payload",
    "room_done_payload",
    "loopback_pair",
    "make_backend_model_factory",
    "resolve_backend_model_factory",
    "task_payload",
    "tool_payload",
]
