"""CoWork Python agent runtime — the loop, tools, state, and model client (§7)."""

from __future__ import annotations

from .environment import Environment, LocalEnvironment, ProcessResult
from .loop import (
    AgentLoop,
    IterationBudget,
    KillSwitch,
    LoopResult,
    StopReason,
)
from .model import (
    ModelClient,
    ModelResponse,
    MockModelClient,
    OpenAICompatModelClient,
    ToolCall,
    parse_openai_response,
)
from .registry import ToolRegistry, ToolSpec
from .runtime import build_runtime
from .state import Message, StateStore
from .tools import register_run_command

__all__ = [
    "AgentLoop",
    "Environment",
    "IterationBudget",
    "KillSwitch",
    "LocalEnvironment",
    "LoopResult",
    "Message",
    "ModelClient",
    "ModelResponse",
    "MockModelClient",
    "OpenAICompatModelClient",
    "ProcessResult",
    "StateStore",
    "StopReason",
    "ToolCall",
    "ToolRegistry",
    "ToolSpec",
    "build_runtime",
    "parse_openai_response",
    "register_run_command",
]
