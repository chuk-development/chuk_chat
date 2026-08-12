"""Production model wiring for the Executor (§ real-model access).

The Executor takes a ``model_factory: () -> ModelClient``. In tests that factory
hands back a :class:`~cowork_agent.MockModelClient`; in production it hands back a
:class:`~cowork_agent.BackendModelClient` driving ``wss://api.chuk.chat/v2/ws``
with the account's Supabase session.

The executor holds only the *authentication* — a :class:`~cowork_agent.SupabaseSession`
(access + refresh token), never the login credentials. Refreshes go straight to
Supabase GoTrue; the backend only ever sees the access token.
"""

from __future__ import annotations

from cowork_agent import (
    DEFAULT_BASE_URL,
    BackendModelClient,
    ModelClient,
    SupabaseSession,
    fetch_models_info,
    resolve_model,
)

from .executor import ModelFactory


def make_backend_model_factory(
    session: SupabaseSession,
    *,
    model_id: str,
    provider_slug: str,
    base_url: str = DEFAULT_BASE_URL,
    max_tokens: int = 2048,
    temperature: float = 0.7,
    reasoning_effort: str | None = None,
) -> ModelFactory:
    """A ``model_factory`` that builds a fresh :class:`BackendModelClient` per task
    from the injected session. The session (and its auto-refresh) is shared, so a
    token refreshed on one task carries to the next.
    """

    def factory() -> ModelClient:
        return BackendModelClient(
            session,
            model_id=model_id,
            provider_slug=provider_slug,
            base_url=base_url,
            max_tokens=max_tokens,
            temperature=temperature,
            reasoning_effort=reasoning_effort,
        )

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


__all__ = ["make_backend_model_factory", "resolve_backend_model_factory"]
