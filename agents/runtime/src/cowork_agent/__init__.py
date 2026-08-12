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
from .memory import (
    MAX_ENTRY_CHARS,
    MAX_FILE_CHARS,
    MemoryStore,
    MemoryToolError,
    register_memory_tool,
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
from .search import (
    register_search_tool,
    sanitize_match,
    search_messages,
    segment_cjk,
)
from .skills import (
    MAX_DESCRIPTION_CHARS,
    Skill,
    SkillError,
    SkillLibrary,
    load_skills,
    parse_skill,
    register_skill_tool,
)
from .state import Message, StateStore
from .tools import register_builtin_tools, register_file_tools, register_run_command

__all__ = [
    "BASE_INSTRUCTIONS",
    "MAX_DESCRIPTION_CHARS",
    "MAX_ENTRY_CHARS",
    "MAX_FILE_CHARS",
    "TOOL_PROTOCOL",
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
    "MemoryStore",
    "MemoryToolError",
    "Message",
    "ModelClient",
    "ModelResponse",
    "MockModelClient",
    "OpenAICompatModelClient",
    "ProcessResult",
    "ResolvedModel",
    "Skill",
    "SkillError",
    "SkillLibrary",
    "StateStore",
    "StopReason",
    "SupabaseAuthError",
    "SupabaseSession",
    "ToolCall",
    "ToolRegistry",
    "ToolSpec",
    "build_runtime",
    "build_system_prompt",
    "extract_tool_calls",
    "fetch_models_info",
    "load_skills",
    "login",
    "parse_openai_response",
    "parse_skill",
    "register_builtin_tools",
    "register_file_tools",
    "register_memory_tool",
    "register_run_command",
    "register_search_tool",
    "register_skill_tool",
    "render_tool_docs",
    "resolve_model",
    "response_from_content",
    "sanitize_match",
    "search_messages",
    "segment_cjk",
]
