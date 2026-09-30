"""What ``build_runtime`` adds for the loop (docs/PYDANTIC_AI_LOOP.md, section 18).

The model: when the client the executor built can describe itself
(``chat_spec()`` — the account client), the loop streams through the stock
``OpenAIChatModel`` on the OpenAI-compatible ``/v1/chat/completions`` route,
with the same session, model, provider pin and effort. A client that cannot (a
test's scripted mock, a subagent child's wrapper) runs behind the legacy
adapter. Plus the approval policy, tool search for deferred tools, and
OpenTelemetry when the process configured it.
"""

from __future__ import annotations

from typing import Any


def _approved(request: Any) -> bool:
    """The gate the here.now tool gets in ``ask`` mode: the approval already
    happened in the loop's deferred-tool flow before the tool runs."""
    return True


def _asks(config: Any) -> bool:
    return bool(
        config is not None
        and getattr(config, "enabled", False)
        and getattr(config, "asks", False)
    )


def herenow_tool_gate(config: Any, gate: Any) -> Any:
    """The gate to register the here.now tool with. In ``ask`` mode the ask
    lives in the loop's approval policy, so the tool itself always proceeds;
    in ``auto`` mode there is no ask at all."""
    return _approved if _asks(config) else gate


def instrumentation_capabilities() -> list[Any]:
    """Pydantic AI's OpenTelemetry spans for the run (``invoke_agent``,
    ``chat``, ``execute_tool``), when tracing is on: into the run trace's own
    provider (so they nest under the ``agent_run`` span in the same file), or
    into the process's OTel SDK when an operator configured one. Content is
    never recorded: a span must not become a way for a secret to leave the
    host."""
    from opentelemetry import trace

    from ..telemetry import OTelTracer, get_tracer

    tracer = get_tracer()
    if isinstance(tracer, OTelTracer):
        provider = tracer.provider
    elif not isinstance(trace.get_tracer_provider(), trace.ProxyTracerProvider):
        provider = trace.get_tracer_provider()
    else:
        return []
    from pydantic_ai.capabilities import Instrumentation
    from pydantic_ai.models.instrumented import InstrumentationSettings

    return [
        Instrumentation(
            settings=InstrumentationSettings(
                tracer_provider=provider,
                include_content=False,
                include_binary_content=False,
                include_model_request_parameters=False,
            )
        )
    ]


def openai_model_from_client(model: Any) -> tuple[Any, Any, Any, Any] | None:
    """``(model factory, settings, on_delta, on_reasoning)`` for the client the
    executor built, or ``None`` when it cannot describe itself (a mock, a
    scripted client): the caller keeps the adapter.

    ``model`` is the executor's streaming wrapper (``inner`` is the account
    client) or the account client itself. The account client describes itself
    with ``chat_spec()``; the wrapper already set the delta / reasoning sinks
    on it, and those become the loop's sinks. The loop builds one model per
    run from the factory and closes its client when the run ends.
    """
    inner = getattr(model, "inner", None) or model
    chat_spec = getattr(inner, "chat_spec", None)
    if not callable(chat_spec):
        return None
    spec = chat_spec()
    from .model import ChukModelSpec, chuk_chat_model, chuk_model_settings

    chuk_spec = ChukModelSpec(
        model_id=str(spec["model_id"]),
        provider_slug=spec.get("provider_slug") or None,
        reasoning_effort=spec.get("reasoning_effort"),
    )
    base_url = str(spec.get("base_url") or "https://api.chuk.chat")
    session = spec["session"]

    def factory() -> Any:
        return chuk_chat_model(session, chuk_spec, base_url=base_url)[0]

    return factory, chuk_model_settings(chuk_spec), getattr(inner, "on_delta", None), getattr(inner, "on_reasoning", None)


def loop_setup(
    model: Any,
    *,
    env: Any,
    herenow_config: Any,
    herenow_gate: Any,
    expose_tools: bool = True,
) -> tuple[Any, dict[str, Any]]:
    """``(model, extra kwargs)`` for the :class:`~chuk_agents_runtime.loop.AgentLoop`
    that ``build_runtime`` builds."""
    from .approvals import ApprovalPolicy, herenow_rule

    policy = ApprovalPolicy()
    if _asks(herenow_config):
        policy.add("herenow_publish", herenow_rule(env, herenow_config, herenow_gate))
    extra: dict[str, Any] = {
        "approval_policy": policy,
        "deferred_mode": "pai",
        "expose_tools": expose_tools,
        "capabilities": instrumentation_capabilities(),
    }
    converted = openai_model_from_client(model)
    if converted is not None:
        factory, settings, on_delta, on_reasoning = converted
        extra.update(
            model_factory=factory,
            model_settings=settings,
            on_delta=on_delta,
            on_reasoning=on_reasoning,
        )
    return model, extra


__all__ = [
    "herenow_tool_gate",
    "instrumentation_capabilities",
    "loop_setup",
    "openai_model_from_client",
]
