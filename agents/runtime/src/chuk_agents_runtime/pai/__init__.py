"""The agent loop on Pydantic AI (docs/PYDANTIC_AI_LOOP.md).

The loop itself is :class:`chuk_agents_runtime.loop.AgentLoop`; this package
holds its parts: ``model`` (the account model and the legacy-client
adapter), ``convert`` (stored rows <-> Pydantic AI messages), ``tools`` (the
registry as a toolset), ``approvals`` (the policy and the same-run handler),
``events`` (stream events -> delta / reasoning frames) and ``wiring`` (what
``build_runtime`` adds).

The exports are lazy, so importing one part does not import the others.
"""

from __future__ import annotations

import importlib
from typing import Any

_EXPORTS = {
    "ApprovalPolicy": "approvals",
    "ApprovalRule": "approvals",
    "herenow_rule": "approvals",
    "messages_to_rows": "convert",
    "rows_to_messages": "convert",
    "ChukModelSpec": "model",
    "LegacyClientModel": "model",
    "SupabaseJwtAuth": "model",
    "chuk_chat_model": "model",
    "RegistryToolset": "tools",
}


def __getattr__(name: str) -> Any:
    module = _EXPORTS.get(name)
    if module is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    value = getattr(importlib.import_module(f"{__name__}.{module}"), name)
    globals()[name] = value
    return value


def disable_banner() -> None:
    """Pydantic AI prints a once-per-process banner on stdout at the first
    run. The host and the executor speak framed protocols on their standard
    streams, so it must never be written."""
    import pydantic_ai

    pydantic_ai.BANNER_ENABLED = False


__all__ = [*_EXPORTS, "disable_banner"]
