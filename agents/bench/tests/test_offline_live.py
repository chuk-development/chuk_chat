"""The snapshot guard, the offline replay and the live wiring, on synthetic
databases built with the runtime's own StateStore. No model, no network."""

from __future__ import annotations

import json
import sqlite3

import pytest

from chuk_agents_bench import live, offline, snapshot
from chuk_agents_runtime import MockModelClient
from chuk_agents_runtime.state import StateStore

KEY = "local:test-agent:1:42"


def _make_session(path, *, turns=40, key=KEY):
    store = StateStore(str(path))
    sid = store.route(key)
    store.append_message(sid, "system", {"role": "system", "content": "You are a test agent."})
    for i in range(turns):
        store.append_message(sid, "user", {"role": "user", "content": f"question {i} " + "x" * 400})
        store.append_message(
            sid, "assistant", {"role": "assistant", "content": f"answer {i} " + "y" * 800}
        )
    store.append_message(sid, "user", {"role": "user", "content": "hi"})
    # An event row: replay-only, never part of the model's context.
    store.append_event(sid, {"type": "file", "name": "a.txt"})
    close = getattr(store, "close", None)
    if callable(close):
        close()
    return sid


@pytest.fixture
def state_home(tmp_path, monkeypatch):
    home = tmp_path / "live-home"
    home.mkdir()
    monkeypatch.setenv("AGENTS_HOME", str(home))
    return home


def test_snapshot_copies_and_refuses_to_write_into_live_dir(tmp_path, state_home):
    live_db = state_home / snapshot.STATE_DB_NAME
    _make_session(live_db, turns=2)
    copy = snapshot.snapshot(live_db, tmp_path / "copy.db")
    assert copy.is_file()
    conn = sqlite3.connect(copy)
    try:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
        assert conn.execute("SELECT count(*) FROM messages").fetchone()[0] >= 6
    finally:
        conn.close()
    with pytest.raises(ValueError):
        snapshot.snapshot(live_db, state_home / "copy.db")
    assert snapshot.is_live_path(live_db) and not snapshot.is_live_path(copy)
    # ensure_copy never hands back a path inside the live directory.
    assert not snapshot.is_live_path(snapshot.ensure_copy(copy))


def test_snapshot_drops_stale_wal_of_an_old_copy(tmp_path, state_home):
    live_db = state_home / snapshot.STATE_DB_NAME
    _make_session(live_db, turns=1)
    dest = tmp_path / "copy.db"
    snapshot.snapshot(live_db, dest)
    stale = tmp_path / "copy.db-wal"
    stale.write_bytes(b"not a wal")
    snapshot.snapshot(live_db, dest)
    assert not stale.exists()
    conn = sqlite3.connect(dest)
    try:
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    finally:
        conn.close()


def test_find_session_counts_only_model_rows(tmp_path):
    db = tmp_path / "s.db"
    sid = _make_session(db, turns=3)
    session_id, rows, size = offline.find_session(db, KEY)
    assert session_id == sid and rows == 1 + 3 * 2 + 1 and size > 0
    with pytest.raises(LookupError):
        offline.find_session(db, "nope")


def test_replay_times_every_step_and_counts_aux_calls(tmp_path):
    db = tmp_path / "s.db"
    _make_session(db, turns=60)
    result = offline.replay(
        db,
        KEY,
        passes=2,
        rounds=2,
        context_length=8_000,  # small window: forces tier 2 on ~30k tokens
        work_db=tmp_path / "work.db",
    )
    assert len(result.passes) == 2
    first = result.passes[0]
    for step in offline.PREPARE_STEPS:
        assert first.steps[step] >= 0
    assert first.prepare_ms == pytest.approx(
        sum(first.steps[s] for s in offline.PREPARE_STEPS), abs=0.01
    )
    assert [r["round"] for r in first.rounds] == [1, 2]
    assert first.rounds[0]["tier"] >= 2 and first.rounds[0]["tokens_after"] < first.rounds[0]["tokens_before"]
    assert first.summarizer_calls >= 1 and first.summarizer_transcript_chars > 0
    # The working copy is a fresh copy; the source copy is never written.
    assert offline.find_session(db, KEY)[1] == offline.find_session(tmp_path / "work.db", KEY)[1]
    data = json.loads(offline.render_json(result))
    assert data["steps"]["prepare_total"]["p50"] is not None
    text = offline.render_text(result, baseline=data)
    assert "prepare_total" in text and "aux summarizer calls" in text and "delta" in text


def test_replay_without_summarizer_stays_tier_one(tmp_path):
    db = tmp_path / "s.db"
    _make_session(db, turns=60)
    result = offline.replay(
        db, KEY, passes=1, summarizer="none", context_length=8_000, work_db=tmp_path / "w.db"
    )
    assert result.passes[0].summarizer_calls == 0
    assert result.passes[0].rounds[0]["tier"] <= 1


def test_stub_summarizer_counts_and_delays():
    stub = offline.StubSummarizer(delay_ms=5)
    text = stub.summarize("abc", None)
    assert stub.calls == 1 and stub.transcript_chars == 3 and stub.ms >= 4
    assert "bench stub summary" in text


def test_live_refuses_real_session_keys():
    with pytest.raises(ValueError):
        live.check_session_key("local:brisk-heron:2:116636868")
    assert live.new_session_key().startswith(live.SESSION_PREFIX)


def test_live_needs_env_credentials(monkeypatch):
    for name in live.ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(RuntimeError, match="environment variables"):
        live.session_from_env()


def test_run_live_with_a_scripted_model_and_a_seeded_session(tmp_path):
    source = tmp_path / "source.db"
    _make_session(source, turns=5)
    client = MockModelClient(["hello", "hello again"])
    result = live.run_live(
        client,
        prompts=["hi", "hi"],
        db_path=tmp_path / "live.db",
        seed_db=source,
        seed_session=KEY,
        with_aux=False,
    )
    assert result.session_key.startswith(live.SESSION_PREFIX)
    assert result.seeded_rows == 1 + 5 * 2 + 1
    assert [t.reason for t in result.turns] == ["finished", "finished"]
    assert all(t.wall_ms > 0 for t in result.turns)
    assert "prepare_ms" in result.turns[0].timings
    assert result.summary()["turns"] == 2
    assert "live  session bench:" in live.render_text(result)
