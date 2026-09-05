"""The executor persists subagent / file / approval frames as it streams them
and replays them (docs/WIRE_CONTRACT.md, "Persisted subagent / file / approval
events", bead cowork-266)."""

from __future__ import annotations

import base64
import threading
import time
from types import SimpleNamespace

from cowork_agent import MockModelClient, StateStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _model() -> MockModelClient:
    return MockModelClient(["unused"])


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


def _no_kill() -> SimpleNamespace:
    return SimpleNamespace(interrupted=lambda: False, estop_engaged=lambda: False)


def _publish_request() -> SimpleNamespace:
    return SimpleNamespace(
        path="site", name="My site", file_count=2, total_bytes=1234,
        base_url="here.now", public=True,
    )


def test_persisted_events_replay_in_thread_order_marked_replay(tmp_path):
    db_path = str(tmp_path / "state.db")
    store = StateStore(db_path)
    sid = store.route("thread-1")
    store.append_message(sid, "user", {"role": "user", "content": "draw it"})
    store.append_message(sid, "assistant", {"role": "assistant", "content": "here"})
    raw = b"PNGDATA"
    store.append_event(sid, {"type": "file", "name": "a.png", "mime_type": "image/png", "size": len(raw), "data": base64.b64encode(raw).decode()})
    store.append_event(sid, {"type": "subagent", "event": {"type": "subagent_state", "subagent_id": "sa_1", "title": "helper", "state": "succeeded", "result": "done"}})
    store.append_event(sid, {"type": "approval_request", "approval_id": "ap1", "action": "herenow_publish", "path": "site", "name": "site", "file_count": 1, "total_bytes": 9, "base_url": "here.now", "public": True, "decision": "denied", "decision_reason": "timeout", "decided_at": 3.0})
    store.close()

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    controller = ControllerSession(endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener)
    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    kinds = [e["type"] for e in events]
    assert kinds == ["run_state", "user", "delta", "file", "subagent", "approval_request", "done"]
    file, sub, approval = events[3], events[4], events[5]
    assert file["replay"] is True and base64.b64decode(file["data"]) == raw
    assert sub["replay"] is True and sub["event"]["subagent_id"] == "sa_1"
    assert approval["replay"] is True and approval["decision"] == "denied"
    assert events[2]["mid"] < file["mid"] < sub["mid"] < approval["mid"]


def test_the_approval_gate_persists_the_request_and_the_users_decision(tmp_path):
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    sent: list[dict] = []
    executor._event = lambda rid, payload: sent.append(payload)  # type: ignore[method-assign]

    gate = executor._make_approval_gate("req-1", _no_kill(), "thread-1")
    outcome: list[bool] = []
    worker = threading.Thread(target=lambda: outcome.append(gate(_publish_request())))
    worker.start()
    deadline = time.monotonic() + 5
    while not sent and time.monotonic() < deadline:
        time.sleep(0.01)
    assert sent and sent[0]["type"] == "approval_request"
    # The frame names its thread, so the app prompts over the right one (F9).
    assert sent[0]["session_key"] == "thread-1"
    approval_id = sent[0]["approval_id"]

    # The row exists before the user answers, with no decision yet.
    store = StateStore(db_path)
    sid = store.route("thread-1")
    (row,) = store.replay_events(sid)
    assert row["type"] == "approval_request" and row["approval_id"] == approval_id
    assert "decision" not in row

    executor._resolve_approval({"approval_id": approval_id, "approved": True})
    worker.join(5)
    assert outcome == [True]

    (row,) = store.replay_events(sid)
    assert row["decision"] == "approved" and row["decision_reason"] == "user"
    assert row["decided_at"] > 0
    store.close()


def test_a_stopped_approval_is_recorded_as_denied(tmp_path):
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    executor._event = lambda rid, payload: None  # type: ignore[method-assign]
    stop = threading.Event()
    kill = SimpleNamespace(interrupted=stop.is_set, estop_engaged=lambda: False)

    gate = executor._make_approval_gate("req-1", kill, "thread-1")
    outcome: list[bool] = []
    worker = threading.Thread(target=lambda: outcome.append(gate(_publish_request())))
    worker.start()
    time.sleep(0.05)
    stop.set()
    worker.join(5)
    assert outcome == [False]

    store = StateStore(db_path)
    (row,) = store.replay_events(store.route("thread-1"))
    assert row["decision"] == "denied" and row["decision_reason"] == "stopped"
    store.close()


def test_subagent_state_is_persisted_but_output_is_not(tmp_path):
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    sent: list[dict] = []
    executor._event = lambda rid, payload: sent.append(payload)  # type: ignore[method-assign]

    executor._emit_subagent("req-1", "thread-1", {"type": "subagent_state", "subagent_id": "sa_1", "title": "t", "state": "running"})
    executor._emit_subagent("req-1", "thread-1", {"type": "subagent_output", "subagent_id": "sa_1", "text": "chunk"})
    executor._emit_subagent("req-1", "thread-1", {"type": "subagent_state", "subagent_id": "sa_1", "title": "t", "state": "succeeded", "result": "ok"})

    assert [p["event"]["type"] for p in sent] == ["subagent_state", "subagent_output", "subagent_state"]
    store = StateStore(db_path)
    events = store.replay_events(store.route("thread-1"))
    assert [e["event"]["state"] for e in events] == ["running", "succeeded"]
    assert all(e["type"] == "subagent" and e["replay"] for e in events)
    store.close()


def test_a_sent_file_is_persisted_before_it_streams(tmp_path):
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    order: list[str] = []

    def spy(rid, payload):
        store = StateStore(db_path)
        try:
            order.append("stored" if store.replay_events(store.route("thread-1")) else "missing")
        finally:
            store.close()

    executor._event = spy  # type: ignore[method-assign]
    executor._emit_persisted("req-1", "thread-1", {"type": "file", "name": "a.txt", "mime_type": "text/plain", "size": 2, "data": base64.b64encode(b"hi").decode()})
    assert order == ["stored"]


def test_a_timed_out_approval_is_recorded_as_denied_timeout(tmp_path, monkeypatch):
    # Bead cowork-b12: the wait length and the reason string must not share a
    # name, or the stamp raises and the row stays open.
    import cowork_executor.executor as executor_module

    monkeypatch.setattr(executor_module, "APPROVAL_WAIT_SECONDS", 0.05)
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep)
    executor._event = lambda rid, payload: None  # type: ignore[method-assign]

    gate = executor._make_approval_gate("req-1", _no_kill(), "thread-1")
    assert gate(_publish_request()) is False

    store = StateStore(db_path)
    (row,) = store.replay_events(store.route("thread-1"))
    assert row["decision"] == "denied"
    assert row["decision_reason"] == "timeout"
    store.close()
