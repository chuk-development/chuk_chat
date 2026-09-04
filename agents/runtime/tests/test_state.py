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


def test_replay_events_rebuild_the_thread_in_live_shapes(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-A")
    # A whole turn: system seed, user ask, assistant tool call, its result, and
    # the assistant's final text answer.
    store.append_message(sid, "system", {"role": "system", "content": "be quiet"})
    store.append_message(sid, "user", {"role": "user", "content": "make a file"})
    store.append_message(
        sid,
        "assistant",
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "write_file", "arguments": {"path": "a.txt"}},
                }
            ],
        },
    )
    store.append_message(
        sid,
        "tool",
        {"role": "tool", "tool_call_id": "call_1", "name": "write_file", "content": "wrote a.txt"},
    )
    store.append_message(sid, "assistant", {"role": "assistant", "content": "done, it is a.txt"})

    events = store.replay_events(sid)
    # System is dropped; the other four rows map to four events, in stored order.
    assert [e["type"] for e in events] == ["user", "tool", "delta"]
    # Every event is marked as a replay, so a client never mistakes it for live.
    assert all(e["replay"] is True for e in events)

    user, tool, delta = events
    assert user["text"] == "make a file"
    # The tool event uses the live tool shape; its result fills stdout.
    assert tool["name"] == "write_file"
    assert tool["stdout"] == "wrote a.txt"
    assert tool["exit_code"] == 0 and tool["timed_out"] is False
    assert delta["text"] == "done, it is a.txt"


def test_replay_events_survive_a_reopen(tmp_path):
    path = str(tmp_path / "s.db")
    store = StateStore(path)
    sid = store.route("session-A")
    store.append_message(sid, "user", {"role": "user", "content": "hi"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "there"})
    store.close()

    # A reinstalled client: a fresh store on the same file replays the thread.
    store2 = StateStore(path)
    events = store2.replay_events(store2.route("session-A"))
    assert [e["type"] for e in events] == ["user", "delta"]
    assert events[0]["text"] == "hi"
    assert events[1]["text"] == "there"
