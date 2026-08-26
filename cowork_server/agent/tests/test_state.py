import threading

from cowork_agent.state import StateStore


def test_append_and_get_conversation_ordered_by_id(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.create_session()
    store.append_message(sid, "user", {"role": "user", "content": "one"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "two"})
    store.append_message(sid, "user", {"role": "user", "content": "three"})

    convo = store.get_conversation(sid)
    assert [m.content["content"] for m in convo] == ["one", "two", "three"]
    # strictly increasing autoincrement ids define the order
    ids = [m.id for m in convo]
    assert ids == sorted(ids)
    assert len(set(ids)) == 3


def test_resume_by_id_survives_a_reopen(tmp_path):
    path = str(tmp_path / "s.db")
    store = StateStore(path)
    sid = store.route("session-A")
    store.append_message(sid, "user", {"role": "user", "content": "hello"})
    store.close()

    # relaunch — a fresh store on the same file resolves the same session.
    store2 = StateStore(path)
    assert store2.route("session-A") == sid
    convo = store2.get_conversation(sid)
    assert convo[0].content["content"] == "hello"


def test_session_key_routing_is_stable(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    a1 = store.route("alpha")
    a2 = store.route("alpha")
    b1 = store.route("beta")
    assert a1 == a2
    assert b1 != a1
    assert store.resolve_session("alpha") == a1
    assert store.resolve_session("unknown") is None


def test_json_in_columns_roundtrip(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.create_session(meta={"k": "v"})
    payload = {"role": "tool", "content": {"nested": [1, 2, {"x": True}]}}
    store.append_message(sid, "tool", payload)
    got = store.get_conversation(sid)[0].content
    assert got == payload


def test_concurrent_writers_do_not_lose_rows(tmp_path):
    # BEGIN IMMEDIATE + jittered retry must serialize writers without loss.
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.create_session()

    def writer(n):
        for i in range(20):
            store.append_message(sid, "user", {"role": "user", "content": f"{n}-{i}"})

    threads = [threading.Thread(target=writer, args=(n,)) for n in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert len(store.get_conversation(sid)) == 80
