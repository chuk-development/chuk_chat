"""One model per kind of work (CHAT-181, idea 15 from Nod and Hermes).

An agent does more than chat. Each kind of work can run on its own model:

========== ==================================================================
kind       what runs on it
========== ==================================================================
``main``   the agent loop (the chat, the tool calls)
``aux``    housekeeping: the context summary, memory extraction, judges,
           the background skill review
``browser`` the browser fallback's own step loop (``browser_task``)
``vision`` reading pictures when the main model cannot see
``coding`` coding subagents
========== ==================================================================

Safe defaults: ``main`` is always the task's model (the agent's own model,
else the model the task names; docs/agents/AGENT_MODEL.md); it is not a
route. ``aux`` is the cheap housekeeping model
(:func:`~chuk_agents_runtime.backend.aux_model_settings`, DeepSeek V4.1 Flash
with reasoning off). ``browser`` is the host's default client, ``vision`` and
``coding`` are the task's model, until they are set.

Where a route is set, from the weakest to the strongest:

1. the environment of the host: ``AGENTS_MODEL_<KIND>`` (model id),
   ``AGENTS_MODEL_<KIND>_PROVIDER`` and ``AGENTS_MODEL_<KIND>_REASONING_EFFORT``
   (``aux`` keeps its old variables, ``AGENTS_MODEL_AUX`` and friends, which
   the aux client reads itself, so they never show as a route here);
2. the agent's own model row on the host (``session_features``, kind
   ``agent_model``), key ``routes``:
   ``{"routes": {"browser": {"id": "...", "provider"?: "...", "reasoning_effort"?: "..."}}}``.

A route without an ``id`` is ignored (the kind keeps its default).
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

#: Every kind of work, in the order of the table above.
WORK_KINDS = ("main", "aux", "browser", "vision", "coding")

#: The kinds a route can be set for (``main`` is the task's model).
ROUTED_KINDS = ("aux", "browser", "vision", "coding")


@dataclass(frozen=True)
class ModelRoute:
    """The model one kind of work runs on."""

    model_id: str
    provider_slug: str | None = None
    reasoning_effort: str | None = None

    def to_dict(self) -> dict[str, str]:
        out = {"id": self.model_id}
        if self.provider_slug:
            out["provider"] = self.provider_slug
        if self.reasoning_effort:
            out["reasoning_effort"] = self.reasoning_effort
        return out


def _text(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def route_from(data: Any) -> ModelRoute | None:
    """A route from its stored shape ``{"id", "provider"?, "reasoning_effort"?}``,
    or ``None`` for anything without a model id."""
    if not isinstance(data, Mapping):
        return None
    model_id = _text(data.get("id"))
    if model_id is None:
        return None
    return ModelRoute(
        model_id=model_id,
        provider_slug=_text(data.get("provider")),
        reasoning_effort=_text(data.get("reasoning_effort")),
    )


def _env_route(kind: str, env: Mapping[str, str]) -> ModelRoute | None:
    if kind == "aux":
        # The host-wide aux model keeps its own variables, read by
        # ``BackendModelClient.cheap_clone`` (``aux_model_settings``).
        return None
    name = f"AGENTS_MODEL_{kind.upper()}"
    model_id = _text(env.get(name))
    if model_id is None:
        return None
    return ModelRoute(
        model_id=model_id,
        provider_slug=_text(env.get(f"{name}_PROVIDER")),
        reasoning_effort=_text(env.get(f"{name}_REASONING_EFFORT")),
    )


@dataclass(frozen=True)
class ModelRoutes:
    """The resolved table. ``route(kind)`` is ``None`` when the kind keeps
    its default (see the module docstring); always ``None`` for ``main``."""

    routes: Mapping[str, ModelRoute] = field(default_factory=dict)

    def route(self, kind: str) -> ModelRoute | None:
        if kind not in WORK_KINDS:
            raise ValueError(f"unknown kind of work {kind!r}")
        return self.routes.get(kind)

    def to_dict(self) -> dict[str, dict[str, str]]:
        """The set routes as the stored / wire shape."""
        return {kind: route.to_dict() for kind, route in self.routes.items()}


def resolve_routes(
    agent_model: Mapping[str, Any] | None = None,
    environ: Mapping[str, str] | None = None,
) -> ModelRoutes:
    """The table for one run: the host's environment, then the agent's own
    ``routes`` on top. ``agent_model`` is the stored ``agent_model`` row
    (``Executor._agent_model``)."""
    env = os.environ if environ is None else environ
    table: dict[str, ModelRoute] = {}
    for kind in ROUTED_KINDS:
        route = _env_route(kind, env)
        if route is not None:
            table[kind] = route
    if isinstance(agent_model, Mapping):
        own = agent_model.get("routes")
        if isinstance(own, Mapping):
            for kind, data in own.items():
                if kind in ROUTED_KINDS:
                    route = route_from(data)
                    if route is not None:
                        table[kind] = route
    return ModelRoutes(table)


def clean_routes(raw: Any) -> dict[str, dict[str, str]] | None:
    """The ``routes`` of an ``agent_model_set`` frame as they are stored:
    known kinds with a model id only. ``None`` when nothing is left."""
    if not isinstance(raw, Mapping):
        return None
    out: dict[str, dict[str, str]] = {}
    for kind, data in raw.items():
        if kind in ROUTED_KINDS:
            route = route_from(data)
            if route is not None:
                out[kind] = route.to_dict()
    return out or None


__all__ = [
    "ROUTED_KINDS",
    "WORK_KINDS",
    "ModelRoute",
    "ModelRoutes",
    "clean_routes",
    "resolve_routes",
    "route_from",
]
