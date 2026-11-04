"""Plan mode, ``todo_write``, timed ``ask_user`` and typed row sources
(docs/WIRE_CONTRACT.md "Plan mode", "Todo list", "Questions to the user",
"Typed source on synthetic rows"; DeepSeek harness ideas 45, 46, 51, 52)."""

from __future__ import annotations

import json

import pytest

from chuk_agents_runtime import build_runtime
from chuk_agents_runtime.ask_user import (
    ASK_USER,
    PENDING_NOTICE,
    QuestionError,
    clean_answers,
    late_answer_prompt,
    register_ask_user_tool,
    validate_questions,
    validate_timeout,
)
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.plan_mode import (
    EXIT_PLAN_MODE,
    PLAN_RULES,
    PlanMode,
    PlanState,
    parse_plan_prefix,
)
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.sources import tag_row
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.todo import TodoError, load_todos, summary, validate_todos

KEY = "s1"


# -- plan mode -----------------------------------------------------------------


def test_plan_prefix():
    assert parse_plan_prefix("/plan add a login page") == (True, "add a login page")
    assert parse_plan_prefix("/plan off go ahead") == (False, "go ahead")
    on, text = parse_plan_prefix("/plan")
    assert on is True and text
    assert parse_plan_prefix("/planet earth") == (None, "/planet earth")
    assert parse_plan_prefix("plan it") == (None, "plan it")


class _Review:
    def __init__(self, answer):
        self.answer = answer
        self.plans: list = []

    def review(self, plan, title):
        self.plans.append((plan, title))
        return self.answer


def _plan(tmp_path, answer, active=True):
    store = StateStore(str(tmp_path / "state.db"))
    state = PlanState(store, KEY)
    state.set(active)
    changes: list = []
    return store, state, PlanMode(state=state, backend=_Review(answer), on_change=changes.append), changes


def test_approve_ends_plan_mode(tmp_path):
    _store, state, mode, changes = _plan(tmp_path, {"decision": "approve"})
    result = mode.exit("# Add login\n\n1. Do it")
    assert result["ok"] is True and result["approved"] is True
    assert state.active() is False and changes == [False]
    assert mode.backend.plans == [("# Add login\n\n1. Do it", "Add login")]


def test_keep_planning_returns_the_feedback_as_the_error(tmp_path):
    _store, state, mode, _ = _plan(
        tmp_path, {"decision": "keep_planning", "feedback": "Use OAuth, not passwords"}
    )
    result = mode.exit("# Plan")
    assert result["ok"] is False and "Use OAuth, not passwords" in result["error"]
    assert state.active() is True


def test_no_review_keeps_plan_mode(tmp_path):
    _store, state, mode, _ = _plan(tmp_path, {"decision": "timeout"})
    assert "Stay in plan mode" in mode.exit("# Plan")["error"]
    assert state.active() is True


def test_exit_outside_plan_mode_is_refused(tmp_path):
    _store, _state, mode, _ = _plan(tmp_path, {"decision": "approve"}, active=False)
    assert "not on" in mode.exit("# Plan")["error"]


class _ToolsSeen(MockModelClient):
    def __init__(self, responses):
        super().__init__(responses)
        self.tools_per_call: list = []
        self._tools = None

    def set_tools(self, tools):
        self._tools = tools

    def complete(self, messages):
        self.tools_per_call.append(json.dumps(self._tools, sort_keys=True))
        return super().complete(messages)


def test_plan_mode_is_an_appended_row_not_a_prompt_or_tool_change(tmp_path):
    """The cache rule: the system prompt and the declared tools are the
    same bytes with plan mode on and off; only an appended row differs."""
    db = str(tmp_path / "state.db")
    store = StateStore(db)
    state = PlanState(store, KEY)
    model = _ToolsSeen(["planning...", "carrying out..."])
    mode = PlanMode(state=state, backend=_Review({"decision": "approve"}))
    loop = build_runtime(model, db_path=db, context_ladder=False, plan_mode=mode)
    assert loop.registry.has(EXIT_PLAN_MODE) and loop.registry.is_deferred(EXIT_PLAN_MODE)
    state.set(True)
    first = loop.run(KEY, "add a login page")
    state.set(False)
    loop.run(KEY, "now do it")
    rows = [m for m in store.get_conversation(first.session_id)]
    plan_rows = [m for m in rows if m.content.get("source") == "plan"]
    assert len(plan_rows) == 1 and plan_rows[0].content["content"] == PLAN_RULES
    assert plan_rows[0].role == "context"
    # Right after the prompt and the clock row.
    user_index = next(i for i, m in enumerate(rows) if m.role == "user")
    assert rows.index(plan_rows[0]) > user_index
    systems = [m.content["content"] for m in rows if m.role == "system"]
    assert len(systems) == 1
    assert model.tools_per_call[0] == model.tools_per_call[1]


# -- todo_write ------------------------------------------------------------------


def test_todo_rules():
    ok = validate_todos(
        [
            {"content": "Read the code", "status": "completed"},
            {"content": "Write the fix", "status": "in_progress"},
            {"content": "Run the tests", "status": "pending"},
        ]
    )
    assert summary(ok) == "Updated todo list: 1 pending, 1 in progress, 1 completed"
    assert validate_todos([{"content": "a", "status": "completed"}])
    assert validate_todos([]) == []
    for bad, match in [
        ([{"content": "a", "status": "in_progress"}, {"content": "b", "status": "in_progress"}], "exactly one"),
        ([{"content": "a", "status": "pending"}], "exactly one"),
        ([{"content": " ", "status": "pending"}], "non-empty"),
        ([{"content": "a", "status": "in_progress"}, {"content": "a", "status": "pending"}], "duplicate"),
        ([{"content": "a", "status": "doing"}], "status"),
        ([{"content": "a", "status": "in_progress", "priority": 1}], "unknown"),
    ]:
        with pytest.raises(TodoError, match=match):
            validate_todos(bad)


def test_todo_write_replaces_the_list_and_feeds_the_card(tmp_path):
    db = str(tmp_path / "state.db")
    sent: list = []
    todos = [{"content": "Step one", "status": "in_progress"}, {"content": "Step two", "status": "pending"}]
    model = MockModelClient([tool_call_response(("todo_write", {"todos": todos})), "ok"])
    loop = build_runtime(
        model, db_path=db, context_ladder=False, shell_session_key=KEY, todo_sink=sent.append
    )
    assert loop.registry.is_deferred("todo_write")
    result = loop.run(KEY, "do two steps")
    store = StateStore(db)
    assert load_todos(store, KEY) == todos
    assert sent == [todos]
    tool_rows = [m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool"]
    assert tool_rows[0]["content"] == "Updated todo list: 1 pending, 1 in progress, 0 completed"


# -- ask_user ----------------------------------------------------------------------


def test_question_validation_and_the_recommended_rule():
    batch = validate_questions(
        [
            {
                "id": "db",
                "question": "Which database?",
                "header": "Database",
                "options": [
                    {"label": "SQLite (Recommended)", "description": "No server."},
                    {"label": "Postgres"},
                ],
            }
        ]
    )
    assert batch[0]["options"][0]["label"] == "SQLite (Recommended)"
    with pytest.raises(QuestionError, match="first"):
        validate_questions(
            [{"id": "a", "question": "?", "options": [{"label": "x"}, {"label": "y (Recommended)"}]}]
        )
    with pytest.raises(QuestionError, match="unique"):
        validate_questions([{"id": "a", "question": "?"}, {"id": "a", "question": "!"}])
    assert validate_timeout(None) == 120 and validate_timeout(-1) == -1
    with pytest.raises(QuestionError):
        validate_timeout(0)


def test_skips_and_unknown_options_in_an_answer():
    questions = validate_questions(
        [
            {"id": "a", "question": "?", "options": [{"label": "x"}, {"label": "y"}]},
            {"id": "b", "question": "!"},
        ]
    )
    answers = clean_answers([{"id": "a", "selected": ["y", "z", "x"]}], questions)
    assert answers == [{"id": "a", "selected": ["y"]}, {"id": "b", "selected": []}]


class _Backend:
    def __init__(self, result):
        self.result = result
        self.asked: list = []

    def ask(self, call_id, questions, timeout):
        self.asked.append((call_id, questions, timeout))
        return self.result


def test_a_timeout_is_pending_with_the_call_id(tmp_path):
    backend = _Backend({"pending": True})
    db = str(tmp_path / "state.db")
    model = MockModelClient(
        [tool_call_response(("ask_user", {"questions": [{"id": "q", "question": "Which?"}], "timeout": 30})), "ok"]
    )
    loop = build_runtime(model, db_path=db, context_ladder=False, questions=backend)
    assert loop.registry.is_deferred(ASK_USER)
    result = loop.run(KEY, "ask me")
    [(call_id, _questions, timeout)] = backend.asked
    assert call_id == "call_0" and timeout == 30
    store = StateStore(db)
    tool = [m.content for m in store.get_conversation(result.session_id) if m.content.get("role") == "tool"][0]
    content = tool["content"]
    data = content if isinstance(content, dict) else json.loads(content)
    assert data == {"pending": True, "callId": "call_0", "message": PENDING_NOTICE}


def test_an_answer_batch_passes_through():
    registry = ToolRegistry()
    register_ask_user_tool(registry, _Backend({"answers": [{"id": "q", "selected": [], "custom": "blue"}]}))
    result = registry.dispatch(ASK_USER, {"questions": [{"id": "q", "question": "Colour?"}]})
    assert result == {"answers": [{"id": "q", "selected": [], "custom": "blue"}]}


def test_the_late_answer_prompt_names_the_call():
    text = late_answer_prompt("call_7", [{"id": "q", "question": "?"}], [{"id": "q", "selected": []}])
    assert text.startswith('<answer_to_pending_question callId="call_7">')


# -- typed sources -------------------------------------------------------------------


def test_role_tags_map_to_sources():
    assert tag_row("clock", {"role": "user", "content": "x"})["source"] == "time"
    assert tag_row("skill", {"role": "user", "content": "x"})["source"] == "skill"
    assert tag_row("subagent", {"role": "user", "content": "x"})["source"] == "subagent"
    assert "source" not in tag_row("context", {"role": "user", "content": "x"})
    assert tag_row("skill", {"role": "user", "content": "x", "source": "plan"})["source"] == "plan"


def test_source_is_stored_and_replayed_backward_compatibly(tmp_path):
    db = str(tmp_path / "state.db")
    live: list = []
    loop = build_runtime(
        MockModelClient(["one", "two"]), db_path=db, context_ladder=False,
        context_observer=live.append,
    )
    loop.run(KEY, "typed by the user")
    loop.run(KEY, "<goal_round>...</goal_round>", source="goal",
             row_extra={"answer_to_pending_question": "call_3"})
    store = StateStore(db)
    sid = store.route(KEY)
    users = [e for e in store.replay_events(sid) if e["type"] == "user"]
    assert "source" not in users[0]
    assert users[1]["source"] == "goal" and users[1]["answer_to_pending_question"] == "call_3"
    rows = [m for m in store.get_conversation(sid)]
    clock = [m for m in rows if m.role == "clock"]
    assert clock and all(m.content["source"] == "time" for m in clock)
    # The clock row is stored with its source but never replayed or streamed.
    assert not [e for e in store.replay_events(sid) if e["type"] == "context"]
    assert live == []
    # Unknown sources are dropped.
    loop.run(KEY, "x", source="bogus")
    assert "source" not in [m.content for m in store.get_conversation(sid) if m.role == "user"][-1]
