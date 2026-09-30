"""Tool Search / progressive disclosure (§7.2).

Every declared tool schema is paid for on **every** round of **every** session:
the request's ``tools`` array is re-sent with each turn. A handful of core tools
is cheap. Twelve MCP servers with twenty tools each is not: that surface can pass
fifty thousand tokens, which is spent before the model has read the task.

So the surface is measured against the **effective input budget**
(``context_window − reserved_output``, the same figure the context ladder uses,
§7.3). Above ~10 % of it, every **deferrable** tool stops being declared. The
loop's Pydantic AI ``ToolSearch`` capability then gives the model one
``search_tools(queries)`` tool; a tool it finds joins the declared set on the
next request and is called directly (docs/PYDANTIC_AI_LOOP.md, section 14).

Two invariants:

1. **Core tools are never deferred.** ``run_command``, the file tools,
   ``memory``, ``skill``, ``web_search``, ``web_fetch``, the terminal set and the
   subagent set stay declared at every size. They are used in almost every
   task, so hiding them would cost two extra round trips to save nothing. The
   guarantee is structural, not a list-check-at-render-time: a tool can only be
   deferred if it registered ``deferrable=True``
   (:meth:`chuk_agents_runtime.registry.ToolRegistry.defer` refuses otherwise), and
   only :mod:`chuk_agents_runtime.mcp_client` does that. :data:`CORE_TOOLS` below is a
   second belt — a name on it is refused even if some future caller marks it
   deferrable.
2. **Deferral is declaration-only.** The tool stays registered; once found it
   is dispatched through the same registry as any direct call, so there is no
   second execution path to keep in sync (journaling, arg coercion and the
   bounded error envelope all still apply).

The measurement is done on
:meth:`chuk_agents_runtime.registry.ToolRegistry.openai_tool` — the *native* schema
JSON, byte for byte what goes on the wire in the request's ``tools`` array — so
the reported saving is the real one. It used to be measured on the prompt text
of the tool docs; that stopped being what the model is billed for when tool
calling went native, and a threshold measured against text nobody sends would
defer at the wrong size.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from .context import estimate_tokens
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
    }
)

#: Share of the effective input budget the deferrable surface may occupy before
#: tool search takes over.
DEFAULT_THRESHOLD = 0.10
#: Same defaults as :class:`chuk_agents_runtime.context.LadderConfig`, so both parts of
#: the token story are measured against one budget.
DEFAULT_CONTEXT_WINDOW = 128_000
DEFAULT_RESERVED_OUTPUT = 8_000

# -- measurement -----------------------------------------------------------


def tool_doc_tokens(registry: ToolRegistry, names: list[str] | None = None) -> int:
    """Input tokens the given tools' *declarations* cost, per round.

    Measured on the native OpenAI function JSON — the exact bytes the request's
    ``tools`` array carries — not on any prose rendering of it. The JSON is
    serialized compactly, the way it travels.

    ``names`` defaults to everything currently *offered*: available and not
    deferred. Unavailable tools are skipped because they are never declared.
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
        entry = registry.openai_tool(name)
        total += estimate_tokens(json.dumps(entry, separators=(",", ":")))
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
    # The baseline is the tool set *without* tool search: every offered tool.
    tokens_before = tool_doc_tokens(
        registry, [name for name in registry.names() if registry.available(name)]
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

    for name in candidates:
        registry.defer(name)

    return ToolSearchDecision(
        active=True,
        effective_budget=effective,
        threshold_tokens=limit,
        deferrable_tokens=deferrable_tokens,
        deferred=sorted(candidates),
        tokens_before=tokens_before,
        # Measured after deferral. Pydantic AI's one ``search_tools``
        # declaration comes on top (a few hundred tokens).
        tokens_after=tool_doc_tokens(registry),
    )
