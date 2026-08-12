"""CoWork Python agent runtime — the loop, tools, state, and model client (§7)."""

from __future__ import annotations

from .backend import (
    DEFAULT_BASE_URL,
    DEFAULT_MODEL_ID,
    BackendModelClient,
    BackendModelError,
    ResolvedModel,
    SupabaseAuthError,
    SupabaseSession,
    fetch_models_info,
    login,
    resolve_model,
)
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
    extract_tool_calls,
    parse_openai_response,
    response_from_content,
)
from .registry import ToolRegistry, ToolSpec
from .runtime import build_runtime
from .state import Message, StateStore
from .tools import register_run_command

__all__ = [
    "AgentLoop",
    "BackendModelClient",
    "BackendModelError",
    "DEFAULT_BASE_URL",
    "DEFAULT_MODEL_ID",
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
    "ResolvedModel",
    "StateStore",
    "StopReason",
    "SupabaseAuthError",
    "SupabaseSession",
    "ToolCall",
    "ToolRegistry",
    "ToolSpec",
    "build_runtime",
    "extract_tool_calls",
    "fetch_models_info",
    "login",
    "parse_openai_response",
    "register_run_command",
    "resolve_model",
    "response_from_content",
]
