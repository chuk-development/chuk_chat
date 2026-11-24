"""The goal judge (CHAT-183): a cheap model checks ``update_goal complete``."""

from __future__ import annotations

import json

from chuk_agents_runtime import build_runtime
from chuk_agents_runtime.goal import (
    PHASE_ACTIVE,
    PHASE_COMPLETE,
    GoalArming,
    GoalController,
    load_goal,
    register_goal_tools,
)
from chuk_agents_runtime.goal_judge import (
    VERDICT_CONTINUE,
    VERDICT_DONE,
    VERDICT_ERROR,
    VERDICT_SKIPPED,
    GoalJudge,
    build_judge_messages,
    judge_enabled,
    make_judge,
    parse_verdict,
)
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore

KEY = "s1"


class _Judge:
    """A scripted judge model; records every call."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls: list = []

    def complete(self, messages):
        self.calls.append(messages)
        item = self.answers.pop(0) if self.answers else json.dumps({"verdict": "done"})
        if isinstance(item, Exception):
            raise item

        class R:
            text = item

        return R()


def _no(reason="tests are missing"):
    return json.dumps({"verdict": "continue", "reason": reason})


def _setup(tmp_path, judge_model, **kw):
    store = StateStore(str(tmp_path / "state.db"))
    arming = GoalArming()
    changes: list = []
    c = GoalController(
        store=store,
        session_key=KEY,
        arming=arming,
        judge=GoalJudge(judge_model, **kw.pop("judge_kw", {})),
        on_change=changes.append,
        **kw,
    )
    doc = c.create("Write hello.txt and a test for it")
    return store, c, doc, changes


def _complete(c, doc, rev=None, evidence="hello.txt exists"):
    registry = ToolRegistry()
    register_goal_tools(registry, c)
    return registry.dispatch(
        "update_goal",
        {
            "goal_id": doc["id"],
            "revision": rev or doc["revision"],
            "action": "complete",
            "evidence": evidence,
        },
    )


def test_parse_verdict_accepts_only_the_expected_json():
    assert parse_verdict('```json\n{"verdict": "done", "reason": ""}\n```') == ("done", "")
    assert parse_verdict(_no("x")) == ("continue", "x")
    assert parse_verdict("sure, done") is None
    assert parse_verdict('{"verdict": "maybe"}') is None
    # A refusal with no reason gives the agent nothing to do.
    assert parse_verdict('{"verdict": "continue", "reason": ""}') is None


def test_messages_are_capped_and_keep_the_tail():
    messages = build_judge_messages("Obj", "ev", "A" * 50_000 + "THE END", 2_000)
    body = messages[1]["content"]
    assert len(body) <= 2_100 and body.endswith("THE END") and "Obj" in body


def test_done_completes_and_the_verdict_is_in_the_goal_view(tmp_path):
    judge = _Judge(json.dumps({"verdict": "done", "reason": "all there"}))
    store, c, doc, changes = _setup(tmp_path, judge)
    result = _complete(c, doc)
    assert result["ok"] is True
    stored = load_goal(store, KEY)
    assert stored["phase"] == PHASE_COMPLETE and stored["judge_rounds"] == 1
    assert result["goal"]["judge"]["verdict"] == VERDICT_DONE
    assert changes[-1]["judge"]["verdict"] == VERDICT_DONE
    assert "Write hello.txt" in judge.calls[0][1]["content"]
    assert "hello.txt exists" in judge.calls[0][1]["content"]


def test_continue_refuses_queues_a_nudge_and_keeps_the_revision(tmp_path):
    store, c, doc, changes = _setup(tmp_path, _Judge(_no("the test file is missing")))
    result = _complete(c, doc)
    assert result["ok"] is False and "the test file is missing" in result["error"]
    assert result["judge"]["verdict"] == VERDICT_CONTINUE and result["judge"]["round"] == 1
    stored = load_goal(store, KEY)
    assert stored["phase"] == PHASE_ACTIVE and stored["revision"] == 1
    # The app sees the verdict in the goal frame.
    assert changes[-1]["judge"]["reason"] == "the test file is missing"
    rows = c.pending_context()
    assert len(rows) == 1 and rows[0]["source"] == "goal" and rows[0]["role"] == "user"
    assert "<goal_judge>" in rows[0]["content"] and "final_step" not in rows[0]
    # The same revision is still valid for the next try.
    assert _complete(c, doc)["ok"] is True


def test_the_judge_has_a_hard_round_cap(tmp_path):
    judge = _Judge(_no(), _no(), _no(), _no())
    store, c, doc, _ = _setup(tmp_path, judge)
    for _ in range(3):
        assert _complete(c, doc)["ok"] is False
    result = _complete(c, doc)
    assert result["ok"] is True and len(judge.calls) == 3
    assert load_goal(store, KEY)["judge"]["verdict"] == VERDICT_SKIPPED


def test_the_judge_has_a_cost_cap(tmp_path):
    judge = _Judge(_no(), _no())
    store, c, doc, _ = _setup(
        tmp_path, judge, judge_kw={"max_input_chars": 600, "max_total_chars": 600}
    )
    assert _complete(c, doc)["ok"] is False
    # The first call used the whole character budget: the next is not judged.
    assert _complete(c, doc)["ok"] is True and len(judge.calls) == 1


def test_judge_errors_fail_open(tmp_path):
    for index, answer in enumerate((RuntimeError("down"), "not json at all")):
        (tmp_path / str(index)).mkdir()
        store, c, doc, _ = _setup(tmp_path / str(index), _Judge(answer))
        result = _complete(c, doc)
        assert result["ok"] is True
        assert load_goal(store, KEY)["judge"]["verdict"] == VERDICT_ERROR


def test_no_refusal_when_the_run_has_no_steps_left(tmp_path):
    store, c, doc, _ = _setup(tmp_path, _Judge(_no()), steps_left=lambda: 1)
    result = _complete(c, doc)
    assert result["ok"] is True
    assert load_goal(store, KEY)["judge"]["verdict"] == VERDICT_SKIPPED


def test_a_factory_gets_a_fresh_client_that_is_closed(tmp_path):
    made: list = []

    class Client(_Judge):
        closed = False

        def close(self):
            self.closed = True

    def factory():
        made.append(Client(json.dumps({"verdict": "done"})))
        return made[-1]

    store, c, doc, _ = _setup(tmp_path, factory)
    assert _complete(c, doc)["ok"] is True
    assert len(made) == 1 and made[0].closed is True


def test_judge_switch_and_make_judge():
    assert judge_enabled({}) is True
    assert judge_enabled({"AGENTS_GOAL_JUDGE": "0"}) is False
    assert make_judge(None) is None
    assert isinstance(make_judge(_Judge()), GoalJudge)


def test_in_a_run_the_refusal_keeps_the_loop_going(tmp_path):
    db = str(tmp_path / "state.db")
    store = StateStore(db)
    arming = GoalArming()
    judge = _Judge(_no("hello.txt is not verified"), json.dumps({"verdict": "done"}))
    doc = GoalController(store=store, session_key=KEY, arming=arming).create("Write hello.txt")
    complete = ("update_goal", {"goal_id": doc["id"], "revision": 1, "action": "complete"})
    model = MockModelClient(
        [
            tool_call_response(complete),
            tool_call_response(complete),
            "Done: hello.txt exists.",
        ]
    )
    controller = GoalController(
        store=store,
        session_key=KEY,
        arming=arming,
        goal_round=1,
        direct_user=False,
        judge=GoalJudge(judge),
    )
    loop = build_runtime(model, db_path=db, context_ladder=False, goal=controller)
    # The runtime wired the run's step budget into the controller.
    assert controller.steps_left is not None and controller.steps_left() > 0
    result = loop.run(KEY, "<goal_round>work</goal_round>", source="goal")
    assert result.final_answer == "Done: hello.txt exists."
    assert load_goal(store, KEY)["phase"] == PHASE_COMPLETE
    assert len(judge.calls) == 2
    # The nudge reached the model as a user-side row before its second try.
    second = model.calls[1]
    assert any("<goal_judge>" in str(m.get("content")) for m in second)
