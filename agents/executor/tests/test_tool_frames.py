"""Tool frames come from the loop's dispatch, one per native tool call, live
and replayed alike; ``done`` carries the run's clock and rows
(docs/WIRE_CONTRACT.md, "Tool events and timestamps"; beads cowork-b45,
cowork-al2)."""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _model() -> MockModelClient:
    # write_file runs printf|base64 helper commands through the environment;
    # none of them may show up as a tool card. Then one real shell command.
    return MockModelClient(
        [
            tool_call_response(("write_file", {"path": "a.txt", "content": "hi"})),
            tool_call_response(("run_command", {"command": "cat a.txt"})),
            "done",
        ]
    )


def _executor(tmp_path, db_path, channel, executor_ep, model_factory) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="tooler",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=db_path,
        model_factory=model_factory,
    )


def _controller(channel, controller_ep) -> ControllerSession:
    return ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )


def _run(tmp_path, db_path, model_factory, payload: dict | None = None) -> list[dict]:
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep, model_factory)
    controller = _controller(channel, controller_ep)
    executor.start()
    try:
        if payload is None:
            rid = controller.send_task("write then read", session_key="thread-t")
        else:
            rid = controller.send_payload(payload)
        return controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()


def test_one_tool_frame_per_native_call_and_no_helper_commands(tmp_path):
    db_path = str(tmp_path / "state.db")
    events = _run(tmp_path, db_path, _model)

    tools = [e for e in events if e["type"] == "tool"]
    assert [t["name"] for t in tools] == ["write_file", "run_command"]

    write, cat = tools
    assert write["arguments"] == {"path": "a.txt", "content": "hi"}
    assert write["status"] == "completed"
    assert "command" not in write
    assert write["started_at"] <= write["completed_at"]
    assert not write.get("replay")

    assert cat["command"] == "cat a.txt"
    assert cat["exit_code"] == 0 and cat["stdout"].strip() == "hi"
    assert cat["status"] == "completed"
    assert cat["duration_ms"] >= 0
    # The file really was written: the helper commands ran, just not as cards.
    assert (tmp_path / "ws" / "a.txt").read_text() == "hi"

    done = events[-1]
    assert done["type"] == "done"
    # The run's clock and rows ride the live done; last_mid moves the app's
    # replay cursor past this run.
    assert done["started_at"] <= done["finished_at"]
    assert done["first_mid"] < done["last_mid"]
    store = StateStore(db_path)
    assert done["last_mid"] == store.max_message_id(store.route("thread-t"))
    store.close()


def test_replay_draws_the_same_tool_cards_and_the_same_done(tmp_path):
    db_path = str(tmp_path / "state.db")
    live = _run(tmp_path, db_path, _model)
    replayed = _run(
        tmp_path,
        db_path,
        lambda: MockModelClient(["unused"]),
        payload={"type": "replay", "session_key": "thread-t"},
    )

    def stable(event: dict) -> dict:
        return {
            k: v
            for k, v in event.items()
            if k not in ("replay", "mid", "started_at", "completed_at", "duration_ms")
        }

    live_tools = [stable(e) for e in live if e["type"] == "tool"]
    replay_tools = [stable(e) for e in replayed if e["type"] == "tool"]
    assert replay_tools == live_tools
    assert all(e["replay"] is True for e in replayed if e["type"] == "tool")
    # The replayed clocks are the rows': call row, then result row.
    for tool in (e for e in replayed if e["type"] == "tool"):
        assert tool["started_at"] <= tool["completed_at"]

    live_done = live[-1]
    # The replayed run terminal is the done before the history-end marker.
    replay_done = [e for e in replayed if e["type"] == "done" and e.get("run_id")][0]
    for key in ("started_at", "finished_at", "first_mid", "last_mid", "run_id"):
        assert replay_done[key] == live_done[key], key
