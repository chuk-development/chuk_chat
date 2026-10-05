"""Cost per run and weekly budget (docs/WIRE_CONTRACT.md, "Cost per run and
weekly budget", bead chuk_chat-qcbv): the price formula, the price list, the
cost lines in the state file and the metered housekeeping client."""

from __future__ import annotations

import sqlite3
import time

import pytest

from chuk_agents_runtime import LocalEnvironment, MockModelClient, build_runtime
from chuk_agents_runtime.cost import (
    BUDGET_EXCEEDED,
    BUDGET_OK,
    BUDGET_WARNING,
    LINE_AUX,
    BudgetNotices,
    MeteredClient,
    PriceBook,
    budget_state,
    cost_block,
    cost_eur,
    day_start,
    metered,
    usage_split,
    valid_budget,
    week_start,
)
from chuk_agents_runtime.loop import RunTimings, _split_tokens
from chuk_agents_runtime.model import ModelResponse
from chuk_agents_runtime.state import RUN_TIMING_COLUMNS, StateStore

# The shape of one ``/v1/models_info`` entry (api_server models_cache.json).
MODELS = [
    {
        "id": "z-ai/glm-5.3-flash",
        "providers": [
            {
                "slug": "deepinfra/fp4",
                "pricing": {
                    "prompt": 7.5e-08,
                    "completion": 2.5e-07,
                    "cache_read": 1.5e-08,
                    "cache_write": 0.0,
                },
                "pricing_listed": {"prompt": 1.5e-07, "completion": 5e-07},
            },
            {
                "slug": "orcarouter",
                "pricing": {"prompt": 1e-07, "completion": 4e-07, "cache_read": 0.0},
            },
        ],
    },
    {"id": "no/providers", "providers": []},
]


# -- the formula (api_server services/payment_service.calculate_cost) --------


def test_cost_matches_the_api_formula():
    pricing = MODELS[0]["providers"][0]["pricing"]
    # 1M prompt tokens of which 400k cached, 100k completion:
    # 600k * 7.5e-8 + 400k * 1.5e-8 + 100k * 2.5e-7 = 0.045 + 0.006 + 0.025
    eur = cost_eur(pricing, prompt_tokens=1_000_000, completion_tokens=100_000,
                   cached_tokens=400_000)
    assert eur == pytest.approx(0.076)


def test_a_missing_cache_price_bills_the_full_prompt_price():
    pricing = {"prompt": 1e-07, "completion": 4e-07, "cache_read": 0.0}
    with_cache = cost_eur(pricing, prompt_tokens=1000, completion_tokens=0, cached_tokens=1000)
    without = cost_eur(pricing, prompt_tokens=1000, completion_tokens=0)
    assert with_cache == pytest.approx(without) == pytest.approx(1e-04)


def test_noise_never_bills_negative():
    pricing = {"prompt": 1e-07, "completion": 4e-07}
    assert cost_eur(pricing, prompt_tokens=10, completion_tokens=-5, cached_tokens=99) >= 0
    assert cost_eur(None, prompt_tokens=10, completion_tokens=10) == 0.0


# -- the price list ----------------------------------------------------------


def test_the_pinned_provider_prices_the_call():
    book = PriceBook(MODELS)
    assert book.pricing("z-ai/glm-5.3-flash", "DeepInfra/FP4")["prompt"] == 7.5e-08
    assert book.pricing("z-ai/glm-5.3-flash", "orcarouter")["prompt"] == 1e-07


def test_no_pin_or_an_unknown_pin_takes_the_cheapest_by_prompt():
    book = PriceBook(MODELS)
    for provider in (None, "", "gone"):
        assert book.pricing("z-ai/glm-5.3-flash", provider)["prompt"] == 7.5e-08


def test_an_unknown_model_has_no_price():
    book = PriceBook(MODELS)
    assert book.pricing("x/unknown", None) is None
    assert book.pricing("no/providers", None) is None
    assert book.cost("x/unknown", None, prompt_tokens=10, completion_tokens=10) is None
    assert not PriceBook([])


# -- the cost block ----------------------------------------------------------


def test_cost_block_totals_only_when_every_line_is_priced():
    run = {"kind": "run", "model": "m", "provider": "p", "prompt_tokens": 1000,
           "completion_tokens": 100, "cached_tokens": 500, "cost_eur": 0.002, "calls": 3}
    aux = {"kind": "aux", "model": "a", "prompt_tokens": 4000,
           "completion_tokens": 200, "cached_tokens": 0, "cost_eur": 0.0003}
    block = cost_block([run, aux])
    assert block["currency"] == "EUR"
    assert block["eur"] == pytest.approx(0.0023)
    assert block["input_tokens"] == 5000 and block["output_tokens"] == 300
    assert [line["kind"] for line in block["lines"]] == ["run", "aux"]
    assert block["lines"][0]["calls"] == 3

    unpriced = cost_block([run, {**aux, "cost_eur": None}])
    assert "eur" not in unpriced
    assert "eur" not in unpriced["lines"][1]
    assert unpriced["lines"][0]["eur"] == pytest.approx(0.002)


def test_cost_block_is_absent_when_nothing_was_spent():
    assert cost_block([]) is None
    assert cost_block([{"kind": "run", "prompt_tokens": 0, "completion_tokens": 0}]) is None


# -- usage dicts and the run's own split -------------------------------------


def test_usage_split_reads_the_route_shape():
    usage = {"prompt_tokens": 900, "completion_tokens": 50, "total_tokens": 950,
             "prompt_tokens_details": {"cached_tokens": 600}}
    assert usage_split(usage) == (900, 50, 600)
    assert usage_split({"input_tokens": 9, "output_tokens": 1, "cache_read_tokens": 3}) == (9, 1, 3)
    assert usage_split(None) == (0, 0, 0)


def test_the_loop_splits_prompt_and_completion():
    assert _split_tokens({"prompt_tokens": 10, "completion_tokens": 4}) == (10, 4)
    # Only a total: it counts as prompt (the cheaper half), never as output.
    assert _split_tokens({"total_tokens": 12}) == (12, 0)
    assert _split_tokens(None) == (0, 0)


def test_the_split_is_part_of_the_run_row():
    timings = RunTimings(prompt_tokens=7, completion_tokens=3)
    row = timings.as_row()
    assert row["prompt_tokens"] == 7 and row["completion_tokens"] == 3
    assert {"prompt_tokens", "completion_tokens"} <= set(RUN_TIMING_COLUMNS)


def test_a_run_records_its_token_split(tmp_path):
    """The loop adds each call's usage to the run's split."""
    reply = ModelResponse(text="done", raw={"content": "done", "usage": {
        "prompt_tokens": 120, "completion_tokens": 8, "total_tokens": 128,
        "prompt_tokens_details": {"cached_tokens": 100}}})
    loop = build_runtime(
        MockModelClient([reply]),
        db_path=str(tmp_path / "s.db"),
        environment=LocalEnvironment(),
        include_tool_docs=False,
        enable_memory=False,
        enable_skills=False,
    )
    result = loop.run("s1", "hi")
    assert result.timings.prompt_tokens == 120
    assert result.timings.completion_tokens == 8
    assert result.timings.cached_tokens == 100


# -- the state file ----------------------------------------------------------


def test_an_old_database_gains_the_cost_columns(tmp_path):
    path = str(tmp_path / "old.db")
    conn = sqlite3.connect(path)
    conn.executescript(
        "CREATE TABLE sessions (session_id INTEGER PRIMARY KEY AUTOINCREMENT, "
        "created_at REAL NOT NULL, meta TEXT NOT NULL DEFAULT '{}');"
        "CREATE TABLE runs (run_id TEXT PRIMARY KEY, session_id INTEGER NOT NULL, "
        "session_key TEXT NOT NULL, prompt TEXT NOT NULL, state TEXT NOT NULL, "
        "reason TEXT, final_answer TEXT, iterations INTEGER NOT NULL DEFAULT 0, "
        "tokens_spent INTEGER NOT NULL DEFAULT 0, first_mid INTEGER, last_mid INTEGER, "
        "started_at REAL NOT NULL, finished_at REAL, notified_at REAL, seen_at REAL);"
        "INSERT INTO sessions(created_at) VALUES (1.0);"
        "INSERT INTO runs(run_id, session_id, session_key, prompt, state, started_at) "
        "VALUES ('old', 1, 'k', 'p', 'finished', 1.0);"
    )
    conn.commit()
    conn.close()
    store = StateStore(path)
    row = store.get_run("old")
    assert row["prompt_tokens"] == 0 and row["completion_tokens"] == 0
    assert row["cost_eur"] is None
    assert store.usage_lines("old") == []
    store.close()


def test_lines_group_per_kind_and_model(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("agent-1")
    store.begin_run("r1", sid, "agent-1", "hi")
    store.add_usage_line(run_id="r1", session_key="agent-1", kind="run", model="m",
                         prompt_tokens=100, completion_tokens=10, cost_eur=0.01)
    store.add_usage_line(run_id="r1", session_key="agent-1", kind=LINE_AUX, model="a",
                         prompt_tokens=50, completion_tokens=5, cost_eur=0.001)
    store.add_usage_line(run_id="r1", session_key="agent-1", kind=LINE_AUX, model="a",
                         prompt_tokens=50, completion_tokens=5, cost_eur=None)
    lines = store.usage_lines("r1")
    assert [(line["kind"], line["calls"]) for line in lines] == [("run", 1), ("aux", 2)]
    assert lines[1]["prompt_tokens"] == 100
    # One unpriced call makes the summed line unpriced.
    assert lines[1]["cost_eur"] is None
    store.close()


def test_spend_by_session_sums_priced_lines_in_the_window(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    now = time.time()
    store.add_usage_line(session_key="a", kind="run", cost_eur=1.0, at=now - 10 * 86400)
    store.add_usage_line(session_key="a", kind="run", cost_eur=0.5, at=now - 60)
    store.add_usage_line(session_key="a", kind="aux", cost_eur=0.25, at=now - 30)
    store.add_usage_line(session_key="a", kind="aux", cost_eur=None, at=now - 20)
    store.add_usage_line(session_key="b", kind="run", cost_eur=2.0, at=now - 5)
    assert store.spend_by_session(now - 3600) == {"a": 0.75, "b": 2.0}
    assert store.spend_by_session(0.0)["a"] == pytest.approx(1.75)
    store.close()


def test_a_replayed_done_carries_the_cost(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("k")
    store.begin_run("r1", sid, "k", "hi")
    store.append_message(sid, "user", {"role": "user", "content": "hi"})
    store.finish_run("r1", reason="finished", final_answer="ok", iterations=1,
                     tokens_spent=110, timings={"prompt_tokens": 100, "completion_tokens": 10},
                     cost_eur=0.004)
    store.add_usage_line(run_id="r1", session_key="k", kind="run", model="m",
                         prompt_tokens=100, completion_tokens=10, cost_eur=0.004)
    row = store.get_run("r1")
    assert row["cost_eur"] == pytest.approx(0.004) and row["prompt_tokens"] == 100
    (done,) = store.run_terminals("k")
    assert done["cost"]["eur"] == pytest.approx(0.004)
    assert done["cost"]["lines"][0]["model"] == "m"
    store.close()


def test_a_replay_reads_every_run_cost_in_one_query(tmp_path, monkeypatch):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("k")
    for n in range(5):
        run_id = f"r{n}"
        store.begin_run(run_id, sid, "k", "hi")
        store.append_message(sid, "user", {"role": "user", "content": f"hi {n}"})
        store.finish_run(run_id, reason="finished", final_answer="ok", iterations=1,
                         tokens_spent=1)
        if n != 2:  # r2 has no line and so no cost block
            store.add_usage_line(run_id=run_id, session_key="k", kind="run", model="m",
                                 prompt_tokens=10, completion_tokens=1,
                                 cost_eur=0.001 * (n + 1))
    statements: list[str] = []
    store._conn().set_trace_callback(statements.append)
    events = store.run_terminals("k")
    store._conn().set_trace_callback(None)
    assert [e["run_id"] for e in events] == ["r0", "r1", "r2", "r3", "r4"]
    assert sum("FROM usage_lines" in sql for sql in statements) == 1
    assert "cost" not in events[2]
    assert events[4]["cost"]["eur"] == pytest.approx(0.005)
    # Chunked ids (SQLite's parameter cap) give the same answer.
    monkeypatch.setattr("chuk_agents_runtime.state._USAGE_IN_CHUNK", 2)
    assert store.run_terminals("k") == events
    assert store.usage_lines_for(["r0", "r2", "r4", "r0"]).keys() == {"r0", "r4"}
    store.close()


# -- the metered housekeeping client -----------------------------------------


class _Aux(MockModelClient):
    model_id = "deepseek/deepseek-v4-flash-0731"
    provider_slug = None

    def cheap_clone(self, **_kwargs):
        return _Aux(["clone"])


def _with_usage(text: str) -> ModelResponse:
    return ModelResponse(text=text, raw={"usage": {"prompt_tokens": 40, "completion_tokens": 4}})


def test_a_metered_client_reports_each_call_and_its_clones():
    seen: list[tuple] = []
    client = metered(_Aux([_with_usage("a")]), lambda *a: seen.append(a), kind=LINE_AUX)
    assert isinstance(client, MeteredClient)
    assert client.complete([{"role": "user", "content": "x"}]).text == "a"
    clone = client.cheap_clone()
    clone.wrapped._responses = [_with_usage("b")]
    clone.complete([])
    assert [(kind, model) for kind, model, _p, _u in seen] == [
        (LINE_AUX, "deepseek/deepseek-v4-flash-0731"),
        (LINE_AUX, "deepseek/deepseek-v4-flash-0731"),
    ]
    # Every other attribute passes through.
    assert client.calls and client.model_id == "deepseek/deepseek-v4-flash-0731"


def test_a_call_without_usage_or_a_broken_sink_is_harmless():
    def broken(*_args):
        raise RuntimeError("disk full")

    client = metered(_Aux(["plain"]), broken)
    assert client.complete([]).text == "plain"
    client = metered(_Aux([_with_usage("x")]), broken)
    assert client.complete([]).text == "x"


def test_a_client_that_cannot_clone_stays_unclonable():
    client = metered(MockModelClient(["x"]), lambda *a: None)
    assert getattr(client, "cheap_clone", None) is None
    assert metered(None, lambda *a: None) is None
    plain = MockModelClient(["x"])
    assert metered(plain, None) is plain


# -- weeks and budgets -------------------------------------------------------


def test_week_and_day_boundaries():
    now = time.time()
    start = week_start(now)
    assert start <= day_start(now) <= now
    assert now - start < 7 * 86400 + 3600
    assert time.localtime(start).tm_wday == 0
    assert time.localtime(start).tm_hour == 0


def test_budget_states():
    assert budget_state(5.0, 0) == BUDGET_OK
    assert budget_state(7.99, 10) == BUDGET_OK
    assert budget_state(8.0, 10) == BUDGET_WARNING
    assert budget_state(10.0, 10) == BUDGET_EXCEEDED


@pytest.mark.parametrize("value", [True, "5", -1, float("nan"), float("inf"), 10_001, None])
def test_a_bad_budget_is_refused(value):
    with pytest.raises(ValueError):
        valid_budget(value)


def test_a_good_budget_is_rounded_to_cents():
    assert valid_budget(0) == 0.0
    assert valid_budget(4.999) == 5.0
    assert valid_budget(12) == 12.0


def test_each_warning_level_is_sent_once_per_week():
    notices = BudgetNotices()
    assert notices.first("a", 1.0, BUDGET_WARNING)
    assert not notices.first("a", 1.0, BUDGET_WARNING)
    assert notices.first("a", 1.0, BUDGET_EXCEEDED)
    assert not notices.first("a", 1.0, BUDGET_WARNING)
    assert not notices.first("a", 1.0, BUDGET_EXCEEDED)
    # A new week starts over; another coworker is its own.
    assert notices.first("a", 2.0, BUDGET_WARNING)
    assert notices.first("b", 1.0, BUDGET_EXCEEDED)
    assert not notices.first("a", 2.0, BUDGET_OK)


# -- the lighter context of a scheduled run ----------------------------------


def test_light_context_drops_recall_and_extraction(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTS_MEM_BACKEND", "mem0")

    class Writer(MockModelClient):
        def cheap_clone(self):
            return MockModelClient(["{}"])

    workspace = tmp_path / "ws"
    workspace.mkdir()
    loop = build_runtime(
        MockModelClient(["done"]),
        db_path=str(tmp_path / "s.db"),
        environment=LocalEnvironment(),
        workspace=str(workspace),
        aux_model=Writer(["{}"]),
        light_context=True,
    )
    assert loop._recall_provider is None
    assert loop._turn_observer is None
    # The memory tools stay for a run that needs them on purpose.
    assert loop.registry.has("memory_search") and loop.registry.has("memory_add")
