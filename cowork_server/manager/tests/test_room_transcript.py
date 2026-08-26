"""RoomTranscriptStore (§16.1): a room's conversation survives, ordered."""

from __future__ import annotations

from cowork_manager import RoomTranscriptStore, RoomTurn


def _turn(round, handle, text):
    return RoomTurn(round=round, agent_id=f"id-{handle}", handle=handle, text=text)


def test_append_and_history_preserve_spoken_order():
    store = RoomTranscriptStore()
    store.append("r1", _turn(1, "amber", "first"))
    store.append("r1", _turn(1, "cobalt", "second"))
    store.append("r1", _turn(2, "amber", "third"))
    history = store.history("r1")
    assert [(t.round, t.handle, t.text) for t in history] == [
        (1, "amber", "first"),
        (1, "cobalt", "second"),
        (2, "amber", "third"),
    ]


def test_sequence_orders_repeated_rounds_correctly():
    # Round numbers repeat across exchanges, so they cannot order the table; the
    # per-room seq must. Two turns both in "round 1" keep their append order.
    store = RoomTranscriptStore()
    store.append("r1", _turn(1, "amber", "a"))
    store.append("r1", _turn(1, "cobalt", "b"))
    assert [t.text for t in store.history("r1")] == ["a", "b"]


def test_rooms_do_not_share_a_sequence():
    store = RoomTranscriptStore()
    store.append("r1", _turn(1, "amber", "r1-a"))
    store.append("r2", _turn(1, "cobalt", "r2-a"))
    store.append("r1", _turn(1, "amber", "r1-b"))
    assert [t.text for t in store.history("r1")] == ["r1-a", "r1-b"]
    assert [t.text for t in store.history("r2")] == ["r2-a"]


def test_append_returns_the_sequence():
    store = RoomTranscriptStore()
    assert store.append("r1", _turn(1, "amber", "a")) == 1
    assert store.append("r1", _turn(1, "cobalt", "b")) == 2


def test_clear_drops_a_rooms_history_only():
    store = RoomTranscriptStore()
    store.append("r1", _turn(1, "amber", "a"))
    store.append("r2", _turn(1, "cobalt", "b"))
    assert store.clear("r1") == 1
    assert store.history("r1") == []
    assert [t.text for t in store.history("r2")] == ["b"]


def test_history_of_an_unknown_room_is_empty():
    assert RoomTranscriptStore().history("nope") == []


def test_persists_across_reopen(tmp_path):
    path = str(tmp_path / "t.db")
    store = RoomTranscriptStore(path)
    store.append("r1", _turn(1, "amber", "kept"))
    store.close()

    reopened = RoomTranscriptStore(path)
    assert [t.text for t in reopened.history("r1")] == ["kept"]
    reopened.close()
