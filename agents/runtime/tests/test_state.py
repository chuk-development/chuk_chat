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


def test_replay_events_carry_a_cursor_and_honour_after_id(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-A")
    store.append_message(sid, "user", {"role": "user", "content": "one"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "two"})
    store.append_message(sid, "user", {"role": "user", "content": "three"})

    events = store.replay_events(sid)
    mids = [e["mid"] for e in events]
    # Every event names its row id, strictly increasing in stored order.
    assert mids == sorted(mids) and len(set(mids)) == 3
    # The cursor: only the rows after it come back.
    later = store.replay_events(sid, after_id=mids[1])
    assert [e["text"] for e in later] == ["three"]
    assert store.replay_events(sid, after_id=mids[-1]) == []


def test_run_records_round_trip_and_replay_as_terminals(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-A")
    store.begin_run("run-1", sid, "session-A", "do it")
    run = store.get_run("run-1")
    assert run["state"] == "running" and run["first_mid"] == 0
    store.append_message(sid, "user", {"role": "user", "content": "do it"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "did it"})
    store.finish_run("run-1", reason="finished", final_answer="did it", iterations=1, tokens_spent=3)

    run = store.get_run("run-1")
    assert run["state"] == "finished" and run["final_answer"] == "did it"
    assert run["last_mid"] == store.max_message_id(sid)
    assert store.latest_run("session-A")["run_id"] == "run-1"

    # The terminal replays after the run's last turn, unacknowledged.
    terminals = store.run_terminals("session-A")
    assert len(terminals) == 1
    done = terminals[0]
    assert done["type"] == "done" and done["replay"] is True
    assert done["run_id"] == "run-1" and done["while_away"] is True
    assert done["mid"] == run["last_mid"]
    # A client past the cursor does not get it again.
    assert store.run_terminals("session-A", after_id=run["last_mid"]) == []


def test_mark_run_notified_fires_once(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-A")
    store.begin_run("run-1", sid, "session-A", "x")
    store.append_message(sid, "user", {"role": "user", "content": "x"})
    store.finish_run("run-1", reason="finished", final_answer="y", iterations=1, tokens_spent=0)
    assert store.mark_run_notified("run-1") is True
    assert store.mark_run_notified("run-1") is False
    # A notification going out does not mean the user opened the app: the
    # terminal still reads as "finished while away" until the app acks it.
    assert store.run_terminals("session-A")[0]["while_away"] is True
    assert store.mark_run_seen("run-1") is True
    assert store.mark_run_seen("run-1") is False
    assert store.run_terminals("session-A")[0]["while_away"] is False


def test_fail_run_and_orphan_sweep(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-A")
    store.begin_run("run-1", sid, "session-A", "a")
    store.fail_run("run-1", reason="loop failed: Boom")
    assert store.get_run("run-1")["state"] == "failed"
    # A run still running at host start was cut off: the sweep closes it.
    store.begin_run("run-2", sid, "session-A", "b")
    assert store.sweep_orphan_runs() == 1
    swept = store.get_run("run-2")
    assert swept["state"] == "failed" and swept["reason"] == "host_restarted"
    assert store.sweep_orphan_runs() == 0
