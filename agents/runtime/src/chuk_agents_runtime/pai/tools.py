"""The tool registry as a Pydantic AI toolset (docs/PYDANTIC_AI_LOOP.md, section 6).

Every tool of the runtime stays a :class:`~chuk_agents_runtime.registry.ToolRegistry`
entry: its JSON schema, its ``check_fn``, its handler. :class:`RegistryToolset`
shows those entries to Pydantic AI and sends every call back through
``registry.dispatch``, so nothing about a tool changes:

- the arguments are coerced from the schema (``"42"`` -> ``42``) by the registry,
  and Pydantic AI does not validate them a second time (an any-schema
  validator), so a model that sends a string where a number is wanted still
  gets its call run, exactly as before;
- a failure is the bounded error envelope, never an exception;
- the result passes the registry's ``result_filter`` — the secret scrubber —
  before anything else sees it;
- the journaling registry commits the workspace per call.

What the toolset adds is the stop. A call that starts after the kill switch
fired is not run; it gets :data:`~chuk_agents_runtime.loop.INTERRUPTED_TOOL_RESULT`.
A call that is running when Stop arrives is abandoned by the event loop at once
(``abandon_on_cancel``); the executor's cancel listener kills the sandbox
process, so the worker thread ends too.

Approvals: a tool named by the :class:`~chuk_agents_runtime.pai.approvals.ApprovalPolicy`
is declared with ``kind="unapproved"``. Pydantic AI then defers the call, and the
loop's :class:`~pydantic_ai.capabilities.HandleDeferredToolCalls` handler asks the
user in the same run.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any

import anyio
from pydantic_ai import RunContext
from pydantic_ai.tools import ToolDefinition
from pydantic_ai.toolsets import AbstractToolset
from pydantic_ai.toolsets.abstract import ToolsetTool
from pydantic_core import SchemaValidator, core_schema

from ..loop import INTERRUPTED_TOOL_RESULT, KillSwitch
from ..registry import ToolRegistry

#: Arguments are validated by the registry (schema coercion), not by Pydantic
#: AI: a second, stricter validation would turn today's lenient coercion into
#: retry prompts.
ANY_ARGS = SchemaValidator(schema=core_schema.any_schema())

#: How many times Pydantic AI may re-ask the model after a tool call it could
#: not resolve (an unknown name). The run is bounded by the loop's own
#: iteration and token budgets, as it always was; this only keeps Pydantic AI
#: from ending a run because a model named a tool twice that does not exist.
TOOL_RETRIES = 1_000_000


#: A call that has no result yet (it is running, or it never started).
UNSET: Any = object()


@dataclass
class CallRecord:
    """What the loop needs to know about one call after it ended: the
    clocks for the ``tool`` frame, whether it ran at all, and the exact result
    the registry returned (already scrubbed) — the loop stores that, not the
    text Pydantic AI made of it."""

    started_at: float
    completed_at: float | None = None
    raised: bool = False
    result: Any = UNSET
    #: Set by the worker thread when the handler returned. A call that was
    #: abandoned by a Stop still finishes on its thread (the executor kills
    #: the sandbox process); the loop waits a bounded time for it, so the row
    #: holds the real result when there is one.
    done: threading.Event = field(default_factory=threading.Event)
    #: The handler began: its side effect may have happened. Only a call that
    #: never started may be recorded as "not run".
    started: bool = False
    #: The loop gave up on the call before it started; it must never run.
    closed: bool = False
    lock: threading.Lock = field(default_factory=threading.Lock)

    def begin(self) -> bool:
        """Called on the worker thread right before the handler. ``False``
        when the loop already closed the call as "not run"."""
        with self.lock:
            if self.closed:
                return False
            self.started = True
            return True

    def close_unstarted(self) -> bool:
        """``True`` (and the call can never start) when it had not started."""
        with self.lock:
            if self.started:
                return False
            self.closed = True
            return True


def tool_definition(registry: ToolRegistry, name: str, **overrides: Any) -> ToolDefinition:
    """One registry entry as a :class:`ToolDefinition`. The schema's top-level
    ``description`` is the tool description, the rest is the parameter schema —
    the same split :meth:`ToolRegistry.openai_tool` makes for the wire."""
    function = registry.openai_tool(name)["function"]
    return ToolDefinition(
        name=name,
        description=function["description"],
        parameters_json_schema=function["parameters"],
        # The proxy's upstreams do not take OpenAI strict schemas.
        strict=False,
        **overrides,
    )


@dataclass
class RegistryToolset(AbstractToolset[Any]):
    """The runtime's registry behind the Pydantic AI toolset interface."""

    registry: ToolRegistry
    kill: KillSwitch = field(default_factory=KillSwitch)
    #: Names whose calls need the user's yes. Evaluated per step, so a policy
    #: that depends on a setting (here.now ``ask`` mode) is read live.
    requires_approval: Callable[[str], bool] = field(default=lambda name: False)
    #: ``"hide"`` keeps a deferred tool out of the prompt (the ``tool_search``
    #: bridge reaches it); ``"pai"`` declares it with ``defer_loading=True`` so
    #: Pydantic AI's ToolSearch capability can reveal it.
    deferred_mode: str = "hide"
    #: ``False`` offers no tools at all (a bare run that uses its persona
    #: verbatim).
    enabled: bool = True
    #: Told the tool name right before a handler starts (the loop's
    #: ``heartbeat.phase`` source). Runs on the worker thread; never raises
    #: into the call.
    on_tool_start: Callable[[str], None] | None = None
    #: Filled per call; the loop reads and clears it after each tool round.
    calls: dict[str, CallRecord] = field(default_factory=dict)
    toolset_id: str = "chuk-registry"
    #: Deferred tools the conversation already found (``"pai"`` mode only),
    #: in the order they were found. They are declared like core tools, after
    #: the core tools and in this order, and they stay declared for the rest
    #: of the conversation (bead cowork-g85d). Every chat template renders the
    #: ``tools`` array before the history, so a tool set that changes between
    #: two requests costs the provider's prefix cache the whole prompt.
    #: Without this, a found tool sat in registry order between the core tools
    #: and ``search_tools``, and it left the array again when the context
    #: ladder summarized or idle-dropped the search that found it.
    found: Callable[[], Sequence[str]] | None = None

    @property
    def id(self) -> str | None:
        return self.toolset_id

    async def get_tools(self, ctx: RunContext[Any]) -> dict[str, ToolsetTool[Any]]:
        tools: dict[str, ToolsetTool[Any]] = {}
        if not self.enabled:
            return tools
        registry = self.registry
        found: list[str] = []
        if self.found is not None and self.deferred_mode == "pai":
            try:
                found = [n for n in self.found() if registry.has(n) and registry.is_deferred(n)]
            except Exception:  # noqa: BLE001 — a lost cache hit, never a failed request
                found = []
        declared = set(found)
        for name in registry.names():
            deferred = registry.is_deferred(name)
            if deferred and (self.deferred_mode == "hide" or name in declared):
                continue
            self._add(tools, name, deferred=deferred)
        for name in found:
            self._add(tools, name, deferred=False)
        return tools

    def _add(self, tools: dict[str, ToolsetTool[Any]], name: str, *, deferred: bool) -> None:
        registry = self.registry
        if not registry.available(name):
            return
        overrides: dict[str, Any] = {}
        if deferred:
            overrides["defer_loading"] = True
        if self.requires_approval(name):
            overrides["kind"] = "unapproved"
        tools[name] = ToolsetTool(
            toolset=self,
            tool_def=tool_definition(registry, name, **overrides),
            max_retries=TOOL_RETRIES,
            args_validator=ANY_ARGS,
        )

    async def call_tool(
        self,
        name: str,
        tool_args: dict[str, Any],
        ctx: RunContext[Any],
        tool: ToolsetTool[Any],
    ) -> Any:
        call_id = ctx.tool_call_id or f"{name}:{len(self.calls)}"
        record = CallRecord(started_at=time.time())
        self.calls[call_id] = record
        if self.kill.interrupted():
            record.raised = True
            record.result = INTERRUPTED_TOOL_RESULT
            record.completed_at = time.time()
            return INTERRUPTED_TOOL_RESULT
        args = dict(tool_args or {})
        registry = self.registry

        def work() -> Any:
            if not record.begin():
                # Stopped before it began: the loop already wrote "not run".
                record.done.set()
                return INTERRUPTED_TOOL_RESULT
            if self.on_tool_start is not None:
                try:
                    self.on_tool_start(name)
                except Exception:  # noqa: BLE001 — a status sink never fails a call
                    pass
            try:
                result = registry.dispatch(name, args)
                record.result = result
                return result
            finally:
                record.completed_at = time.time()
                record.done.set()

        return await anyio.to_thread.run_sync(work, abandon_on_cancel=True)


__all__ = [
    "ANY_ARGS",
    "CallRecord",
    "RegistryToolset",
    "TOOL_RETRIES",
    "UNSET",
    "tool_definition",
]
