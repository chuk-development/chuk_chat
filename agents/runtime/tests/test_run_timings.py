"""The ``runs`` row's timing columns: the migration, the defaults and the loop
that fills them.

The point of these columns is that a slow run can be attributed from its row —
"the four minutes were model wait, not tools" — instead of being reconstructed
from ``messages.created_at`` by hand.
"""

from __future__ import annotations

import sqlite3

import pytest

from chuk_agents_runtime.loop import AgentLoop, RunTimings, StopReason
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import RUN_TIMING_COLUMNS, StateStore

#: The ``runs`` table exactly as it shipped BEFORE the timing columns existed.
#: A real 8 MB database on the user's host looks like this, so it is the thing
#: the migration has to open.
_OLD_SCHEMA = """
CREATE TABLE sessions (
    session_id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at REAL NOT NULL,
    meta TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE session_routes (
    session_key TEXT PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES sessions(session_id)
);
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES sessions(session_id),
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at REAL NOT NULL
);
CREATE TABLE runs (
    run_id       TEXT PRIMARY KEY,
    session_id   INTEGER NOT NULL REFERENCES sessions(session_id),
    session_key  TEXT NOT NULL,
    prompt       TEXT NOT NULL,
    state        TEXT NOT NULL,
    reason       TEXT,
    final_answer TEXT,
    iterations   INTEGER NOT NULL DEFAULT 0,
    tokens_spent INTEGER NOT NULL DEFAULT 0,
    first_mid    INTEGER,
    last_mid     INTEGER,
    started_at   REAL NOT NULL,
    finished_at  REAL,
    notified_at  REAL,
    seen_at      REAL
);
"""


def _old_database(path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(_OLD_SCHEMA)
    conn.execute(
        "INSERT INTO sessions(session_id, created_at) VALUES (1, 0)",
    )
    conn.execute(
        "INSERT INTO runs(run_id, session_id, session_key, prompt, state, "
        "iterations, tokens_spent, started_at) VALUES "
        "('old-run', 1, 'sess', 'why', 'finished', 3, 175519, 100.0)"
    )
    conn.commit()
    conn.close()


def test_an_old_database_still_opens_and_gains_the_columns(tmp_path):
    path = tmp_path / "executor-state.db"
    _old_database(path)

    store = StateStore(str(path))
    try:
        columns = {
            row[1]
            for row in store._conn().execute("PRAGMA table_info(runs)").fetchall()  # noqa: SLF001
        }
        assert set(RUN_TIMING_COLUMNS) <= columns
        # The old row survives untouched, and reads as "not measured" — which is
        # what it is.
        row = store.get_run("old-run")
        assert row["iterations"] == 3
        assert row["tokens_spent"] == 175519
        for column in RUN_TIMING_COLUMNS:
            assert row[column] == 0
    finally:
        store.close()


def test_the_migration_is_idempotent(tmp_path):
    path = tmp_path / "executor-state.db"
    _old_database(path)

    for _ in range(3):
        store = StateStore(str(path))
        store.close()

    conn = sqlite3.connect(str(path))
    names = [row[1] for row in conn.execute("PRAGMA table_info(runs)").fetchall()]
    conn.close()
    assert len(names) == len(set(names))


def test_a_fresh_database_has_the_columns_too(tmp_path):
    store = StateStore(str(tmp_path / "fresh.db"))
    try:
        session_id = store.route("sess")
        store.begin_run("r1", session_id, "sess", "why")
        store.finish_run(
            "r1", reason="finished", final_answer="ok", iterations=2, tokens_spent=9
        )
        row = store.get_run("r1")
        for column in RUN_TIMING_COLUMNS:
            assert row[column] == 0
    finally:
        store.close()


def test_the_timings_reach_the_row(tmp_path):
    store = StateStore(str(tmp_path / "fresh.db"))
    try:
        session_id = store.route("sess")
        store.begin_run("r1", session_id, "sess", "why")
        timings = RunTimings(
            model_calls=3,
            model_wait_ms=735_400.0,
            prepare_ms=1_200.0,
            tool_ms=3_300.0,
            recall_ms=74_600.0,
            retries=2,
            retry_ms=360_000.0,
        )
        store.finish_run(
            "r1",
            reason="finished",
            final_answer="ok",
            iterations=3,
            tokens_spent=175519,
            timings=timings.as_row(),
        )
        row = store.get_run("r1")
        assert row["model_calls"] == 3
        assert row["model_wait_ms"] == 735_400
        assert row["recall_ms"] == 74_600
        assert row["retries"] == 2
        assert row["retry_ms"] == 360_000
    finally:
        store.close()


def test_an_unknown_timing_key_is_ignored_rather_than_crashing_the_close(tmp_path):
    store = StateStore(str(tmp_path / "fresh.db"))
    try:
        session_id = store.route("sess")
        store.begin_run("r1", session_id, "sess", "why")
        store.finish_run(
            "r1",
            reason="finished",
            final_answer="ok",
            iterations=1,
            tokens_spent=1,
            timings={"model_calls": 2, "drop_table": 1},
        )
        assert store.get_run("r1")["model_calls"] == 2
    finally:
        store.close()


# -- the loop fills them ----------------------------------------------------


def test_the_loop_reports_where_the_wall_clock_went(tmp_path):
    store = StateStore(str(tmp_path / "loop.db"))
    registry = ToolRegistry()
    registry.register(
        "echo", {"type": "object", "properties": {}}, lambda: "done"
    )
    model = MockModelClient(
        [tool_call_response(("echo", {})), "finished"]
    )
    loop = AgentLoop(model, registry, store, max_iterations=5)

    result = loop.run("sess", "go")

    assert result.reason is StopReason.FINISHED
    assert result.timings.model_calls == 2
    assert result.timings.model_wait_ms >= 0
    assert result.timings.tool_ms >= 0
    assert result.timings.retries == 0
    assert set(result.timings.as_row()) == set(RUN_TIMING_COLUMNS)
    store.close()


def test_the_loop_bills_a_retry_reported_by_the_model_client(tmp_path):
    store = StateStore(str(tmp_path / "loop.db"))
    registry = ToolRegistry()
    model = MockModelClient(["done"])
    # A client that retried once: the loop must carry that through to the row.
    original = model.complete

    def complete(messages):
        response = original(messages)
        response.raw.setdefault("timing", {}).update(
            {"attempts": 2, "retry_reason": "first_frame_stalled", "wasted_ms": 45_000.0}
        )
        return response

    model.complete = complete  # type: ignore[method-assign]
    loop = AgentLoop(model, registry, store, max_iterations=3)

    result = loop.run("sess", "go")

    assert result.timings.retries == 1
    assert result.timings.retry_ms == pytest.approx(45_000.0)
    store.close()


def test_a_recall_provider_is_timed(tmp_path):
    store = StateStore(str(tmp_path / "loop.db"))
    registry = ToolRegistry()
    loop = AgentLoop(
        MockModelClient(["done"]),
        registry,
        store,
        max_iterations=3,
        recall_provider=lambda prompt: [{"role": "user", "content": "recalled"}],
    )

    result = loop.run("sess", "go")

    assert result.timings.recall_ms >= 0.0
    rows = [m.content for m in store.get_conversation(result.session_id)]
    assert {"role": "user", "content": "recalled"} in rows
    store.close()


# -- cache hits and time to first token (the speed harness reads these) -------


def test_cache_hits_and_first_token_reach_the_row(tmp_path):
    store = StateStore(str(tmp_path / "fresh.db"))
    try:
        session_id = store.route("sess")
        store.begin_run("r1", session_id, "sess", "why")
        timings = RunTimings(model_calls=1, cached_tokens=31_744, first_token_ms=812.6)
        store.finish_run(
            "r1", reason="finished", final_answer="ok", iterations=1, tokens_spent=9,
            timings=timings.as_row(),
        )
        row = store.get_run("r1")
        assert row["cached_tokens"] == 31_744
        assert row["first_token_ms"] == 812
    finally:
        store.close()


def test_an_unmeasured_first_token_is_zero_on_the_row():
    assert RunTimings().as_row()["first_token_ms"] == 0
    assert RunTimings().as_row()["cached_tokens"] == 0


def test_cached_tokens_are_read_from_every_usage_shape():
    from chuk_agents_runtime.loop import cached_tokens_from_usage

    assert cached_tokens_from_usage({"prompt_tokens_details": {"cached_tokens": 7}}) == 7
    assert cached_tokens_from_usage({"cached_tokens": 5}) == 5
    assert cached_tokens_from_usage({"cache_read_tokens": 4}) == 4
    assert cached_tokens_from_usage({"cache_read_input_tokens": 3}) == 3
    assert cached_tokens_from_usage({"prompt_tokens": 10}) == 0
    assert cached_tokens_from_usage(None) == 0
    assert cached_tokens_from_usage({"cached_tokens": True}) == 0


def test_a_blocking_client_reports_its_cached_tokens(tmp_path):
    store = StateStore(str(tmp_path / "loop.db"))
    model = MockModelClient(["done"])
    original = model.complete

    def complete(messages):
        response = original(messages)
        response.raw["usage"] = {
            "prompt_tokens": 1_000,
            "completion_tokens": 5,
            "prompt_tokens_details": {"cached_tokens": 900},
        }
        return response

    model.complete = complete  # type: ignore[method-assign]
    result = AgentLoop(model, ToolRegistry(), store, max_iterations=3).run("sess", "go")
    assert result.timings.cached_tokens == 900
    assert result.timings.first_token_ms is None  # nothing was streamed
    store.close()


def test_the_streaming_route_fills_cache_hits_and_first_token(tmp_path):
    """Through the production model (OpenAI-compatible SSE): the route reports
    ``prompt_tokens_details.cached_tokens``; every call adds to the run's
    figure, and the first call's first token is timed."""
    import httpx2
    from pai_fakes import FakeChatEndpoint, FakeSession, text_turn, tool_turn

    from chuk_agents_runtime.pai.model import ChukModelSpec, chuk_chat_model

    def usage(cached: int) -> dict:
        return {
            "prompt_tokens": 1_000,
            "completion_tokens": 8,
            "total_tokens": 1_008,
            "prompt_tokens_details": {"cached_tokens": cached},
        }

    endpoint = FakeChatEndpoint(
        [
            tool_turn([("c1", "echo", {})], usage=usage(600)),
            text_turn(["ok"], usage=usage(950)),
        ]
    )
    model, settings = chuk_chat_model(
        FakeSession(), ChukModelSpec(model_id="m"), base_url="https://api.test",
        transport=httpx2.MockTransport(endpoint.handler),
    )
    registry = ToolRegistry()
    registry.register("echo", {"type": "object", "properties": {}}, lambda: "echoed")
    store = StateStore(str(tmp_path / "loop.db"))
    result = AgentLoop(model, registry, store, model_settings=settings, max_iterations=4).run(
        "sess", "go"
    )
    assert result.final_answer == "ok"
    assert result.timings.cached_tokens == 1_550
    assert result.timings.first_token_ms is not None and result.timings.first_token_ms >= 0
    store.close()
