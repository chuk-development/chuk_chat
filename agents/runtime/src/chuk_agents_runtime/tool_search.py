"""Tool Search / progressive disclosure (§7.2).

Every declared tool schema is paid for on **every** round of **every** session:
the request's ``tools`` array is re-sent with each turn. A handful of core tools
is cheap. Twelve MCP servers with twenty tools each is not: that surface can pass
fifty thousand tokens, which is spent before the model has read the task.

So the deferrable surface is **hidden from token 0** (bead chuk_chat-b3g4).
A plain "hi" to a coworker used to declare 64 tools — about 10k tokens on every
round — because the old rule hid tools only once they passed ~10 % of the
effective input budget, and the browser's 24 Playwright tools plus the
schedule / call / secrets / shell / document tools never got there. A schema
that is declared but not used is paid on every round; a tool that is searched
for costs one extra round, once, in the task that needs it. So the default
threshold is ``0``: every deferrable, non-core tool stops being declared. The
loop's Pydantic AI ``ToolSearch`` capability then gives the model one
``search_tools(queries)`` tool; a tool it finds joins the declared set on the
next request and is called directly (docs/PYDANTIC_AI_LOOP.md, section 14).
A positive ``threshold`` restores the old size rule: defer only above that
share of the effective input budget
(``context_window − reserved_output``, the same figure the context ladder uses,
§7.3).

Two invariants:

1. **Core tools are never deferred.** ``run_command``, ``python``, the file
   tools, ``memory_search`` / ``memory_add``, ``skill``, ``web_search``, ``web_fetch``,
   ``send_file_to_user``, ``search_chats`` and the subagent set stay declared
   at every size. They are used in almost every task, so hiding them would cost
   an extra round trip to save nothing. The guarantee is structural, not a
   list-check-at-render-time: a tool can only be deferred if it registered
   ``deferrable=True`` (:meth:`chuk_agents_runtime.registry.ToolRegistry.defer`
   refuses otherwise). The MCP tools opt in (:mod:`chuk_agents_runtime.mcp_client`),
   and so do the built-in tools a task rarely needs: the interactive shell,
   background jobs, workspace history/undo,
   ``chat_document``, ffmpeg/ffprobe, ``browser_task`` and the combined
   ``memory`` tool (its add/search verbs stay declared), and the automation,
   call and secrets tools. :data:`CORE_TOOLS` below is a second belt — a name
   on it is refused even if some caller marks it deferrable.

   Pydantic AI refuses a call to a deferred tool the model has not searched
   for. The loop runs such a call anyway when the tool exists, is available
   and needs no approval (``AgentLoop._write_tool_row``), and
   ``pai.convert.rows_to_messages`` adds a discovery record for it, so the
   next call of that tool is not refused again.
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
        "python",
        "finish",
        "write_file",
        "read_file",
        "list_dir",
        "read_document",
        "memory_search",
        "memory_add",
        "skill",
        "web_search",
        "web_fetch",
        "send_file_to_user",
        "search_chats",
        "delegate_task",
        "subagent_control",
    }
)

#: Share of the effective input budget the deferrable surface may occupy before
#: tool search takes over. ``0`` = always: every deferrable, non-core tool is
#: behind ``search_tools`` from the first round (see the module docstring).
DEFAULT_THRESHOLD = 0.0
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

    With the default ``threshold=0`` "above" means "there is any": every
    available, deferrable, non-core tool is deferred.

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
