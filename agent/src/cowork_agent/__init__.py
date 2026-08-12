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
from .prompt import (
    BASE_INSTRUCTIONS,
    TOOL_PROTOCOL,
    build_system_prompt,
    render_tool_docs,
)
from .registry import ToolRegistry, ToolSpec
from .runtime import build_runtime
from .state import Message, StateStore
from .tools import register_builtin_tools, register_file_tools, register_run_command
from .web_fetch import (
    FETCH_CAP,
    UrlRejected,
    html_to_markdown,
    is_blocked_address,
    make_web_fetch_handler,
    register_web_fetch,
    validate_url,
)
from .web_search import (
    TokenSession,
    make_web_search_handler,
    register_web_search,
)

__all__ = [
    "BASE_INSTRUCTIONS",
    "TOOL_PROTOCOL",
    "AgentLoop",
    "BackendModelClient",
    "BackendModelError",
    "DEFAULT_BASE_URL",
    "DEFAULT_MODEL_ID",
    "Environment",
    "FETCH_CAP",
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
    "TokenSession",
    "ToolCall",
    "ToolRegistry",
    "ToolSpec",
    "UrlRejected",
    "build_runtime",
    "build_system_prompt",
    "extract_tool_calls",
    "fetch_models_info",
    "html_to_markdown",
    "is_blocked_address",
    "login",
    "make_web_fetch_handler",
    "make_web_search_handler",
    "parse_openai_response",
    "register_builtin_tools",
    "register_file_tools",
    "register_run_command",
    "register_web_fetch",
    "register_web_search",
    "render_tool_docs",
    "resolve_model",
    "response_from_content",
    "validate_url",
]
