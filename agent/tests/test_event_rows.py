"""Persisted stream events (docs/WIRE_CONTRACT.md, "Persisted subagent / file /
approval events", bead cowork-266): ``event`` rows replay as the live frame,
stay out of the model's context, and an approval nobody answered is closed
with its run."""

from __future__ import annotations

import base64

from chuk_agents_runtime import StateStore


def _store(tmp_path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _seed_turn(store: StateStore, sid: int) -> None:
    store.append_message(sid, "user", {"role": "user", "content": "make a chart"})
    store.append_message(
        sid,
        "assistant",
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "run_python", "arguments": {"code": "plot()"}},
                }
            ],
        },
    )


def test_event_rows_stay_out_of_the_model_context(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    _seed_turn(store, sid)
    store.append_event(sid, {"type": "subagent", "event": {"type": "subagent_state", "subagent_id": "sa_1", "state": "running"}})

    roles = [m.role for m in store.get_conversation(sid)]
    assert roles == ["user", "assistant"], "the model never sees an event row"
    roles_all = [m.role for m in store.get_conversation(sid, include_events=True)]
    assert roles_all == ["user", "assistant", "event"]


def test_a_file_event_replays_with_its_bytes_and_a_small_row(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    _seed_turn(store, sid)
    raw = b"\x89PNG" + bytes(range(256))
    mid = store.append_event(
        sid,
        {
            "type": "file",
            "name": "chart.png",
            "mime_type": "image/png",
            "size": len(raw),
            "data": base64.b64encode(raw).decode("ascii"),
        },
    )
    # Result row lands AFTER the file (the tool sent it while running).
    store.append_message(
        sid,
        "tool",
        {"role": "tool", "tool_call_id": "call_1", "name": "run_python", "content": "sent chart.png"},
    )

    # The row's JSON carries no body; the bytes live in event_blobs.
    stored = [m for m in store.get_conversation(sid, include_events=True) if m.role == "event"]
    assert "data" not in stored[0].content
    assert store.event_blob(mid) == raw

    events = store.replay_events(sid)
    kinds = [e["type"] for e in events]
    assert kinds == ["user", "tool", "file"]
    tool, file = events[1], events[2]
    # The file in the middle did not split the call from its result.
    assert tool["result"] == "sent chart.png"
    assert file["replay"] is True and file["mid"] == mid
    assert file["name"] == "chart.png" and file["size"] == len(raw)
    assert base64.b64decode(file["data"]) == raw
    # Thread order: the file row came before the tool-result row, but the tool
    # event carries its CALL row's id, which came before the file.
    assert tool["mid"] < file["mid"]


def test_a_file_event_with_a_bad_body_replays_without_one(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    mid = store.append_event(sid, {"type": "file", "name": "x.bin", "mime_type": "application/octet-stream", "size": 3, "data": "@@not base64@@"})
    assert store.event_blob(mid) is None
    (event,) = store.replay_events(sid)
    assert event["type"] == "file" and "data" not in event


def test_the_replay_cursor_covers_event_rows(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    _seed_turn(store, sid)
    first = store.append_event(sid, {"type": "subagent", "event": {"type": "subagent_state", "subagent_id": "sa_1", "state": "queued"}})
    second = store.append_event(sid, {"type": "subagent", "event": {"type": "subagent_state", "subagent_id": "sa_1", "state": "succeeded", "result": "ok"}})

    events = store.replay_events(sid, after_id=first)
    assert [e["mid"] for e in events] == [second]
    assert events[0]["event"]["state"] == "succeeded"
    assert events[0]["replay"] is True


def test_an_approval_outcome_is_patched_into_its_row(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    mid = store.append_event(sid, {"type": "approval_request", "approval_id": "ap1", "action": "herenow_publish", "path": "site", "name": "site", "file_count": 3, "total_bytes": 10, "base_url": "here.now", "public": True})
    assert store.update_event(mid, {"decision": "approved", "decision_reason": "user", "decided_at": 5.0})
    (event,) = store.replay_events(sid)
    assert event["decision"] == "approved"
    assert event["decision_reason"] == "user"
    assert event["approval_id"] == "ap1"
    # Only event rows are patchable.
    other = store.append_message(sid, "user", {"role": "user", "content": "hi"})
    assert store.update_event(other, {"decision": "denied"}) is False


def test_an_unanswered_approval_is_closed_with_its_run(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    store.begin_run("run-1", sid, "t", "publish it")
    open_mid = store.append_event(sid, {"type": "approval_request", "approval_id": "ap1", "action": "herenow_publish", "path": "site", "name": "site", "file_count": 1, "total_bytes": 1, "base_url": "here.now", "public": True})
    done_mid = store.append_event(sid, {"type": "approval_request", "approval_id": "ap0", "action": "herenow_publish", "path": "old", "name": "old", "file_count": 1, "total_bytes": 1, "base_url": "here.now", "public": True, "decision": "approved", "decision_reason": "user", "decided_at": 1.0})

    store.fail_run("run-1", reason="loop failed")

    by_mid = {e["mid"]: e for e in store.replay_events(sid)}
    assert by_mid[open_mid]["decision"] == "denied"
    assert by_mid[open_mid]["decision_reason"] == "stopped"
    assert by_mid[done_mid]["decision"] == "approved", "a decided row is left alone"


def test_the_start_up_sweep_closes_orphaned_approvals(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    store.begin_run("run-1", sid, "t", "publish it")
    mid = store.append_event(sid, {"type": "approval_request", "approval_id": "ap1", "action": "herenow_publish", "path": "site", "name": "site", "file_count": 1, "total_bytes": 1, "base_url": "here.now", "public": True})

    assert store.sweep_orphan_runs() == 1

    (event,) = store.replay_events(sid)
    assert event["mid"] == mid
    assert event["decision"] == "denied" and event["decision_reason"] == "stopped"


def test_a_retry_drops_the_events_of_the_replaced_answer(tmp_path):
    store = _store(tmp_path)
    sid = store.route("t")
    store.append_message(sid, "user", {"role": "user", "content": "q1"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "a1"})
    store.append_event(sid, {"type": "file", "name": "a1.txt", "mime_type": "text/plain", "size": 1, "data": base64.b64encode(b"x").decode()})
    store.append_message(sid, "user", {"role": "user", "content": "q2"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "a2"})
    store.append_event(sid, {"type": "file", "name": "a2.txt", "mime_type": "text/plain", "size": 1, "data": base64.b64encode(b"y").decode()})

    store.drop_last_user_turn(sid)

    names = [e["name"] for e in store.replay_events(sid) if e["type"] == "file"]
    assert names == ["a1.txt"]
