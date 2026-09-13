"""Production model wiring for the Executor (§ real-model access).

The Executor takes a ``model_factory: () -> ModelClient``. In tests that factory
hands back a :class:`~chuk_agents_runtime.MockModelClient`; in production it hands back a
:class:`~chuk_agents_runtime.BackendModelClient` driving ``wss://api.chuk.chat/v2/ws``
with the account's Supabase session.

The executor holds only the *authentication* — a :class:`~chuk_agents_runtime.SupabaseSession`
(access + refresh token), never the login credentials. Refreshes go straight to
Supabase GoTrue; the backend only ever sees the access token.
"""

from __future__ import annotations

import logging

from chuk_agents_runtime.connection_pool import BackendConnectionPool

from chuk_agents_runtime import (
    DEFAULT_BASE_URL,
    BackendModelClient,
    ModelClient,
    SupabaseSession,
    clamp_reasoning_effort,
    fetch_models_info,
    resolve_model,
    supported_efforts,
)

logger = logging.getLogger(__name__)

from .executor import ModelFactory, ModelSelect


def make_backend_model_factory(
    session: SupabaseSession,
    *,
    model_id: str,
    provider_slug: str,
    base_url: str = DEFAULT_BASE_URL,
    max_tokens: int = 2048,
    temperature: float = 0.7,
    reasoning_effort: str | None = None,
    connection_pool: BackendConnectionPool | None = None,
) -> ModelFactory:
    """A ``model_factory`` that builds a fresh :class:`BackendModelClient` per task
    from the injected session. The session (and its auto-refresh) is shared, so a
    token refreshed on one task carries to the next.
    """

    pool = connection_pool or BackendConnectionPool()

    def factory() -> ModelClient:
        return BackendModelClient(
            session,
            model_id=model_id,
            provider_slug=provider_slug,
            base_url=base_url,
            max_tokens=max_tokens,
            temperature=temperature,
            reasoning_effort=reasoning_effort,
            connection_pool=pool,
        )

    factory.close = pool.close
    return factory


def resolve_backend_model_factory(
    session: SupabaseSession,
    *,
    base_url: str = DEFAULT_BASE_URL,
    preferred_model_id: str | None = None,
    preferred_provider: str | None = None,
    **kwargs,
) -> ModelFactory:
    """Resolve a default model + provider from ``/v1/models_info`` with the token,
    then build the factory. One network call at wiring time; the tasks reuse the
    result."""
    models = fetch_models_info(session, base_url=base_url)
    resolved = resolve_model(
        models,
        preferred_model_id=preferred_model_id,
        preferred_provider=preferred_provider,
    )
    return make_backend_model_factory(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        base_url=base_url,
        **kwargs,
    )


def make_backend_model_select(
    session: SupabaseSession,
    models: list[dict],
    *,
    base_url: str = DEFAULT_BASE_URL,
    max_tokens: int = 2048,
    temperature: float = 0.7,
    reasoning_effort: str | None = None,
    connection_pool: BackendConnectionPool | None = None,
) -> ModelSelect:
    """A per-task selector: given the ``(model, provider, reasoning_effort)`` a
    task asked for, resolve it against the account's ``/v1/models_info`` list and
    build a :class:`BackendModelClient` for it. An unknown id falls back through
    :func:`resolve_model` to the default, so a stale client can never pin the host
    to a model the account cannot serve. ``models`` is fetched once at wiring time
    and reused across tasks.

    The task's own ``reasoning_effort`` reaches the client — that is what Fast
    Mode is: the same model with thinking turned down. When the task names none,
    the factory-level default passed in here is used instead.

    The level is clamped to the model's catalogue ``supported_efforts``
    (:func:`chuk_agents_runtime.clamp_reasoning_effort`): the backend answers an
    unsupported level with NO reasoning frames at all, so an app whose
    capability cache was cold (it sent ``medium`` to a low/high/max model)
    would otherwise get a silent, thinking-less run. A clamp is logged once per
    ``(model, level)`` pair; the client's ``reasoning_effort`` property carries
    the effective level so the executor can record it on the run.
    """
    warned: set[tuple[str, str]] = set()
    pool = connection_pool or BackendConnectionPool()

    def select(
        model: str | None,
        provider: str | None,
        task_reasoning_effort: str | None = None,
    ) -> ModelClient:
        resolved = resolve_model(
            models,
            preferred_model_id=model,
            preferred_provider=provider,
        )
        requested = (
            task_reasoning_effort
            if task_reasoning_effort is not None
            else reasoning_effort
        )
        effective = clamp_reasoning_effort(models, resolved.model_id, requested)
        if effective != requested and requested is not None:
            key = (resolved.model_id, requested)
            if key not in warned:
                warned.add(key)
                logger.warning(
                    "reasoning effort %r is not supported by %s (supported: %s); "
                    "using %r",
                    requested,
                    resolved.model_id,
                    ",".join(supported_efforts(models, resolved.model_id)) or "?",
                    effective,
                )
        return BackendModelClient(
            session,
            model_id=resolved.model_id,
            provider_slug=resolved.provider_slug,
            base_url=base_url,
            max_tokens=max_tokens,
            temperature=temperature,
            reasoning_effort=effective,
            connection_pool=pool,
        )

    select.close = pool.close
    return select


def resolve_backend_model_wiring(
    session: SupabaseSession,
    *,
    base_url: str = DEFAULT_BASE_URL,
    preferred_model_id: str | None = None,
    preferred_provider: str | None = None,
    **kwargs,
) -> tuple[ModelFactory, ModelSelect]:
    """Fetch ``/v1/models_info`` once and build BOTH the default model factory and
    the per-task selector from the same list. One network call at wiring time. The
    factory serves tasks that name no model; the selector serves those that do."""
    models = fetch_models_info(session, base_url=base_url)
    resolved = resolve_model(
        models,
        preferred_model_id=preferred_model_id,
        preferred_provider=preferred_provider,
    )
    kwargs.setdefault("connection_pool", BackendConnectionPool())
    factory = make_backend_model_factory(
        session,
        model_id=resolved.model_id,
        provider_slug=resolved.provider_slug,
        base_url=base_url,
        **kwargs,
    )
    select = make_backend_model_select(session, models, base_url=base_url, **kwargs)
    return factory, select


__all__ = [
    "make_backend_model_factory",
    "make_backend_model_select",
    "resolve_backend_model_factory",
    "resolve_backend_model_wiring",
]
