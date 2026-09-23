"""Replay paging in the store (Bead cowork-axx, docs/WIRE_CONTRACT.md "Replay
paging"): ``replay_page_bounds`` picks the newest N turn rows of a window,
``replay_events`` / ``run_terminals`` honour ``before_id``. No paging = today's
behaviour, byte for byte."""

from __future__ import annotations

from chuk_agents_runtime import StateStore


def _store(tmp_path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _seed(store: StateStore, session_key: str, turns: int) -> tuple[int, list[int]]:
    """``turns`` user/assistant pairs, each answer closed by a run. Returns the
    session id and the ids of the user rows, in order."""
    sid = store.route(session_key)
    store.append_message(sid, "system", {"role": "system", "content": "sys"})
    user_ids: list[int] = []
    for n in range(turns):
        user_ids.append(store.append_message(sid, "user", {"role": "user", "content": f"q{n}"}))
        store.begin_run(f"run-{n}", sid, session_key, f"q{n}")
        store.append_message(sid, "assistant", {"role": "assistant", "content": f"a{n}"})
        store.finish_run(f"run-{n}", reason="finished", final_answer=f"a{n}", iterations=1, tokens_spent=0)
    return sid, user_ids


def test_no_limit_means_no_paging(tmp_path):
    store = _store(tmp_path)
    try:
        sid, _ = _seed(store, "t", 5)
        assert store.replay_page_bounds(sid) == (0, False)
        assert store.replay_page_bounds(sid, after_id=7) == (7, False)
        # The unpaged replay is untouched: every turn, in order.
        texts = [e.get("text") or e.get("content") for e in store.replay_events(sid)]
        assert texts == [t for n in range(5) for t in (f"q{n}", f"a{n}")]
    finally:
        store.close()


def test_a_page_is_the_newest_n_turn_rows_and_says_whether_older_exist(tmp_path):
    store = _store(tmp_path)
    try:
        sid, user_ids = _seed(store, "t", 5)  # 10 turn rows
        # Newest 4 turn rows = q3 a3 q4 a4: the page starts at q3.
        page_after, more = store.replay_page_bounds(sid, limit=4)
        assert page_after == user_ids[3] - 1
        assert more is True
        events = store.replay_events(sid, after_id=page_after)
        assert [e.get("text") or e.get("content") for e in events] == ["q3", "a3", "q4", "a4"]
        # Its run terminals: only the runs whose last row is in the page.
        terminals = store.run_terminals("t", after_id=page_after)
        assert [t["run_id"] for t in terminals] == ["run-3", "run-4"]

        # The next, older page: below q3, again 4 rows = q1 a1 q2 a2, and one
        # more page (q0 a0) still exists.
        page_after2, more2 = store.replay_page_bounds(sid, before_id=page_after + 1, limit=4)
        assert page_after2 == user_ids[1] - 1
        assert more2 is True
        events2 = store.replay_events(sid, after_id=page_after2, before_id=page_after + 1)
        assert [e.get("text") or e.get("content") for e in events2] == ["q1", "a1", "q2", "a2"]
        assert [t["run_id"] for t in store.run_terminals("t", after_id=page_after2, before_id=page_after + 1)] == [
            "run-1",
            "run-2",
        ]

        # The last page: fewer rows than the limit, nothing older.
        page_after3, more3 = store.replay_page_bounds(sid, before_id=page_after2 + 1, limit=4)
        assert page_after3 == 0 and more3 is False
        events3 = store.replay_events(sid, before_id=page_after2 + 1)
        assert [e.get("text") or e.get("content") for e in events3] == ["q0", "a0"]
    finally:
        store.close()


def test_a_page_respects_the_cursor_below_it(tmp_path):
    store = _store(tmp_path)
    try:
        sid, user_ids = _seed(store, "t", 3)
        # The client already holds everything up to a1: a page of 10 above that
        # is just q2 a2, and nothing "older" is owed (the client has it).
        page_after, more = store.replay_page_bounds(sid, after_id=user_ids[2] - 1, limit=10)
        assert page_after == user_ids[2] - 1 and more is False
        # A tiny page inside the same window: q2 a2 fits in 2, no more above the cursor.
        page_after2, more2 = store.replay_page_bounds(sid, after_id=user_ids[2] - 1, limit=2)
        assert page_after2 == user_ids[2] - 1 and more2 is False
    finally:
        store.close()


def test_an_empty_thread_pages_to_nothing(tmp_path):
    store = _store(tmp_path)
    try:
        sid = store.route("empty")
        assert store.replay_page_bounds(sid, limit=50) == (0, False)
        assert store.replay_events(sid, before_id=1) == []
        assert store.run_terminals("empty", before_id=1) == []
    finally:
        store.close()
