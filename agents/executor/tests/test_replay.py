"""Transcript replay: a reconnecting client re-streams a thread from the server.

The server holds the authoritative transcript (see ``docs/PRODUCT_PHILOSOPHY``).
A fresh or reinstalled client sends one ``replay`` frame and gets the whole
thread back as the SAME ``user`` / ``delta`` / ``tool`` events a live run
streams, each marked ``replay``, then a terminal ``done``. No model runs.
"""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, StateStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _model() -> MockModelClient:
    # Never used by a replay: it opens no loop. Present only because the
    # executor requires a factory.
    return MockModelClient(["unused"])


def _seed_thread(db_path: str, session_key: str) -> None:
    """Write one whole turn to the store the executor will replay from."""
    store = StateStore(db_path)
    sid = store.route(session_key)
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
                    "function": {
                        "name": "run_command",
                        "arguments": {"command": "touch a.txt"},
                    },
                }
            ],
        },
    )
    store.append_message(
        sid,
        "tool",
        {
            "role": "tool",
            "tool_call_id": "call_1",
            "name": "run_command",
            "content": "created a.txt",
        },
    )
    store.append_message(
        sid, "assistant", {"role": "assistant", "content": "done, made a.txt"}
    )
    store.close()


def _executor(tmp_path, db_path, channel, executor_ep) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="replayer",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=db_path,
        model_factory=_model,
    )


def test_replay_restreams_the_whole_thread_marked_replay(tmp_path):
    db_path = str(tmp_path / "state.db")
    _seed_thread(db_path, "thread-1")

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    # The stored turn comes back in live shapes: first the run-state header
    # (docs/WIRE_CONTRACT.md), then user ask, the tool call with its result
    # folded in, then the assistant's final text. System is dropped.
    kinds = [e["type"] for e in events]
    assert kinds == ["run_state", "user", "tool", "delta", "done"]

    state, user, tool, delta, done = events
    # No run is in flight for this thread: the header says idle.
    assert state["state"] == "idle" and state["session_key"] == "thread-1"
    # Every replayed row carries its message id, the client's replay cursor.
    assert user["mid"] < tool["mid"] < delta["mid"]
    # Every non-terminal event is flagged replay, so the client never mistakes it
    # for a live run.
    assert user["replay"] is True
    assert tool["replay"] is True
    assert delta["replay"] is True

    assert user["text"] == "make a file"
    assert tool["name"] == "run_command"
    # One shape, live and replayed (docs/WIRE_CONTRACT.md, "Tool events and
    # timestamps"): the native arguments as an object, `command` as the plain
    # command line for run_command, the result as text, a status, the clocks.
    assert tool["arguments"] == {"command": "touch a.txt"}
    assert tool["command"] == "touch a.txt"
    assert tool["result"] == "created a.txt"
    assert tool["status"] == "completed"
    assert tool["started_at"] <= tool["completed_at"]
    assert delta["text"] == "done, made a.txt"

    # The terminal done marks the replay so the client leaves its loading state
    # without rendering a "done" card or reading it as a finished/stopped run.
    assert done["reason"] == "replay"
    assert done["replay"] is True
    assert done["final_answer"] is None

    # No command actually ran: replay never touches the sandbox.
    assert not (tmp_path / "ws" / "a.txt").exists()


def test_replay_of_unknown_thread_is_an_empty_stream(tmp_path):
    db_path = str(tmp_path / "state.db")
    # No seeding: the thread has never been used.
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "never"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    # Just the header and the terminal: an unknown thread is safe to ask for and
    # replays empty.
    assert [e["type"] for e in events] == ["run_state", "done"]
    assert events[0]["state"] == "idle"
    assert events[1]["reason"] == "replay"


def test_replay_cursor_returns_only_the_rows_after_it(tmp_path):
    """A client that holds the thread up to a message id asks with ``after_id``
    and gets only what came later (docs/WIRE_CONTRACT.md)."""
    db_path = str(tmp_path / "state.db")
    _seed_thread(db_path, "thread-1")
    store = StateStore(db_path)
    sid = store.route("thread-1")
    # Everything up to (and including) the tool call is already on the client.
    all_events = store.replay_events(sid)
    cursor = all_events[1]["mid"]  # the tool event
    store.close()

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "replay", "session_key": "thread-1", "after_id": cursor}
        )
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    # Header, then only the final assistant text, then the history-end marker.
    assert [e["type"] for e in events] == ["run_state", "delta", "done"]
    assert events[1]["text"] == "done, made a.txt"
    assert events[1]["mid"] > cursor


def test_a_finished_run_is_replayed_with_its_done_after_its_last_turn(tmp_path):
    """A run recorded as finished on the host comes back as a real completion
    card placed after its last message, flagged ``while_away`` when nobody
    acknowledged it (docs/WIRE_CONTRACT.md)."""
    db_path = str(tmp_path / "state.db")
    store = StateStore(db_path)
    sid = store.route("thread-1")
    store.begin_run("run-1", sid, "thread-1", "make a file")
    store.append_message(sid, "user", {"role": "user", "content": "make a file"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "made it"})
    store.finish_run(
        "run-1", reason="finished", final_answer="made it", iterations=2, tokens_spent=7
    )
    store.close()

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    assert [e["type"] for e in events] == ["run_state", "user", "delta", "done", "done"]
    run_done, history_end = events[3], events[4]
    # The run's own terminal: a finished run, replayed, unacknowledged.
    assert run_done["replay"] is True
    assert run_done["reason"] == "finished"
    assert run_done["run_id"] == "run-1"
    assert run_done["while_away"] is True
    assert run_done["final_answer"] == "made it"
    assert run_done["tokens_spent"] == 7
    # The stream still closes with the history-end marker, unchanged.
    assert history_end["reason"] == "replay"


def test_run_state_reports_a_run_recorded_as_running(tmp_path):
    db_path = str(tmp_path / "state.db")
    store = StateStore(db_path)
    sid = store.route("thread-1")
    store.begin_run("run-9", sid, "thread-1", "count to 20")
    store.close()

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    state = events[0]
    assert state["type"] == "run_state" and state["state"] == "running"
    assert state["run_id"] == "run-9" and state["prompt"] == "count to 20"
