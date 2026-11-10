"""Bead B18: the context ladder sizes itself from the model's real window,
not the 128k default."""

from __future__ import annotations

from types import SimpleNamespace

from chuk_agents_runtime import BackendModelClient, MockModelClient, SupabaseSession
from chuk_agents_runtime.backend import model_limits_from_catalog
from chuk_agents_runtime.context import DEFAULT_CONTEXT_LENGTH, DEFAULT_RESERVED_OUTPUT, LadderConfig
from chuk_agents_runtime.environment import LocalEnvironment
from chuk_agents_runtime.runtime import build_runtime, ladder_config_for, model_limits

CATALOG = [
    {
        "id": "big/model",
        "providers": [
            {"slug": "a", "context_length": 1_000_000, "max_completion_tokens": 32_000},
            {"slug": "b", "context_length": 200_000, "max_completion_tokens": None},
        ],
    },
    {"id": "top/level", "context_length": 32_768, "providers": [{"slug": "x"}]},
    {"id": "silent/model", "providers": [{"slug": "y"}]},
]


def test_catalog_limits_prefer_the_pinned_provider():
    assert model_limits_from_catalog(CATALOG, "big/model", "a") == (1_000_000, 32_000)
    assert model_limits_from_catalog(CATALOG, "big/model", "b") == (200_000, 32_000)
    # No pin: the smallest window every route can hold.
    assert model_limits_from_catalog(CATALOG, "big/model") == (200_000, 32_000)
    assert model_limits_from_catalog(CATALOG, "top/level", "x") == (32_768, None)
    assert model_limits_from_catalog(CATALOG, "silent/model", "y") == (None, None)
    assert model_limits_from_catalog(CATALOG, "unknown") == (None, None)


def test_for_model_uses_the_window_and_caps_the_reserve():
    cfg = LadderConfig.for_model(1_000_000, 32_000)
    assert cfg.context_length == 1_000_000 and cfg.reserved_output == 32_000
    small = LadderConfig.for_model(16_000, 16_000)
    assert small.context_length == 16_000 and small.reserved_output == 4_000
    assert LadderConfig.for_model(32_768).reserved_output == DEFAULT_RESERVED_OUTPUT
    unknown = LadderConfig.for_model(None)
    assert unknown.context_length == DEFAULT_CONTEXT_LENGTH
    assert LadderConfig.for_model("garbage").context_length == DEFAULT_CONTEXT_LENGTH  # type: ignore[arg-type]


def _client(**kw) -> BackendModelClient:
    session = SupabaseSession(
        access_token="t", refresh_token="r", supabase_url="http://x", anon_key="k"
    )
    return BackendModelClient(session, model_id="big/model", provider_slug="a", **kw)


def test_the_backend_client_carries_the_limits_through_wrappers():
    client = _client(context_length=1_000_000, max_output_tokens=32_000)
    assert model_limits(client) == (1_000_000, 32_000)
    wrapped = SimpleNamespace(inner=SimpleNamespace(inner=client))
    assert model_limits(wrapped) == (1_000_000, 32_000)
    # The client's own max_tokens cap is what the answer may spend.
    assert _client(context_length=200_000, max_tokens=8_000).max_output_tokens == 8_000
    assert model_limits(MockModelClient(["x"])) == (None, None)


def test_build_runtime_sizes_the_ladder_from_the_model(tmp_path):
    big = _client(context_length=1_000_000, max_output_tokens=32_000)
    assert ladder_config_for(big).context_length == 1_000_000

    model = MockModelClient(["done"])
    model.context_length = 32_000  # type: ignore[attr-defined]
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "state.db"),
        environment=LocalEnvironment(),
        version_workspace=False,
    )
    ladder = _find_ladder(loop)
    assert ladder.config.context_length == 32_000

    plain = build_runtime(
        MockModelClient(["done"]),
        db_path=str(tmp_path / "state2.db"),
        environment=LocalEnvironment(),
        version_workspace=False,
    )
    assert _find_ladder(plain).config.context_length == DEFAULT_CONTEXT_LENGTH


def _find_ladder(loop):
    from chuk_agents_runtime.context import ContextLadder

    for value in vars(loop).values():
        if isinstance(value, ContextLadder):
            return value
    raise AssertionError("no ContextLadder on the loop")
