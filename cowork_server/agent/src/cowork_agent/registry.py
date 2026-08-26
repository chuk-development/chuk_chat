"""Self-registering tool registry (§7.2).

Each tool calls :func:`ToolRegistry.register` at import. ``dispatch`` bridges
async handlers, coerces stringy model args against the tool schema, and wraps
any failure in a bounded, sanitized error envelope so a misbehaving tool cannot
stack an unbounded error body across retries.
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

# A tool handler is any callable. Async handlers are bridged in ``dispatch``.
Handler = Callable[..., Any]
CheckFn = Callable[[], bool]

# Cap on the error body a single dispatch can emit. Keeps a flapping tool from
# stacking megabytes of traceback across retries.
ERROR_CAP = 2048

_CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


@dataclass
class ToolSpec:
    name: str
    schema: dict
    handler: Handler
    check_fn: CheckFn | None = None
    is_async: bool = False
    #: May this tool be hidden from the prompt behind the ``tool_search`` /
    #: ``tool_describe`` / ``tool_call`` bridge (§7.2)? Only MCP and plugin tools
    #: opt in. Every core tool leaves this at ``False`` and can therefore never
    #: be deferred — see :meth:`ToolRegistry.defer`.
    deferrable: bool = False


@dataclass
class ToolRegistry:
    _tools: dict[str, ToolSpec] = field(default_factory=dict)
    #: Names currently hidden from the prompt. Deferral is a *prompt* state, not
    #: a dispatch state: a deferred tool stays fully callable through
    #: ``tool_call``, so the bridge needs no second dispatch path.
    _deferred: set[str] = field(default_factory=set)

    # -- registration -----------------------------------------------------

    def register(
        self,
        name: str,
        schema: dict,
        handler: Handler,
        check_fn: CheckFn | None = None,
        is_async: bool = False,
        deferrable: bool = False,
    ) -> None:
        if name in self._tools:
            raise ValueError(f"tool already registered: {name}")
        self._tools[name] = ToolSpec(
            name=name,
            schema=schema,
            handler=handler,
            check_fn=check_fn,
            is_async=is_async,
            deferrable=deferrable,
        )

    def has(self, name: str) -> bool:
        return name in self._tools

    def names(self) -> list[str]:
        return list(self._tools)

    def spec(self, name: str) -> ToolSpec:
        return self._tools[name]

    def available(self, name: str) -> bool:
        """Per-tool availability probe. A tool with no ``check_fn`` is always
        available. A probe that raises counts as unavailable."""
        spec = self._tools.get(name)
        if spec is None:
            return False
        if spec.check_fn is None:
            return True
        try:
            return bool(spec.check_fn())
        except Exception:
            return False

    # -- progressive disclosure (§7.2) ------------------------------------

    def deferrable_names(self) -> list[str]:
        """Every registered tool that opted in to being hidden behind the
        bridge tools. Availability is not checked here — the caller measures the
        prompt surface, and an unavailable tool is not in the prompt anyway."""
        return [name for name, spec in self._tools.items() if spec.deferrable]

    def defer(self, name: str) -> None:
        """Hide one tool from the prompt.

        Refuses a tool that did not opt in. That refusal is the whole guarantee
        behind "core tools are never deferred": there is one door, and
        ``run_command`` never has the key.
        """
        spec = self._tools.get(name)
        if spec is None:
            raise KeyError(f"unknown tool: {name}")
        if not spec.deferrable:
            raise ValueError(f"tool is not deferrable: {name}")
        self._deferred.add(name)

    def undefer_all(self) -> None:
        self._deferred.clear()

    def is_deferred(self, name: str) -> bool:
        return name in self._deferred

    def deferred_names(self) -> list[str]:
        return sorted(self._deferred)

    # -- dispatch ---------------------------------------------------------

    def dispatch(self, name: str, args: dict | None = None) -> Any:
        """Execute a tool by name. Never raises for a tool failure — returns a
        bounded error envelope instead."""
        args = dict(args or {})
        spec = self._tools.get(name)
        if spec is None:
            return self._error(name, f"unknown tool: {name}")
        if not self.available(name):
            return self._error(name, f"tool unavailable: {name}")

        try:
            coerced = _coerce_args(args, spec.schema)
        except Exception as exc:  # coercion should not, but guard anyway
            return self._error(name, f"argument error: {exc}")

        try:
            if spec.is_async:
                result = _run_async(spec.handler(**coerced))
            else:
                result = spec.handler(**coerced)
        except Exception as exc:
            return self._error(name, f"{type(exc).__name__}: {exc}")
        return result

    # -- error envelope ---------------------------------------------------

    @staticmethod
    def _error(name: str, message: str) -> dict:
        clean = _CONTROL_CHARS.sub(" ", message)
        if len(clean) > ERROR_CAP:
            clean = clean[:ERROR_CAP] + "…[truncated]"
        return {"error": clean, "tool": name}


def _run_async(awaitable: Awaitable[Any]) -> Any:
    """Run an awaitable to completion from sync code, whether or not a loop is
    already running in this thread."""
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(awaitable)
    # A loop is already running in this thread — run on a private loop.
    return asyncio.new_event_loop().run_until_complete(awaitable)


# -- schema-driven arg coercion ------------------------------------------

_TRUE = {"true", "1", "yes", "on"}
_FALSE = {"false", "0", "no", "off"}


def _coerce_args(args: dict, schema: dict) -> dict:
    """Coerce stringy model args to their declared types. Models routinely send
    ``"42"`` where an integer is wanted and ``"true"`` for a boolean."""
    props = (schema or {}).get("properties", {})
    out: dict[str, Any] = {}
    for key, value in args.items():
        prop = props.get(key)
        if not isinstance(prop, dict):
            out[key] = value
            continue
        out[key] = _coerce_one(value, prop.get("type"))
    return out


def _coerce_one(value: Any, target: str | None) -> Any:
    if target is None or not isinstance(value, str):
        return value
    text = value.strip()
    try:
        if target == "integer":
            return int(text)
        if target == "number":
            return float(text)
        if target == "boolean":
            low = text.lower()
            if low in _TRUE:
                return True
            if low in _FALSE:
                return False
            return value
    except ValueError:
        return value
    return value
