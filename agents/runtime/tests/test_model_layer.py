"""CHAT-181: the model layer.

1. DeepSeek gets the reasoning of its earlier turns back in a tool loop.
2. The prompt prefix stays byte-identical across tasks; cache hits are
   counted and priced at the cache price.
3. A model per kind of work, and the monthly spending cap helpers.
4. Retry, then fall back to the next tool-capable model.
5. A failed or useless aux summary never ends the run: the ladder trims.

No real model is called: every endpoint is an ``httpx2.MockTransport``.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx2
import pytest
from pydantic_ai.usage import RequestUsage

import chuk_agents_runtime.clock as clock_module
from chuk_agents_runtime import MockModelClient, build_runtime
from chuk_agents_runtime.backend import BackendModelClient
from chuk_agents_runtime.context import (
    SUMMARY_PREFIX,
    TRIM_MARKER,
    AuxSummarizer,
    ContextLadder,
    LadderConfig,
    summary_is_junk,
)
from chuk_agents_runtime.cost import (
    PriceBook,
    cache_hit_tokens,
    month_start,
    monthly_cap_refusal_text,
    usage_split,
    valid_monthly_cap,
)
from chuk_agents_runtime.loop import AgentLoop, ModelServiceError, cached_tokens_from_usage
from chuk_agents_runtime.model import ModelResponse
from chuk_agents_runtime.model_fallback import FallbackChain, model_gone
from chuk_agents_runtime.model_retry import RetryPolicy
from chuk_agents_runtime.model_routes import (
    ModelRoute,
    clean_routes,
    resolve_routes,
)
from chuk_agents_runtime.pai.model import (
    ChukModelSpec,
    chuk_chat_model,
    needs_reasoning_passback,
)
from chuk_agents_runtime.pai.wiring import fallback_from_client
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore

from pai_fakes import FakeChatEndpoint, FakeSession, text_turn, tool_turn

DEEPSEEK = "deepseek/deepseek-v4.1-flash-1017"
MISTRAL = "mistralai/mistral-small-2603"


def _store(tmp_path: Path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _model(endpoint: FakeChatEndpoint, model_id: str, **spec):
    return chuk_chat_model(
        FakeSession(),
        ChukModelSpec(model_id=model_id, **spec),
        base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )


def _echo_registry() -> ToolRegistry:
    reg = ToolRegistry()
    reg.register(
        "lookup",
        {"type": "object", "properties": {"q": {"type": "string"}}},
        lambda q="": {"found": q},
    )
    return reg


def _assistant_messages(body: dict) -> list[dict]:
    return [m for m in body["messages"] if m.get("role") == "assistant"]


# -- 1. reasoning passback -----------------------------------------------------


def test_the_passback_rule_names_deepseek_and_not_mistral():
    assert needs_reasoning_passback(DEEPSEEK)
    assert needs_reasoning_passback("deepseek/deepseek-v4-pro-0813")
    assert not needs_reasoning_passback(MISTRAL)
    assert not needs_reasoning_passback(None)


def test_deepseek_gets_the_reasoning_of_a_tool_call_turn_back(tmp_path):
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("call_1", "lookup", {"q": "x"})], reasoning_parts=["I should ", "look it up."]),
            text_turn(["done"], reasoning_parts=["now answer"]),
        ]
    )
    model, settings = _model(endpoint, DEEPSEEK)
    assert model.reasoning_passback is True
    result = AgentLoop(model, _echo_registry(), _store(tmp_path), model_settings=settings).run("s", "q")
    assert result.final_answer == "done"
    second = endpoint.requests[1]["body"]
    assert second["tools"], "the request carries tools: the passback is required"
    [assistant] = _assistant_messages(second)
    assert assistant["tool_calls"][0]["id"] == "call_1"
    assert assistant["reasoning_content"] == "I should look it up."


def test_the_passback_also_covers_earlier_tasks_of_the_session(tmp_path):
    endpoint = FakeChatEndpoint(
        [
            text_turn(["first"], reasoning_parts=["think one"]),
            text_turn(["second"], reasoning_parts=["think two"]),
        ]
    )
    model, settings = _model(endpoint, DEEPSEEK)
    loop = AgentLoop(model, _echo_registry(), _store(tmp_path), model_settings=settings)
    loop.run("s", "a")
    loop.run("s", "b")
    [earlier] = _assistant_messages(endpoint.requests[1]["body"])
    assert earlier["reasoning_content"] == "think one"


def test_other_models_get_no_reasoning_back(tmp_path):
    endpoint = FakeChatEndpoint(
        [
            tool_turn([("call_1", "lookup", {"q": "x"})], reasoning_parts=["hmm"]),
            text_turn(["done"]),
        ]
    )
    model, settings = _model(endpoint, MISTRAL)
    AgentLoop(model, _echo_registry(), _store(tmp_path), model_settings=settings).run("s", "q")
    [assistant] = _assistant_messages(endpoint.requests[1]["body"])
    assert "reasoning_content" not in assistant


def _completion(content="ok", usage=None):
    return {
        "id": "c",
        "object": "chat.completion",
        "model": "m",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": usage or {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10},
    }


def _blocking_client(model_id: str, bodies: list[dict], usage=None) -> BackendModelClient:
    def handler(request: httpx2.Request) -> httpx2.Response:
        bodies.append(json.loads(request.content))
        return httpx2.Response(200, json=_completion(usage=usage))

    return BackendModelClient(
        FakeSession(),
        model_id=model_id,
        base_url="https://api.test",
        transport=httpx2.MockTransport(handler),
    )


def test_the_blocking_client_passes_reasoning_back_with_tools():
    bodies: list[dict] = []
    client = _blocking_client(DEEPSEEK, bodies)
    client.set_tools(
        [{"type": "function", "function": {"name": "lookup", "parameters": {"type": "object", "properties": {}}}}]
    )
    rows = [
        {"role": "user", "content": "q"},
        {
            "role": "assistant",
            "content": None,
            "reasoning": "plan the lookup",
            "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "lookup", "arguments": "{}"}}],
        },
        {"role": "tool", "tool_call_id": "c1", "name": "lookup", "content": "{}"},
    ]
    client.complete(rows)
    [assistant] = _assistant_messages(bodies[0])
    assert assistant["reasoning_content"] == "plan the lookup"


# -- 2. prompt cache -----------------------------------------------------------


class _FixedClock(datetime):
    now_value = datetime(2026, 11, 24, 9, 0, tzinfo=timezone(timedelta(hours=1)))

    @classmethod
    def now(cls, tz=None):  # noqa: D401 — the test clock
        return cls.now_value


def test_the_stable_prefix_is_byte_identical_across_tasks(tmp_path, monkeypatch):
    """Two tasks of one session at different times and turns: the system
    prompt and every row the first task sent come back byte for byte at the
    head of the second request. Only rows AFTER them differ (the new clock
    row, the new prompt). This is what DeepSeek's prefix cache needs."""
    monkeypatch.setattr(clock_module, "datetime", _FixedClock)
    model = MockModelClient(["first answer", "second answer"])
    loop = build_runtime(model, db_path=str(tmp_path / "s.db"), enable_memory=False)
    loop.run("s", "hello")
    _FixedClock.now_value = _FixedClock.now_value + timedelta(hours=5, minutes=17)
    loop.run("s", "and now?")

    first, second = model.calls[0], model.calls[-1]
    assert first[0]["role"] == "system" and second[0] == first[0]
    dumped_first = [json.dumps(m, sort_keys=True) for m in first]
    dumped_second = [json.dumps(m, sort_keys=True) for m in second]
    assert dumped_second[: len(dumped_first)] == dumped_first
    clock_rows = [m["content"] for m in second if str(m.get("content", "")).startswith("[clock]")]
    assert len(clock_rows) == 2 and clock_rows[0] != clock_rows[1]
    # The time lives in rows after the prompts, never in the system prompt.
    assert "09:00" not in first[0]["content"] and "14:17" not in second[0]["content"]


def test_deepseek_cache_hits_are_read_from_every_usage_shape():
    assert usage_split({"prompt_tokens": 100, "completion_tokens": 5, "prompt_cache_hit_tokens": 80}) == (100, 5, 80)
    assert cached_tokens_from_usage({"prompt_tokens": 100, "prompt_cache_hit_tokens": 64}) == 64
    assert cache_hit_tokens(RequestUsage(input_tokens=100, details={"prompt_cache_hit_tokens": 70})) == 70
    assert cache_hit_tokens(RequestUsage(input_tokens=100, cache_read_tokens=30)) == 30
    assert cache_hit_tokens(RequestUsage(input_tokens=100)) == 0


def test_cache_hits_are_counted_on_the_run_and_priced_at_the_cache_price(tmp_path):
    usage = {"prompt_tokens": 1000, "completion_tokens": 10, "total_tokens": 1010, "prompt_cache_hit_tokens": 900}
    endpoint = FakeChatEndpoint([text_turn(["ok"], usage=usage)])
    model, settings = _model(endpoint, DEEPSEEK)
    result = AgentLoop(model, ToolRegistry(), _store(tmp_path), model_settings=settings).run("s", "q")
    assert result.timings.cached_tokens == 900

    book = PriceBook(
        [{"id": DEEPSEEK, "providers": [{"slug": "deepseek", "pricing": {"prompt": "0.0000003", "completion": "0.0000005", "cache_read": "0.000000006"}}]}]
    )
    cached = book.cost(DEEPSEEK, None, prompt_tokens=1000, completion_tokens=10, cached_tokens=900)
    uncached = book.cost(DEEPSEEK, None, prompt_tokens=1000, completion_tokens=10)
    assert cached == pytest.approx(100 * 0.0000003 + 900 * 0.000000006 + 10 * 0.0000005)
    assert cached < uncached / 5


def test_the_blocking_client_reports_cache_hits_in_its_usage():
    bodies: list[dict] = []
    client = _blocking_client(DEEPSEEK, bodies, usage={"prompt_tokens": 50, "completion_tokens": 2, "total_tokens": 52, "prompt_cache_hit_tokens": 40})
    response = client.complete([{"role": "user", "content": "q"}])
    assert response.raw["usage"]["cached_tokens"] == 40
    assert usage_split(response.raw["usage"])[2] == 40


# -- 3. model per kind of work, monthly cap -------------------------------------


def test_routes_default_to_nothing_and_read_the_environment():
    assert resolve_routes(None, {}).route("browser") is None
    assert resolve_routes(None, {}).route("main") is None
    routes = resolve_routes(
        None,
        {"AGENTS_MODEL_BROWSER": MISTRAL, "AGENTS_MODEL_BROWSER_PROVIDER": "mistral", "AGENTS_MODEL_AUX": "x"},
    )
    assert routes.route("browser") == ModelRoute(MISTRAL, "mistral", None)
    # The aux model keeps its own variables, read by the aux client itself.
    assert routes.route("aux") is None
    with pytest.raises(ValueError):
        routes.route("painting")


def test_an_agents_own_routes_win_over_the_environment():
    row = {
        "id": DEEPSEEK,
        "routes": {
            "browser": {"id": "z-ai/glm-5.3-flash"},
            "aux": {"id": DEEPSEEK, "reasoning_effort": "none"},
            "coding": {"provider": "no-id"},
            "main": {"id": "ignored"},
        },
    }
    routes = resolve_routes(row, {"AGENTS_MODEL_BROWSER": MISTRAL})
    assert routes.route("browser").model_id == "z-ai/glm-5.3-flash"
    assert routes.route("aux") == ModelRoute(DEEPSEEK, None, "none")
    assert routes.route("coding") is None
    assert routes.route("main") is None
    assert clean_routes(row["routes"]) == {
        "browser": {"id": "z-ai/glm-5.3-flash"},
        "aux": {"id": DEEPSEEK, "reasoning_effort": "none"},
    }
    assert clean_routes({}) is None and clean_routes("x") is None


def test_a_routed_clone_runs_on_the_routes_model():
    client = BackendModelClient(FakeSession(), model_id=DEEPSEEK, provider_slug="deepseek")
    browser = client.routed_clone(ModelRoute(MISTRAL))
    assert browser.model_id == MISTRAL and browser.provider_slug is None
    same = client.routed_clone(ModelRoute(DEEPSEEK, reasoning_effort="low"))
    assert same.provider_slug == "deepseek" and same.reasoning_effort == "low"
    aux = client.cheap_clone(route=ModelRoute(MISTRAL, "mistral", "none"))
    assert (aux.model_id, aux.provider_slug, aux.reasoning_effort) == (MISTRAL, "mistral", "none")
    assert aux.max_output_tokens == 512


def test_monthly_cap_helpers():
    assert valid_monthly_cap(25) == 25.0
    assert valid_monthly_cap(0) == 0.0
    for bad in (True, "5", -1, float("nan"), 10**9):
        with pytest.raises(ValueError):
            valid_monthly_cap(bad)
    stamp = datetime(2026, 11, 24, 15, 30).astimezone().timestamp()
    start = datetime.fromtimestamp(month_start(stamp)).astimezone()
    assert (start.day, start.hour, start.minute) == (1, 0, 0) and start.month == 11
    text = monthly_cap_refusal_text(spent=20.5, cap=20, account=False)
    assert "monthly spending cap" in text and "20.50 of 20.00 EUR" in text
    assert monthly_cap_refusal_text(spent=1, cap=1, account=True).startswith("All agents")


# -- 4. retry, then fall back ------------------------------------------------------


def _chain(endpoint: FakeChatEndpoint, primary: str, chain: list[str]) -> FallbackChain:
    def build(model_id: str):
        model, settings = _model(endpoint, model_id, extra_body={"provider": None})
        model.fallback_settings = settings
        return model

    return FallbackChain(primary, chain, build)


def _fast_retry() -> RetryPolicy:
    return RetryPolicy(quick_delays=(0.0, 0.0, 0.0, 0.0), slow_interval=0.0, window=60.0)


def test_transient_errors_are_retried_then_the_next_model_runs(tmp_path):
    # The SDK sends each failed call twice (MAX_RETRIES = 1): three failed
    # calls on the first model (one try, two loop retries), then the fallback.
    endpoint = FakeChatEndpoint([503] * 6 + [text_turn(["from the fallback"])])
    model, settings = _model(endpoint, DEEPSEEK, provider_slug="deepseek")
    chains: list[FallbackChain] = []

    def fallback():
        chains.append(_chain(endpoint, DEEPSEEK, [DEEPSEEK, MISTRAL]))
        return chains[-1]

    loop = AgentLoop(
        model, ToolRegistry(), _store(tmp_path), model_settings=settings,
        retry_policy=_fast_retry(), model_fallback=fallback,
    )
    result = loop.run("s", "q")
    assert result.final_answer == "from the fallback"
    models = [r["body"]["model"] for r in endpoint.requests]
    assert models[:6] == [DEEPSEEK] * 6
    assert models[6] == MISTRAL
    # The pin of the first model never reaches the fallback model.
    assert endpoint.requests[0]["body"]["provider"] == "deepseek"
    assert endpoint.requests[6]["body"].get("provider") is None
    assert chains[0].used == [MISTRAL]


def test_a_model_that_is_gone_falls_back_at_once(tmp_path):
    endpoint = FakeChatEndpoint([404, text_turn(["ok"])])
    model, settings = _model(endpoint, DEEPSEEK)
    loop = AgentLoop(
        model, ToolRegistry(), _store(tmp_path), model_settings=settings,
        retry_policy=_fast_retry(),
        model_fallback=lambda: _chain(endpoint, DEEPSEEK, [MISTRAL]),
    )
    assert loop.run("s", "q").final_answer == "ok"
    assert [r["body"]["model"] for r in endpoint.requests] == [DEEPSEEK, MISTRAL]


def test_a_request_error_never_falls_back(tmp_path):
    endpoint = FakeChatEndpoint([402, 402, text_turn(["never"])])
    model, settings = _model(endpoint, DEEPSEEK)
    loop = AgentLoop(
        model, ToolRegistry(), _store(tmp_path), model_settings=settings,
        retry_policy=_fast_retry(),
        model_fallback=lambda: _chain(endpoint, DEEPSEEK, [MISTRAL]),
    )
    with pytest.raises(ModelServiceError):
        loop.run("s", "q")
    assert {r["body"]["model"] for r in endpoint.requests} == {DEEPSEEK}


def test_the_chain_skips_the_primary_and_ends():
    built: list[str] = []
    chain = FallbackChain(DEEPSEEK, [DEEPSEEK, MISTRAL, MISTRAL, ""], lambda m: built.append(m) or m)

    class Gone(Exception):
        status_code = 404

    class Busy(Exception):
        status_code = 503

    class Bad(Exception):
        status_code = 400

    assert model_gone(Gone()) and not model_gone(Busy())
    assert chain.wants_fallback(Gone(), 0)
    assert not chain.wants_fallback(Busy(), 1) and chain.wants_fallback(Busy(), 2)
    assert not chain.wants_fallback(Bad(), 5)
    assert chain.next_model() == (MISTRAL, MISTRAL)
    assert chain.exhausted and chain.next_model() is None
    assert not chain.wants_fallback(Gone(), 0)


def test_the_wiring_builds_a_chain_without_the_provider_pin(monkeypatch):
    monkeypatch.delenv("AGENTS_MODEL_FALLBACK", raising=False)
    client = BackendModelClient(FakeSession(), model_id=DEEPSEEK, provider_slug="deepseek", reasoning_effort="high")
    factory = fallback_from_client(client)
    chain = factory()
    model_id, model = chain.next_model()
    assert model_id == MISTRAL
    assert model.model_name == MISTRAL
    assert model.fallback_settings["extra_body"] == {"provider": None}
    assert model.fallback_settings["openai_reasoning_effort"] == "high"
    assert fallback_from_client(MockModelClient([])) is None
    monkeypatch.setenv("AGENTS_MODEL_FALLBACK", "0")
    assert fallback_from_client(client) is None


# -- 5. the compressor fallback --------------------------------------------------


def _history(rounds: int) -> list[dict]:
    messages = [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "build the thing"},
    ]
    for i in range(rounds):
        messages += [
            {
                "role": "assistant",
                "tool_calls": [
                    {"id": f"call_{i}", "type": "function", "function": {"name": "read_file", "arguments": {"path": f"f{i}.py"}}}
                ],
            },
            {"role": "tool", "tool_call_id": f"call_{i}", "name": "read_file", "content": f"line {i} " * 250},
        ]
    return messages


def _ladder(aux) -> ContextLadder:
    config = LadderConfig(
        context_length=4_000,
        reserved_output=1_000,
        tier1_threshold=0.10,
        tier2_threshold=0.50,
        head_messages=2,
        tail_token_budget=600,
        max_tool_result_tokens=10_000_000,
        dedup_min_chars=10_000_000,
    )
    return ContextLadder(config=config, summarizer=AuxSummarizer(aux))


class _Aux:
    def __init__(self, replies) -> None:
        self.replies = list(replies)
        self.calls = 0

    def complete(self, messages):
        self.calls += 1
        reply = self.replies.pop(0) if self.replies else "GOAL: ship it\nDONE: rounds"
        if isinstance(reply, Exception):
            raise reply
        return ModelResponse(text=reply)


def _check_trim(out: list[dict], history: list[dict]) -> None:
    assert out[:2] == history[:2]  # the system prompt and the first user message
    marker = out[2]
    assert marker["role"] == "user" and marker["content"].startswith(SUMMARY_PREFIX)
    assert TRIM_MARKER in marker["content"]
    assert out[-1] == history[-1]  # the newest turn, verbatim
    assert len(out) < len(history)
    # No tool result without its call.
    called = {c["id"] for m in out for c in (m.get("tool_calls") or [])}
    assert all(m["tool_call_id"] in called for m in out if m.get("role") == "tool")


def test_a_failing_summary_call_trims_instead_of_ending_the_run():
    history = _history(12)
    ladder = _ladder(_Aux([RuntimeError("aux down")]))
    out = ladder.compress(history)
    _check_trim(out, history)
    assert ladder.summary is None
    assert ladder.last_stats.summary_fallback == "error"


@pytest.mark.parametrize("junk", ["", "  ", "ok", "x" * 200_000])
def test_a_useless_summary_trims_too(junk):
    history = _history(12)
    ladder = _ladder(_Aux([junk]))
    out = ladder.compress(history)
    _check_trim(out, history)
    assert ladder.summary is None


def test_after_a_failure_the_aux_model_rests_then_is_asked_again(monkeypatch):
    import chuk_agents_runtime.context as context_module

    history = _history(12)
    aux = _Aux([RuntimeError("down")])
    ladder = _ladder(aux)
    ladder.compress(history)
    assert aux.calls == 1
    out = ladder.compress(history + _history(1)[2:])
    assert aux.calls == 1, "inside the cooldown the ladder trims without a call"
    assert ladder.last_stats.summary_fallback == "cooldown"
    assert TRIM_MARKER in out[2]["content"]
    monkeypatch.setattr(context_module, "SUMMARY_FAILURE_COOLDOWN_S", 0.0)
    ladder.compress(history)
    assert aux.calls == 2 and ladder.summary is not None


def test_the_junk_rule_is_by_size_only():
    assert summary_is_junk("", "abc")
    assert summary_is_junk(None, "abc")
    assert not summary_is_junk("GOAL: s", "a long transcript " * 10)
    assert summary_is_junk("y" * 1000, "short transcript")
