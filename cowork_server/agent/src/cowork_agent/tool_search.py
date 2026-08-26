"""Tool Search / progressive disclosure (§7.2).

Every tool schema in the prompt is paid for on **every** round of **every**
session. A handful of core tools is cheap. Twelve MCP servers with twenty tools
each is not: that surface can pass fifty thousand tokens, which is spent before
the model has read the task.

So the surface is measured against the **effective input budget**
(``context_window − reserved_output``, the same figure the context ladder uses,
§7.3). Above ~10 % of it, every **deferrable** tool leaves the prompt and three
bridge tools take its place:

- ``tool_search(query)`` — find tools by keyword, get name + one line each.
- ``tool_describe(name)`` — the full schema of one tool, verbatim the block the
  prompt would have carried.
- ``tool_call(name, arguments)`` — run it.

Two invariants:

1. **Core tools are never deferred.** ``run_command``, the file tools,
   ``memory``, ``skill``, ``web_search``, ``web_fetch``, the terminal set and the
   subagent set stay in the prompt at every size. They are used in almost every
   task, so hiding them would cost two extra round trips to save nothing. The
   guarantee is structural, not a list-check-at-render-time: a tool can only be
   deferred if it registered ``deferrable=True``
   (:meth:`cowork_agent.registry.ToolRegistry.defer` refuses otherwise), and
   only :mod:`cowork_agent.mcp_client` does that. :data:`CORE_TOOLS` below is a
   second belt — a name on it is refused even if some future caller marks it
   deferrable.
2. **Deferral is prompt-only.** The tool stays registered and callable;
   ``tool_call`` dispatches it through the same registry as any direct call, so
   there is no second execution path to keep in sync (journaling, arg coercion
   and the bounded error envelope all still apply).

The measurement is done on :func:`cowork_agent.prompt.render_tool_block`, the
same renderer the prompt uses, so the reported saving is the real one.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

from .context import estimate_tokens
from .prompt import render_tool_block
from .registry import ToolRegistry

#: Tools that must stay in the prompt whatever the size of the tool surface.
CORE_TOOLS = frozenset(
    {
        "run_command",
        "write_file",
        "read_file",
        "list_dir",
        "read_document",
        "memory",
        "skill",
        "web_search",
        "web_fetch",
        "send_file_to_user",
        "search_chats",
        "run_ffmpeg",
        "run_ffprobe",
        "workspace_history",
        "workspace_undo",
        "terminal_open",
        "terminal_send_keys",
        "terminal_read",
        "terminal_wait",
        "terminal_close",
        "delegate_task",
        "subagent_control",
        # The bridge itself, obviously.
        "tool_search",
        "tool_describe",
        "tool_call",
    }
)

#: The bridge itself. Named once so the saving can be measured against a prompt
#: that never had it.
_BRIDGE_TOOLS = ("tool_search", "tool_describe", "tool_call")

#: Share of the effective input budget the deferrable surface may occupy before
#: the bridge takes over.
DEFAULT_THRESHOLD = 0.10
#: Same defaults as :class:`cowork_agent.context.LadderConfig`, so both parts of
#: the token story are measured against one budget.
DEFAULT_CONTEXT_WINDOW = 128_000
DEFAULT_RESERVED_OUTPUT = 8_000

SEARCH_LIMIT = 10
MAX_SEARCH_LIMIT = 30
#: Cap on one ``tool_search`` line, so a server with a novel for a description
#: cannot make the cheap tool expensive.
SUMMARY_CAP = 200

_WORD = re.compile(r"[a-z0-9]+")

TOOL_SEARCH_SCHEMA = {
    "type": "object",
    "description": (
        "Find a tool by keyword. Many tools are not listed above to save room; "
        "this searches all of them and returns name plus one line each. Then "
        "call `tool_describe` for the arguments and `tool_call` to run it."
    ),
    "properties": {
        "query": {
            "type": "string",
            "description": "Words describing the job, for example 'create issue github'.",
        },
        "limit": {
            "type": "integer",
            "description": "How many matches to return.",
            "default": SEARCH_LIMIT,
        },
    },
    "required": ["query"],
}

TOOL_DESCRIBE_SCHEMA = {
    "type": "object",
    "description": (
        "Get the full description and argument list of one tool found with "
        "`tool_search`. Read it before you call the tool."
    ),
    "properties": {
        "name": {"type": "string", "description": "Exact tool name."},
    },
    "required": ["name"],
}

TOOL_CALL_SCHEMA = {
    "type": "object",
    "description": (
        "Run a tool that is not listed above. `name` is the exact tool name "
        "from `tool_search`, `arguments` is the argument object for it. Tools "
        "that ARE listed above you call directly, not through this."
    ),
    "properties": {
        "name": {"type": "string", "description": "Exact tool name."},
        "arguments": {
            "type": "object",
            "description": "The tool's arguments, as an object.",
        },
    },
    "required": ["name"],
}


def _clip(text: Any, cap: int) -> str:
    value = "" if text is None else str(text)
    value = " ".join(value.split())
    return value if len(value) <= cap else value[:cap].rstrip() + "…"


# -- measurement -----------------------------------------------------------


def tool_doc_tokens(registry: ToolRegistry, names: list[str] | None = None) -> int:
    """Prompt tokens the given tools' documentation costs.

    ``names`` defaults to everything currently *visible*: available and not
    deferred. Unavailable tools are skipped because they are not in the prompt.
    """
    if names is None:
        names = [
            name
            for name in registry.names()
            if registry.available(name) and not registry.is_deferred(name)
        ]
    total = 0
    for name in names:
        if not registry.has(name):
            continue
        total += estimate_tokens(render_tool_block(name, registry.spec(name).schema))
    return total


@dataclass
class ToolSearchDecision:
    """What :func:`apply_tool_search` did, in numbers worth logging."""

    active: bool
    effective_budget: int
    threshold_tokens: int
    deferrable_tokens: int
    deferred: list[str] = field(default_factory=list)
    tokens_before: int = 0
    tokens_after: int = 0

    @property
    def saved_tokens(self) -> int:
        return max(0, self.tokens_before - self.tokens_after)

    def as_dict(self) -> dict:
        return {
            "active": self.active,
            "effective_budget": self.effective_budget,
            "threshold_tokens": self.threshold_tokens,
            "deferrable_tokens": self.deferrable_tokens,
            "deferred_count": len(self.deferred),
            "tokens_before": self.tokens_before,
            "tokens_after": self.tokens_after,
            "saved_tokens": self.saved_tokens,
        }


# -- the three bridge tools -----------------------------------------------


def _searchable(registry: ToolRegistry) -> list[str]:
    """What the bridge can reach: the deferred tools. A visible tool is called
    directly, so listing it here would only invite the longer path."""
    return [name for name in registry.deferred_names() if registry.available(name)]


def _score(query_words: set[str], name: str, description: str) -> float:
    haystack_name = set(_WORD.findall(name.lower()))
    haystack_desc = set(_WORD.findall(description.lower()))
    if not query_words:
        return 0.0
    hits_name = len(query_words & haystack_name)
    hits_desc = len(query_words & haystack_desc)
    # A substring hit catches `create_issue` for the query `issue`, which whole
    # word matching on an underscore-joined name would already get, and
    # `githubissues` for `github`, which it would not.
    partial = sum(
        1 for word in query_words if any(word in token for token in haystack_name)
    )
    return hits_name * 3.0 + partial * 1.5 + hits_desc


def make_tool_search_handler(registry: ToolRegistry):
    def tool_search(query: str, limit: int = SEARCH_LIMIT) -> dict:
        text = (query if isinstance(query, str) else str(query or "")).strip()
        try:
            wanted = max(1, min(int(limit), MAX_SEARCH_LIMIT))
        except (TypeError, ValueError):
            wanted = SEARCH_LIMIT
        words = set(_WORD.findall(text.lower()))
        rows: list[tuple[float, str, str]] = []
        for name in _searchable(registry):
            description = (registry.spec(name).schema or {}).get("description", "")
            score = _score(words, name, str(description))
            if score > 0 or not words:
                rows.append((score, name, _clip(description, SUMMARY_CAP)))
        rows.sort(key=lambda row: (-row[0], row[1]))
        matches = [{"name": name, "description": summary} for _, name, summary in rows[:wanted]]
        return {
            "ok": True,
            "query": text,
            "total_available": len(_searchable(registry)),
            "matches": matches,
            "hint": (
                "Call tool_describe for the arguments, then tool_call to run it."
                if matches
                else "No match. Try other words, or use the tools listed in your prompt."
            ),
        }

    return tool_search


def make_tool_describe_handler(registry: ToolRegistry):
    def tool_describe(name: str) -> dict:
        key = (name or "").strip()
        if not registry.has(key):
            return {"ok": False, "error": f"unknown tool: {key}"}
        if not registry.available(key):
            return {"ok": False, "error": f"tool unavailable: {key}"}
        return {
            "ok": True,
            "name": key,
            # The same block the prompt would have carried, so nothing is lost
            # by having deferred it.
            "documentation": render_tool_block(key, registry.spec(key).schema),
            "schema": registry.spec(key).schema or {},
        }

    return tool_describe


def make_tool_call_handler(registry: ToolRegistry):
    def tool_call(name: str, arguments: dict | None = None) -> Any:
        key = (name or "").strip()
        if not registry.has(key):
            return {"ok": False, "error": f"unknown tool: {key}"}
        if not registry.is_deferred(key):
            # A visible tool is called directly. Refusing here keeps one tool to
            # one calling convention, which is what stops the model from
            # wrapping `write_file` in `tool_call` and getting the arguments
            # nested one level too deep.
            return {
                "ok": False,
                "error": (
                    f"{key} is listed in your prompt — call it directly, "
                    "not through tool_call."
                ),
            }
        if isinstance(arguments, str):
            # Models sometimes send the argument object as a JSON string.
            try:
                arguments = json.loads(arguments)
            except ValueError:
                return {"ok": False, "error": "arguments must be an object"}
        if arguments is not None and not isinstance(arguments, dict):
            return {"ok": False, "error": "arguments must be an object"}
        return registry.dispatch(key, dict(arguments or {}))

    return tool_call


def register_bridge_tools(registry: ToolRegistry) -> None:
    """Register ``tool_search`` / ``tool_describe`` / ``tool_call`` once."""
    if registry.has("tool_search"):
        return
    registry.register("tool_search", TOOL_SEARCH_SCHEMA, make_tool_search_handler(registry))
    registry.register(
        "tool_describe", TOOL_DESCRIBE_SCHEMA, make_tool_describe_handler(registry)
    )
    registry.register("tool_call", TOOL_CALL_SCHEMA, make_tool_call_handler(registry))


# -- the decision ----------------------------------------------------------


def apply_tool_search(
    registry: ToolRegistry,
    *,
    context_window: int = DEFAULT_CONTEXT_WINDOW,
    reserved_output: int = DEFAULT_RESERVED_OUTPUT,
    threshold: float = DEFAULT_THRESHOLD,
) -> ToolSearchDecision:
    """Measure the deferrable surface and, above the threshold, hide it.

    Idempotent: it starts from the undeferred state every time, so calling it
    again after a server connected or dropped re-decides on the current surface
    instead of compounding the last decision.
    """
    registry.undefer_all()
    effective = max(1, int(context_window) - max(0, int(reserved_output)))
    limit = int(effective * max(0.0, float(threshold)))

    candidates = [
        name
        for name in registry.deferrable_names()
        if name not in CORE_TOOLS and registry.available(name)
    ]
    deferrable_tokens = tool_doc_tokens(registry, candidates)
    # The baseline is the prompt *without* tool search: every visible tool, minus
    # the three bridge tools, which only exist because of it. Excluding them
    # keeps the reported saving honest when this runs a second time.
    tokens_before = tool_doc_tokens(
        registry,
        [
            name
            for name in registry.names()
            if registry.available(name) and name not in _BRIDGE_TOOLS
        ],
    )

    if not candidates or deferrable_tokens <= limit:
        return ToolSearchDecision(
            active=False,
            effective_budget=effective,
            threshold_tokens=limit,
            deferrable_tokens=deferrable_tokens,
            tokens_before=tokens_before,
            tokens_after=tokens_before,
        )

    register_bridge_tools(registry)
    for name in candidates:
        registry.defer(name)

    return ToolSearchDecision(
        active=True,
        effective_budget=effective,
        threshold_tokens=limit,
        deferrable_tokens=deferrable_tokens,
        deferred=sorted(candidates),
        tokens_before=tokens_before,
        # Measured after deferral, so it includes the three bridge tools the
        # prompt now pays for instead.
        tokens_after=tool_doc_tokens(registry),
    )
