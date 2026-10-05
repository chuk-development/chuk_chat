"""The runs-table reader, the aggregation and the backend log parser."""

from __future__ import annotations

import json
import sqlite3
import time

import pytest

from chuk_agents_bench import runs

FULL_SCHEMA = """
CREATE TABLE runs (
    run_id TEXT PRIMARY KEY, session_id INTEGER NOT NULL, session_key TEXT NOT NULL,
    prompt TEXT NOT NULL, state TEXT NOT NULL, reason TEXT, final_answer TEXT,
    iterations INTEGER NOT NULL DEFAULT 0, tokens_spent INTEGER NOT NULL DEFAULT 0,
    first_mid INTEGER, last_mid INTEGER, started_at REAL NOT NULL, finished_at REAL,
    notified_at REAL, seen_at REAL, model TEXT, provider TEXT, reasoning_effort TEXT,
    model_calls INTEGER NOT NULL DEFAULT 0, model_wait_ms INTEGER NOT NULL DEFAULT 0,
    prepare_ms INTEGER NOT NULL DEFAULT 0, tool_ms INTEGER NOT NULL DEFAULT 0,
    recall_ms INTEGER NOT NULL DEFAULT 0, retries INTEGER NOT NULL DEFAULT 0,
    retry_ms INTEGER NOT NULL DEFAULT 0
);
"""


def _insert(conn, run_id, *, key="s:a", prompt="hi", start=1000.0, wall_s=10.0,
            model="m1", provider="p1", calls=1, wait=3000, prep=5000, tool=0,
            recall=250, tokens=100, state="finished"):
    conn.execute(
        "INSERT INTO runs(run_id, session_id, session_key, prompt, state, iterations,"
        " tokens_spent, started_at, finished_at, model, provider, model_calls,"
        " model_wait_ms, prepare_ms, tool_ms, recall_ms) VALUES"
        " (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (run_id, 1, key, prompt, state, calls, tokens, start, start + wall_s,
         model, provider, calls, wait, prep, tool, recall),
    )


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "state.db"
    conn = sqlite3.connect(path)
    conn.executescript(FULL_SCHEMA)
    _insert(conn, "r1", key="s:a", start=1000, wall_s=110, prep=105919, wait=3448, recall=259)
    _insert(conn, "r2", key="s:a", start=2000, wall_s=185, prep=177007, wait=3400, recall=253)
    _insert(conn, "r3", key="s:b", prompt="long task " * 10, start=3000, wall_s=60,
            calls=4, prep=400, wait=20000, tool=8000, model="m2", provider="p2")
    _insert(conn, "old", key="s:b", start=500, wall_s=5, calls=0, prep=0, wait=0, recall=0)
    conn.commit()
    conn.close()
    return path


def test_percentile_matches_linear_rule():
    assert runs.percentile([], 50) is None
    assert runs.percentile([7], 95) == 7
    assert runs.percentile([1, 2, 3, 4], 50) == 2.5
    # numpy.percentile([10, 20, 30, 40, 50], 95) == 48.0
    assert runs.percentile([50, 10, 40, 20, 30], 95) == pytest.approx(48.0)
    assert runs.percentile([1, 2], 0) == 1 and runs.percentile([1, 2], 100) == 2


def test_load_runs_derives_wall_other_and_per_call(db):
    rows = {r.run_id: r for r in runs.load_runs(db)}
    r1 = rows["r1"]
    assert r1.wall_ms == pytest.approx(110_000)
    # 110000 - (105919 + 3448 + 0 + 259)
    assert r1.other_ms == pytest.approx(374)
    r3 = rows["r3"]
    assert r3.prepare_per_call_ms == 100 and r3.model_wait_per_call_ms == 5000
    assert len(r3.prompt_preview) == runs.PROMPT_PREVIEW and r3.prompt_preview.endswith("~")
    assert not rows["old"].measured and rows["old"].prepare_per_call_ms is None


def test_unmeasured_rows_are_left_out_unless_asked(db):
    rows = runs.load_runs(db)
    assert {r.run_id for r in runs.select(rows, runs.RunFilter())} == {"r1", "r2", "r3"}
    everything = runs.select(rows, runs.RunFilter(include_unmeasured=True))
    assert len(everything) == 4


def test_filters(db):
    rows = runs.load_runs(db)
    only_hi = runs.select(rows, runs.RunFilter(session="s:a", prompt="hi"))
    assert [r.run_id for r in only_hi] == ["r1", "r2"]
    assert [r.run_id for r in runs.select(rows, runs.RunFilter(model="m2"))] == ["r3"]
    assert [r.run_id for r in runs.select(rows, runs.RunFilter(since=1500))] == ["r2", "r3"]


def test_report_groups_and_baseline_numbers(db):
    report = runs.build_report(runs.load_runs(db), runs.RunFilter(session="s:a"), last=1)
    assert report.overall.runs == 2
    prep = report.overall.metrics["prepare_ms"]
    assert prep.p50 == pytest.approx((105919 + 177007) / 2)
    assert prep.max == 177007
    assert [r.run_id for r in report.last] == ["r2"]
    assert [g.key for g in report.by_session] == ["s:a"]
    assert report.by_model[0].key == "p1 | m1"


def test_group_order_is_most_runs_first(db):
    report = runs.build_report(runs.load_runs(db), runs.RunFilter())
    assert [g.key for g in report.by_session] == ["s:a", "s:b"]


def test_render_text_and_json(db):
    report = runs.build_report(runs.load_runs(db), runs.RunFilter(), source="copy.db")
    text = runs.render_text(report)
    assert "by session" in text and "s:a" in text and "105.9s" in text
    data = json.loads(runs.render_json(report))
    assert data["selected_rows"] == 3
    assert data["overall"]["metrics"]["prepare_ms"]["max"] == 177007
    assert {"run_id", "wall_ms", "measured", "model_key"} <= set(data["last"][0])


def test_old_schema_without_timing_columns(tmp_path):
    path = tmp_path / "old.db"
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE runs (run_id TEXT, session_id INTEGER, session_key TEXT, prompt TEXT,"
        " state TEXT, iterations INTEGER, tokens_spent INTEGER, started_at REAL,"
        " finished_at REAL)"
    )
    conn.execute("INSERT INTO runs VALUES ('x', 1, 'k', 'p', 'finished', 1, 5, 1.0, 2.0)")
    conn.commit()
    conn.close()
    (row,) = runs.load_runs(path)
    assert row.model == "" and row.model_calls == 0 and row.wall_ms == 1000

    empty = tmp_path / "empty.db"
    sqlite3.connect(empty).execute("CREATE TABLE other (x)").connection.close()
    assert runs.load_runs(empty) == []


def test_parse_since():
    now = 100_000.0
    assert runs.parse_since(None) is None
    assert runs.parse_since("24h", now=now) == now - 86400
    assert runs.parse_since("90m", now=now) == now - 5400
    assert runs.parse_since("2026-10-05") == time.mktime(time.strptime("2026-10-05", "%Y-%m-%d"))
    with pytest.raises(ValueError):
        runs.parse_since("yesterday")


LOG_LINES = [
    "2026-10-05 03:27:18 INFO chuk_agents_runtime.backend: model call ok model=z-ai/glm-5.3-flash "
    "provider=runanywhere/serverless attempts=1 retry=- prepare_ms=12 connect_ms=80 "
    "first_frame_ms=900 first_token_ms=950 stream_ms=2400 total_ms=3400 wasted_ms=- "
    "prompt_tokens=33000 prompt_tokens_est=32000 completion_tokens=40",
    "random other line",
    "model call failed[timeout] model=z-ai/glm-5.3-flash provider=fireworks/serverless "
    "attempts=2 retry=first_event prepare_ms=- connect_ms=- first_frame_ms=- "
    "first_token_ms=- stream_ms=- total_ms=60000 wasted_ms=30000 prompt_tokens=- "
    "prompt_tokens_est=1000 completion_tokens=-",
]


def test_parse_log_line_reads_fields_and_dash_as_none():
    rec = runs.parse_log_line(LOG_LINES[0])
    assert rec["ok"] and rec["model"] == "z-ai/glm-5.3-flash"
    assert rec["first_token_ms"] == 950.0 and rec["wasted_ms"] is None
    assert rec["prompt_tokens"] == 33000 and rec["attempts"] == 1
    assert runs.parse_log_line(LOG_LINES[1]) is None
    failed = runs.parse_log_line(LOG_LINES[2])
    assert not failed["ok"] and failed["status"] == "failed[timeout]"
    assert failed["first_frame_ms"] is None and failed["wasted_ms"] == 30000.0


def test_summarize_log():
    summary = runs.summarize_log(runs.parse_log(LOG_LINES))
    assert summary["overall"]["calls"] == 2 and summary["overall"]["failed"] == 1
    assert summary["overall"]["first_token_ms"]["n"] == 1
    assert summary["overall"]["total_ms"]["max"] == 60000
    assert set(summary["by_model"]) == {
        "runanywhere/serverless | z-ai/glm-5.3-flash",
        "fireworks/serverless | z-ai/glm-5.3-flash",
    }
    assert "backend model calls" in runs.render_log_text(summary)
