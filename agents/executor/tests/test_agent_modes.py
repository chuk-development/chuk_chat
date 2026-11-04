"""Goal mode, plan mode, todo list and timed questions through the executor
(docs/WIRE_CONTRACT.md "Goal mode", "Plan mode", "Todo list", "Questions to
the user", "Typed source on synthetic rows"), over the real sealed loopback.
"""

from __future__ import annotations

import threading
import time

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_runtime.goal import load_goal
from chuk_agents_runtime.model import ModelResponse
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import (
    ControllerSession,
    Executor,
    approval_decision_payload,
    ask_visible_payload,
    goal_control_payload,
    loopback_pair,
    question_answer_payload,
    task_payload,
)

from wiring import paired_channel

KEY = "t1"


class _Shared(MockModelClient):
    """Every client the executor builds pops from ONE script, so a test can
    span several runs. A callable item builds its turn from the db."""

    script: list = []
    lock = threading.Lock()

    def __init__(self) -> None:
        super().__init__([])

    def complete(self, messages):
        with _Shared.lock:
            item = _Shared.script.pop(0) if _Shared.script else "(end)"
        if callable(item):
            item = item()
        if isinstance(item, ModelResponse):
            return item
        return ModelResponse(text=item, raw={"content": item})


def _start(tmp_path, script, **kwargs):
    _Shared.script = list(script)
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="modes",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=_Shared,
        workspace=str(ws),
        heartbeat_seconds=60,
        **kwargs,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    return executor, controller


def _drive(controller, request_id, *, on_event=None, timeout=20.0):
    deadline = time.monotonic() + timeout
    events: list[dict] = []
    while time.monotonic() < deadline:
        for event in controller.collect(request_id, timeout=0.1):
            events.append(event)
            if on_event is not None:
                on_event(event)
            if event.get("type") == "error":
                return events
            if event.get("type") == "done" and not (
                event.get("replay") and event.get("reason") != "replay"
            ):
                return events
    raise AssertionError(f"no terminal within {timeout}s: {events}")


def _rows(tmp_path, key=KEY):
    store = StateStore(str(tmp_path / "state.db"))
    try:
        return [m for m in store.get_conversation(store.route(key))]
    finally:
        store.close()


def _tool_result(tmp_path, name):
    rows = [m.content for m in _rows(tmp_path) if m.content.get("role") == "tool"]
    found = [r["content"] for r in rows if r.get("name") == name]
    assert found, rows
    return found[-1]


def _wait(predicate, timeout=20.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("condition not met in time")


# -- plan mode --------------------------------------------------------------------


def test_plan_mode_review_approved(tmp_path):
    plan = "# Login page\n\n1. Add the form.\n2. Test it."
    executor, controller = _start(
        tmp_path, [tool_call_response(("exit_plan_mode", {"plan": plan})), "Implementing now."]
    )
    pushes: list = []
    executor._on_approval_pending = pushes.append

    def answer(event):
        if event.get("type") == "approval_request" and "decision" not in event:
            controller.send_payload(
                approval_decision_payload(approval_id=event["approval_id"], approved=True)
            )

    try:
        rid = controller.send_payload(task_payload("design a login page", KEY, plan=True))
        events = _drive(controller, rid, on_event=answer)
    finally:
        executor.stop()
    modes = [e["active"] for e in events if e.get("type") == "plan_mode"]
    assert modes == [True, False]
    [ask] = [e for e in events if e.get("type") == "approval_request"]
    assert ask["action"] == "plan_review" and ask["plan"] == plan
    assert ask["options"] == ["approve", "keep_planning"] and ask["summary"] == "Login page"
    assert pushes and pushes[0]["action"] == "plan_review"
    assert _tool_result(tmp_path, "exit_plan_mode")["approved"] is True
    plan_rows = [m for m in _rows(tmp_path) if m.content.get("source") == "plan"]
    assert len(plan_rows) == 1
    assert events[-1]["type"] == "done" and events[-1]["reason"] == "finished"


def test_plan_prefix_and_keep_planning_with_feedback(tmp_path):
    executor, controller = _start(
        tmp_path, [tool_call_response(("exit_plan_mode", {"plan": "# P"})), "Revising."]
    )

    def answer(event):
        if event.get("type") == "approval_request" and "decision" not in event:
            controller.send_payload(
                approval_decision_payload(
                    approval_id=event["approval_id"], approved=False, feedback="Use OAuth"
                )
            )

    try:
        rid = controller.send_task("/plan add login", session_key=KEY)
        _drive(controller, rid, on_event=answer)
        user = [m.content for m in _rows(tmp_path) if m.role == "user"]
        assert user[-1]["content"] == "add login"
        result = _tool_result(tmp_path, "exit_plan_mode")
        assert result["ok"] is False and "Use OAuth" in result["error"]
        # Still in plan mode: the replay header says so.
        replay = controller.send_payload({"type": "replay", "session_key": KEY})
        header = _drive(controller, replay)[0]
        assert header["type"] == "run_state" and header["plan_mode"] is True
    finally:
        executor.stop()


# -- todo ---------------------------------------------------------------------------


def test_todo_frame_and_run_state(tmp_path):
    todos = [{"content": "One", "status": "in_progress"}, {"content": "Two", "status": "pending"}]
    executor, controller = _start(
        tmp_path, [tool_call_response(("todo_write", {"todos": todos})), "ok"]
    )
    try:
        events = _drive(controller, controller.send_task("two steps", session_key=KEY))
        [frame] = [e for e in events if e.get("type") == "todo"]
        assert frame["todos"] == todos and frame["counts"] == {
            "pending": 1, "in_progress": 1, "completed": 0,
        }
        replay = _drive(controller, controller.send_payload({"type": "replay", "session_key": KEY}))
        assert replay[0]["todos"] == todos
        assert [e for e in replay if e.get("type") == "todo"]
    finally:
        executor.stop()


# -- ask_user --------------------------------------------------------------------------


def _ask(timeout=120):
    return tool_call_response(
        (
            "ask_user",
            {
                "questions": [
                    {
                        "id": "db",
                        "question": "Which database?",
                        "options": [{"label": "SQLite (Recommended)"}, {"label": "Postgres"}],
                    }
                ],
                "timeout": timeout,
            },
        )
    )


def test_an_answer_in_time_returns_to_the_call(tmp_path):
    executor, controller = _start(tmp_path, [_ask(), "Using SQLite."])
    pushes: list = []
    executor._on_approval_pending = pushes.append

    def answer(event):
        if event.get("type") == "question_request" and event["status"] == "open":
            controller.send_payload(
                question_answer_payload(
                    question_id=event["question_id"],
                    answers=[{"id": "db", "selected": ["SQLite (Recommended)"]}],
                    session_key=KEY,
                )
            )

    try:
        events = _drive(controller, controller.send_task("set up storage", session_key=KEY), on_event=answer)
    finally:
        executor.stop()
    statuses = [e["status"] for e in events if e.get("type") == "question_request"]
    assert statuses == ["open", "answered"]
    assert _tool_result(tmp_path, "ask_user") == {
        "answers": [{"id": "db", "selected": ["SQLite (Recommended)"]}]
    }
    assert pushes and pushes[0]["action"] == "ask_user"


def test_a_timeout_is_pending_and_a_late_answer_starts_a_turn(tmp_path):
    executor, controller = _start(tmp_path, [_ask(timeout=1), "I will continue meanwhile.", "Got it: Postgres."])
    try:
        events = _drive(controller, controller.send_task("set up storage", session_key=KEY))
        statuses = [e["status"] for e in events if e.get("type") == "question_request"]
        assert statuses == ["open", "pending"]
        result = _tool_result(tmp_path, "ask_user")
        assert result["pending"] is True and result["callId"] == "call_0"
        assert "answer_to_pending_question" in result["message"]
        controller.send_payload(
            question_answer_payload(
                question_id="call_0", answers=[{"id": "db", "selected": ["Postgres"]}], session_key=KEY
            )
        )
        _wait(lambda: any(
            m.role == "user" and m.content.get("answer_to_pending_question") == "call_0"
            for m in _rows(tmp_path)
        ))
        _wait(lambda: any(
            m.role == "assistant" and m.content.get("content") == "Got it: Postgres."
            for m in _rows(tmp_path)
        ))
        replay = _drive(controller, controller.send_payload({"type": "replay", "session_key": KEY}))
        late = [e for e in replay if e.get("type") == "user" and e.get("answer_to_pending_question")]
        assert len(late) == 1 and '"Postgres"' in late[0]["text"]
        stored = [e for e in replay if e.get("type") == "question_request"]
        assert stored[-1]["status"] == "answered"
    finally:
        executor.stop()


def test_the_wait_pauses_while_the_card_is_visible(tmp_path):
    executor, controller = _start(tmp_path, [_ask(timeout=1), "ok"])

    def on_event(event):
        if event.get("type") == "question_request" and event["status"] == "open":
            controller.send_payload(ask_visible_payload(question_id=event["question_id"], visible=True))

            def later():
                time.sleep(2.0)
                controller.send_payload(
                    question_answer_payload(
                        question_id=event["question_id"],
                        answers=[{"id": "db", "selected": []}],
                        session_key=KEY,
                    )
                )

            threading.Thread(target=later, daemon=True).start()

    try:
        events = _drive(controller, controller.send_task("storage", session_key=KEY), on_event=on_event)
    finally:
        executor.stop()
    statuses = [e["status"] for e in events if e.get("type") == "question_request"]
    assert statuses == ["open", "answered"]
    # A skip: empty selected, no custom.
    assert _tool_result(tmp_path, "ask_user") == {"answers": [{"id": "db", "selected": []}]}


# -- goal mode --------------------------------------------------------------------------


def test_a_goal_runs_rounds_until_complete(tmp_path):
    db = str(tmp_path / "state.db")

    def complete():
        store = StateStore(db)
        try:
            goal = load_goal(store, KEY)
        finally:
            store.close()
        return tool_call_response(
            ("update_goal", {"goal_id": goal["id"], "revision": goal["revision"], "action": "complete"})
        )

    executor, controller = _start(
        tmp_path,
        [
            tool_call_response(("set_goal", {"objective": "Write hello.txt", "max_rounds": 5})),
            "Started on the goal.",
            complete,
            "Done: hello.txt is written and checked.",
        ],
    )
    finished: list = []
    executor._on_run_finished = finished.append
    try:
        events = _drive(controller, controller.send_task("keep at it until hello.txt exists", session_key=KEY))
        done = events[-1]
        assert done["type"] == "done" and done["goal"]["continues"] is True
        assert done["goal"]["rounds_started"] == 1
        goal_frames = [e for e in events if e.get("type") == "goal"]
        assert goal_frames and goal_frames[0]["goal"]["activation"] == "armed"
        _wait(lambda: len(finished) >= 2)
        store = StateStore(db)
        try:
            goal = load_goal(store, KEY)
        finally:
            store.close()
        assert goal["phase"] == "complete" and goal["rounds_started"] == 1
        assert finished[1]["origin"] == "goal" and finished[1]["goal"]["continues"] is False
        rows = _rows(tmp_path)
        round_rows = [m for m in rows if m.role == "user" and m.content.get("source") == "goal"]
        assert len(round_rows) == 1 and round_rows[0].content["content"].startswith("<goal_round>")
        assert any(m.content.get("source") == "goal" and m.role == "context" for m in rows)
        replay = _drive(controller, controller.send_payload({"type": "replay", "session_key": KEY}))
        assert replay[0]["goal"]["phase"] == "complete"
        assert [e for e in replay if e.get("type") == "context" and e["source"] == "goal"]
        assert [e for e in replay if e.get("type") == "user" and e.get("source") == "goal"]
    finally:
        executor.stop()


def test_goal_control_answers_with_the_goal(tmp_path):
    executor, controller = _start(
        tmp_path, [tool_call_response(("set_goal", {"objective": "x", "max_rounds": 1})), "ok", "round ok"]
    )
    try:
        _drive(controller, controller.send_task("goal", session_key=KEY))
        rid = controller.send_payload(goal_control_payload(session_key=KEY, action="pause"))
        reply = controller.collect(rid, timeout=10)
        assert reply[-1]["type"] == "goal" and reply[-1]["session_key"] == KEY
    finally:
        executor.stop()
