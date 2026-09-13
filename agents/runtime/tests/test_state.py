import threading

from chuk_agents_runtime.state import StateStore


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
    # The tool event uses the live tool shape (docs/WIRE_CONTRACT.md, "Tool
    # events and timestamps"): the native arguments as an object, the result
    # as text, a status, and the clocks of the call row and the result row.
    assert tool["name"] == "write_file"
    assert tool["call_id"] == "call_1"
    assert tool["arguments"] == {"path": "a.txt"}
    assert tool["result"] == "wrote a.txt"
    assert tool["status"] == "completed"
    # A string result projects no shell fields, and write_file has no command
    # line — never a JSON blob in `command`.
    assert "stdout" not in tool and "exit_code" not in tool and "command" not in tool
    assert tool["started_at"] <= tool["completed_at"]
    assert tool["duration_ms"] >= 0
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


def test_begin_run_records_the_model_the_task_asked_for(tmp_path):
    """A run must be provable afterwards: what model / provider / reasoning
    effort the task named (docs/WIRE_CONTRACT.md), NULL meaning the host default."""
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("s")
    store.begin_run(
        "r1", sid, "s", "do it", model="anthropic/claude-x", provider="anthropic", reasoning_effort="low"
    )
    store.begin_run("r2", sid, "s", "again")  # named nothing

    named = store.get_run("r1")
    assert named["model"] == "anthropic/claude-x"
    assert named["provider"] == "anthropic"
    assert named["reasoning_effort"] == "low"
    default = store.get_run("r2")
    assert default["model"] is None and default["provider"] is None
    assert default["reasoning_effort"] is None
    assert store.latest_run("s")["run_id"] == "r2"
    store.close()


def test_an_existing_database_without_the_model_columns_is_migrated_on_open(tmp_path):
    """The columns were added after ``runs`` first shipped. CREATE TABLE IF NOT
    EXISTS leaves an old table alone, so opening an old database must ALTER the
    missing columns in — additively, and only once."""
    import sqlite3

    path = tmp_path / "old.db"
    # Build a current database, then age it: drop the three columns so the file
    # looks exactly like one written before they existed (legacy row included).
    fresh = StateStore(str(path))
    sid = fresh.route("s")
    fresh.begin_run("legacy", sid, "s", "old prompt")
    fresh.close()
    old = sqlite3.connect(path)
    for column in ("model", "provider", "reasoning_effort"):
        old.execute(f"ALTER TABLE runs DROP COLUMN {column}")
    old.commit()
    assert "model" not in {r[1] for r in old.execute("PRAGMA table_info(runs)")}
    old.close()

    store = StateStore(str(path))
    columns = {row[1] for row in store._conn().execute("PRAGMA table_info(runs)").fetchall()}
    assert {"model", "provider", "reasoning_effort"} <= columns
    # The legacy row survives with NULLs, and new rows carry the fields.
    assert store.get_run("legacy")["model"] is None
    sid = store.route("s")
    store.begin_run("new", sid, "s", "p", model="m", provider="p", reasoning_effort="none")
    assert store.get_run("new")["reasoning_effort"] == "none"
    store.close()

    # Opening again is a no-op (no duplicate-column error).
    again = StateStore(str(path))
    assert again.get_run("new")["model"] == "m"
    again.close()


def test_replay_events_carry_the_turns_reasoning_before_its_text(tmp_path):
    """A stored assistant turn with ``reasoning`` replays as a ``reasoning``
    event first (the live thinking-chunk shape), then its ``delta`` / ``tool``
    events, all on the same row id, so the app rebuilds the thinking block
    above the answer exactly where it was live."""
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-R")
    store.append_message(sid, "user", {"role": "user", "content": "why?"})
    store.append_message(
        sid,
        "assistant",
        {
            "role": "assistant",
            "reasoning": "the user wants the cause, not a fix",
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "read_file", "arguments": {"path": "log"}},
                }
            ],
        },
    )
    store.append_message(
        sid,
        "tool",
        {"role": "tool", "tool_call_id": "call_1", "name": "read_file", "content": "boom"},
    )
    store.append_message(
        sid,
        "assistant",
        {"role": "assistant", "reasoning": "log says boom", "content": "because boom"},
    )
    # A turn with blank reasoning replays no reasoning event.
    store.append_message(
        sid, "assistant", {"role": "assistant", "reasoning": "  ", "content": "that is all"}
    )

    events = store.replay_events(sid)
    assert [e["type"] for e in events] == [
        "user", "reasoning", "tool", "reasoning", "delta", "delta",
    ]
    _, r1, tool, r2, delta, tail = events
    assert r1["text"] == "the user wants the cause, not a fix"
    assert r1["replay"] is True and r1["mid"] == tool["mid"]
    assert r2["text"] == "log says boom"
    assert r2["mid"] == delta["mid"] and delta["text"] == "because boom"
    assert tail["text"] == "that is all"


# -- retry: replacing a turn, not repeating it (bead cowork-bkw) -------------


def test_drop_last_user_turn_removes_the_question_and_its_answer(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.create_session()
    store.append_message(sid, "system", {"role": "system", "content": "be brief"})
    store.append_message(sid, "user", {"role": "user", "content": "first"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "a1"})
    store.append_message(sid, "user", {"role": "user", "content": "second"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "a2"})

    removed = store.drop_last_user_turn(sid)

    assert removed == 2
    assert [
        (m.content["role"], m.content["content"]) for m in store.get_conversation(sid)
    ] == [("system", "be brief"), ("user", "first"), ("assistant", "a1")]


def test_drop_last_user_turn_takes_tool_rows_with_it(tmp_path):
    """A retried turn may have run tools. Leaving the tool rows behind would
    hand the model a tool result answering a question that is no longer there."""
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.create_session()
    store.append_message(sid, "user", {"role": "user", "content": "q"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "calling"})
    store.append_message(
        sid, "tool", {"role": "tool", "tool_call_id": "c1", "content": "out"}
    )
    store.append_message(sid, "assistant", {"role": "assistant", "content": "done"})

    assert store.drop_last_user_turn(sid) == 4
    assert store.get_conversation(sid) == []


def test_drop_last_user_turn_keeps_the_system_prompt(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.create_session()
    store.append_message(sid, "system", {"role": "system", "content": "rules"})
    store.append_message(sid, "user", {"role": "user", "content": "q"})

    store.drop_last_user_turn(sid)

    convo = store.get_conversation(sid)
    assert [m.content["role"] for m in convo] == ["system"]


def test_drop_last_user_turn_on_a_session_with_no_question_is_a_no_op(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.create_session()
    store.append_message(sid, "system", {"role": "system", "content": "rules"})

    assert store.drop_last_user_turn(sid) == 0
    assert len(store.get_conversation(sid)) == 1


def test_a_retry_leaves_one_user_row_in_the_replay(tmp_path):
    """The reported bug, end to end at the store level: four retries used to
    replay as four copies of the same question."""
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("thread")
    store.append_message(sid, "user", {"role": "user", "content": "what is 2+2"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "five"})
    for attempt in ("four", "4", "four."):
        store.drop_last_user_turn(sid)
        store.append_message(sid, "user", {"role": "user", "content": "what is 2+2"})
        store.append_message(sid, "assistant", {"role": "assistant", "content": attempt})

    events = store.replay_events(sid)
    assert [e["type"] for e in events if e["type"] == "user"] == ["user"]
    assert [e["text"] for e in events if e["type"] == "delta"] == ["four."]


def test_replay_tool_events_project_shell_results_and_mark_failures(tmp_path):
    """A stored run_command result dict projects exit_code/stdout/stderr/
    timed_out to the top level (an old app reads them as before) and a
    non-zero exit is an ``error`` status; the call's clocks are the rows'."""
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-T")
    store.append_message(sid, "user", {"role": "user", "content": "ls"})
    store.append_message(
        sid,
        "assistant",
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "call_9",
                    "type": "function",
                    "function": {"name": "run_command", "arguments": {"command": "ls /nope"}},
                }
            ],
        },
    )
    store.append_message(
        sid,
        "tool",
        {
            "role": "tool",
            "tool_call_id": "call_9",
            "name": "run_command",
            "content": {"exit_code": 2, "stdout": "", "stderr": "No such file", "timed_out": False},
        },
    )
    rows = store.get_conversation(sid)
    (tool,) = [e for e in store.replay_events(sid) if e["type"] == "tool"]
    assert tool["command"] == "ls /nope"
    assert tool["arguments"] == {"command": "ls /nope"}
    assert tool["exit_code"] == 2 and tool["stderr"] == "No such file"
    assert tool["timed_out"] is False
    assert tool["status"] == "error"
    assert tool["started_at"] == rows[1].created_at
    assert tool["completed_at"] == rows[2].created_at
    assert tool["mid"] == rows[1].id


def test_run_terminals_carry_the_runs_clock_and_rows(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-D")
    store.append_message(sid, "user", {"role": "user", "content": "hi"})
    store.begin_run("run-1", sid, "session-D", "hi")
    store.append_message(sid, "assistant", {"role": "assistant", "content": "hello"})
    store.finish_run("run-1", reason="finished", final_answer="hello", iterations=1, tokens_spent=0)

    (done,) = store.run_terminals("session-D")
    row = store.get_run("run-1")
    assert done["started_at"] == row["started_at"]
    assert done["finished_at"] == row["finished_at"]
    assert done["started_at"] <= done["finished_at"]
    # first_mid is the cursor when the run began, last_mid the cursor at its end.
    assert done["first_mid"] == 1 and done["last_mid"] == 2
    assert done["mid"] == done["last_mid"]


def test_replay_skips_runtime_rows_that_are_not_the_users_or_the_models(tmp_path):
    """A memory-recall row or a skill-body row carries a wire role of ``user``
    but was never the user's message: it must not replay as a user bubble."""
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("session-M")
    store.append_message(sid, "user", {"role": "user", "content": "hi"})
    store.append_message(sid, "memory", {"role": "user", "content": "[memory recall]\n- x"})
    store.append_message(sid, "context", {"role": "user", "content": "skill body"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "hello"})
    assert [(e["type"], e["text"]) for e in store.replay_events(sid)] == [
        ("user", "hi"), ("delta", "hello"),
    ]
