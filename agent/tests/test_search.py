"""Full-text session search (§12 B).

Four properties: hits are found in every script the three tables cover, BM25
ranks the better match first, a user's search string cannot become FTS5 syntax,
and every hit comes back as a bounded anchored window with bookends.
"""

from __future__ import annotations

from cowork_agent import LocalEnvironment, MockModelClient, ToolRegistry, build_runtime
from cowork_agent.search import sanitize_match, segment_cjk
from cowork_agent.state import StateStore


def _store(tmp_path, name: str = "s.db") -> StateStore:
    return StateStore(str(tmp_path / name))


def _seed(store: StateStore, session_key: str, texts: list[str]) -> tuple[int, list[int]]:
    session_id = store.route(session_key)
    ids = [
        store.append_message(session_id, "user", {"role": "user", "content": text})
        for text in texts
    ]
    return session_id, ids


# -- finding ---------------------------------------------------------------


def test_a_hit_is_found_across_sessions(tmp_path):
    store = _store(tmp_path)
    _seed(store, "old", ["we decided to deploy through Dokploy"])
    _seed(store, "new", ["unrelated chatter"])

    result = store.search_messages("Dokploy")
    assert result["ok"] is True
    assert result["count"] == 1
    assert "Dokploy" in result["hits"][0]["window"][0]["text"]


def test_a_search_can_be_pinned_to_one_session(tmp_path):
    store = _store(tmp_path)
    old, _ = _seed(store, "old", ["the release tag is v1.0.93"])
    new, _ = _seed(store, "new", ["the release tag is v2.0.0"])

    assert store.search_messages("release tag")["count"] == 2
    scoped = store.search_messages("release tag", session_id=new)
    assert scoped["count"] == 1
    assert scoped["hits"][0]["session_id"] == new
    assert old != new


def test_the_index_is_kept_in_sync_by_triggers_and_backfilled_on_open(tmp_path):
    """Rows written before the index existed must still be findable, and rows
    written after must land without an explicit index call."""
    path = str(tmp_path / "s.db")
    store = StateStore(path)
    session_id = store.route("s")
    store.append_message(session_id, "user", {"role": "user", "content": "keyword alpha"})
    # drop the mirror, as an older database would be
    conn = store._conn()  # noqa: SLF001 — the point of the test is the rebuild
    conn.executescript(
        "DROP TRIGGER messages_fts_ai;"
        "DROP TABLE messages_fts;"
        "DROP TABLE messages_fts_cjk;"
        "DROP TABLE messages_fts_tri;"
    )
    store.close()

    reopened = StateStore(path)
    assert reopened.search_messages("alpha")["count"] == 1  # backfilled
    sid = reopened.route("s")
    reopened.append_message(sid, "user", {"role": "user", "content": "keyword beta"})
    assert reopened.search_messages("beta")["count"] == 1  # trigger


def test_tool_calls_stay_searchable_even_with_no_text_content(tmp_path):
    store = _store(tmp_path)
    session_id = store.route("s")
    store.append_message(
        session_id,
        "assistant",
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "call_0",
                    "type": "function",
                    "function": {"name": "write_file", "arguments": {"path": "notes.md"}},
                }
            ],
        },
    )
    assert store.search_messages("notes.md")["count"] == 1


# -- the three tables ------------------------------------------------------


def test_cjk_text_is_found_by_a_two_character_query(tmp_path):
    """A CJK run is one token to unicode61; the segmented table is what makes a
    short query work."""
    store = _store(tmp_path)
    _seed(store, "s", ["深度学习模型训练", "nothing to do with it"])
    result = store.search_messages("学习")
    assert result["count"] == 1
    assert "深度学习" in result["hits"][0]["window"][0]["text"]


def test_a_substring_query_is_served_by_the_trigram_table(tmp_path):
    store = _store(tmp_path)
    _seed(store, "s", ["the department owns the rollout"])
    assert store.search_messages("epartme")["count"] == 1


def test_segment_cjk_leaves_latin_text_out_of_the_cjk_table():
    assert segment_cjk("plain latin text") == ""
    assert segment_cjk("学习") == " 学  习 "


# -- ranking ---------------------------------------------------------------


def _anchor_text(hit: dict) -> str:
    return next(m["text"] for m in hit["window"] if m["id"] == hit["message_id"])


def test_bm25_ranks_the_denser_match_first(tmp_path):
    store = _store(tmp_path)
    texts = [f"unrelated chatter number {index}" for index in range(8)]
    texts.append(
        "one passing mention of deployment inside a long paragraph that talks "
        "about many other unrelated topics at some length"
    )
    texts.append("deployment deployment deployment")
    _seed(store, "s", texts)

    hits = store.search_messages("deployment")["hits"]
    assert len(hits) == 2
    assert _anchor_text(hits[0]) == "deployment deployment deployment"
    assert hits[0]["score"] > hits[1]["score"]


# -- MATCH sanitizing ------------------------------------------------------


def test_operators_and_quotes_become_literal_terms():
    assert sanitize_match('deploy* OR NEAR(x)') == '"deploy" "OR" "NEAR" "x"'
    assert sanitize_match('say "hello"') == '"say" "hello"'
    assert sanitize_match('   ') == ""
    assert sanitize_match('*** ^^^') == ""


def test_fts_syntax_in_a_query_neither_raises_nor_changes_the_search(tmp_path):
    store = _store(tmp_path)
    _seed(store, "s", ["the deployment finished", "rollback finished"])
    for hostile in (
        'deployment*',
        '"deployment',
        'deployment OR rollback',
        'NEAR(deployment rollback, 2)',
        'deployment AND (rollback',
        'deployment"; DROP TABLE messages; --',
    ):
        result = store.search_messages(hostile)
        assert result["ok"] is True
        assert isinstance(result["hits"], list)
    # the store is intact and the plain query still works
    assert store.search_messages("deployment")["count"] == 1


def test_an_empty_query_is_an_error_not_a_full_table_scan(tmp_path):
    store = _store(tmp_path)
    _seed(store, "s", ["something"])
    result = store.search_messages("   ")
    assert result["ok"] is False
    assert result["hits"] == []


# -- anchored windows ------------------------------------------------------


def test_a_hit_comes_back_with_five_messages_either_side_plus_bookends(tmp_path):
    store = _store(tmp_path)
    texts = [f"filler message {index}" for index in range(10)]
    texts.append("the anchor mentions Nextcloud")
    texts.extend(f"trailing message {index}" for index in range(10))
    session_id, ids = _seed(store, "s", texts)

    hit = store.search_messages("Nextcloud")["hits"][0]
    window = hit["window"]
    assert len(window) == 11
    assert window[5]["id"] == hit["message_id"]
    assert [m["id"] for m in window] == ids[5:16]
    assert hit["bookends"]["first"]["id"] == ids[0]
    assert hit["bookends"]["last"]["id"] == ids[-1]
    assert hit["session_id"] == session_id


def test_a_bookend_already_inside_the_window_is_not_repeated(tmp_path):
    store = _store(tmp_path)
    _, ids = _seed(store, "s", ["anchor Nextcloud", "second", "third"])
    # window=0 isolates the hit, so the bookends are the only extra context
    hit = store.search_messages("Nextcloud", window=0)["hits"][0]
    assert "first" not in hit["bookends"]  # the hit IS the first message
    assert hit["bookends"]["last"]["id"] == ids[-1]

    # with the default window the whole short session already fits, so neither
    # bookend is sent twice
    wide = store.search_messages("Nextcloud")["hits"][0]
    assert wide["bookends"] == {}
    assert [m["id"] for m in wide["window"]] == ids


def test_the_window_and_hit_count_are_capped(tmp_path):
    store = _store(tmp_path)
    _seed(store, "s", [f"anchor {index}" for index in range(60)])
    result = store.search_messages("anchor", limit=999, window=999)
    assert result["count"] == 20  # MAX_HITS
    assert all(len(hit["window"]) <= 21 for hit in result["hits"])  # MAX_WINDOW


def test_message_text_in_a_result_is_clipped(tmp_path):
    store = _store(tmp_path)
    _seed(store, "s", ["Nextcloud " + "padding " * 200])
    text = store.search_messages("Nextcloud")["hits"][0]["window"][0]["text"]
    assert len(text) <= 240


# -- the tool --------------------------------------------------------------


def test_search_chats_is_registered_and_dispatches(tmp_path):
    model = MockModelClient(["done"])
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "s.db"),
        environment=LocalEnvironment(),
        workspace=str(tmp_path / "ws"),
    )
    loop.run("s1", "the magic word is Feldsalat")

    registry: ToolRegistry = loop.registry
    assert registry.has("search_chats")
    result = registry.dispatch("search_chats", {"query": "Feldsalat"})
    assert result["ok"] is True
    assert result["count"] == 1
    assert "search_chats" in loop.store.get_conversation(1)[0].content["content"]
