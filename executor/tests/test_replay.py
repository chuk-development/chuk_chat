"""Transcript replay: a reconnecting client re-streams a thread from the server.

The server holds the authoritative transcript (see ``docs/PRODUCT_PHILOSOPHY``).
A fresh or reinstalled client sends one ``replay`` frame and gets the whole
thread back as the SAME ``user`` / ``delta`` / ``tool`` events a live run
streams, each marked ``replay``, then a terminal ``done``. No model runs.
"""

from __future__ import annotations

from cowork_agent import MockModelClient, StateStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair

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

    # The stored turn comes back in live shapes: user ask, the tool call with its
    # result folded in, then the assistant's final text. System is dropped.
    kinds = [e["type"] for e in events]
    assert kinds == ["user", "tool", "delta", "done"]

    user, tool, delta, done = events
    # Every non-terminal event is flagged replay, so the client never mistakes it
    # for a live run.
    assert user["replay"] is True
    assert tool["replay"] is True
    assert delta["replay"] is True

    assert user["text"] == "make a file"
    assert tool["name"] == "run_command"
    # Dict tool arguments come back as compact JSON — the shape ``state.py`` builds
    # for the ``command`` field; the client renders it as the call's arguments.
    assert tool["command"] == '{"command":"touch a.txt"}'
    assert tool["stdout"] == "created a.txt"
    assert tool["exit_code"] == 0 and tool["timed_out"] is False
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

    # Just the terminal: an unknown thread is safe to ask for and replays empty.
    assert [e["type"] for e in events] == ["done"]
    assert events[0]["reason"] == "replay"
