"""Replay paging over the wire (Bead cowork-axx, docs/WIRE_CONTRACT.md "Replay
paging"): ``limit`` gets the newest page first, its history-end ``done``
carries ``has_more`` / ``oldest_mid``, ``before_id`` fetches the next older
page, and a replay without those fields is exactly what it was."""

from __future__ import annotations

from cowork_agent import MockModelClient, StateStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _seed(db_path: str, session_key: str, turns: int) -> list[int]:
    store = StateStore(db_path)
    try:
        sid = store.route(session_key)
        ids: list[int] = []
        for n in range(turns):
            ids.append(store.append_message(sid, "user", {"role": "user", "content": f"q{n}"}))
            store.begin_run(f"run-{n}", sid, session_key, f"q{n}")
            store.append_message(sid, "assistant", {"role": "assistant", "content": f"a{n}"})
            store.finish_run(
                f"run-{n}", reason="finished", final_answer=f"a{n}", iterations=1, tokens_spent=0
            )
        return ids
    finally:
        store.close()


def _rig(tmp_path, db_path):
    (tmp_path / "ws").mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="pager",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=db_path,
        model_factory=lambda: MockModelClient(["unused"]),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def _texts(events: list[dict]) -> list[str]:
    return [e["text"] for e in events if e["type"] in ("user", "delta")]


def test_a_limited_replay_sends_the_newest_page_and_says_more_exists(tmp_path):
    db_path = str(tmp_path / "state.db")
    user_ids = _seed(db_path, "thread-1", 6)  # 12 turn rows
    executor, controller = _rig(tmp_path, db_path)
    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1", "limit": 4})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    assert events[0]["type"] == "run_state"
    assert _texts(events) == ["q4", "a4", "q5", "a5"]
    # Only the runs inside the page, after their turns.
    assert [e["run_id"] for e in events if e["type"] == "done" and e["reason"] != "replay"] == [
        "run-4",
        "run-5",
    ]
    end = events[-1]
    assert end["type"] == "done" and end["reason"] == "replay" and end["replay"] is True
    assert end["has_more"] is True
    assert end["oldest_mid"] == user_ids[4]
    assert "before_id" not in end


def test_before_id_fetches_the_older_page_and_the_last_one_says_no_more(tmp_path):
    db_path = str(tmp_path / "state.db")
    user_ids = _seed(db_path, "thread-1", 6)
    executor, controller = _rig(tmp_path, db_path)
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "replay", "session_key": "thread-1", "before_id": user_ids[4], "limit": 4}
        )
        page2 = controller.collect(rid, timeout=10.0)
        rid = controller.send_payload(
            {"type": "replay", "session_key": "thread-1", "before_id": user_ids[2], "limit": 4}
        )
        page3 = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    assert _texts(page2) == ["q2", "a2", "q3", "a3"]
    end2 = page2[-1]
    assert end2["has_more"] is True and end2["oldest_mid"] == user_ids[2]
    assert end2["before_id"] == user_ids[4]

    assert _texts(page3) == ["q0", "a0", "q1", "a1"]
    end3 = page3[-1]
    assert end3["has_more"] is False and end3["oldest_mid"] == user_ids[0]
    assert end3["before_id"] == user_ids[2]


def test_a_replay_without_paging_fields_is_unchanged(tmp_path):
    db_path = str(tmp_path / "state.db")
    _seed(db_path, "thread-1", 3)
    executor, controller = _rig(tmp_path, db_path)
    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert _texts(events) == ["q0", "a0", "q1", "a1", "q2", "a2"]
    end = events[-1]
    assert end["reason"] == "replay"
    assert "has_more" not in end and "oldest_mid" not in end and "before_id" not in end


def test_bad_paging_fields_fall_back_to_the_whole_window(tmp_path):
    db_path = str(tmp_path / "state.db")
    _seed(db_path, "thread-1", 2)
    executor, controller = _rig(tmp_path, db_path)
    executor.start()
    try:
        rid = controller.send_payload(
            {"type": "replay", "session_key": "thread-1", "limit": "lots", "before_id": -3}
        )
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()
    assert _texts(events) == ["q0", "a0", "q1", "a1"]
    assert "has_more" not in events[-1]
