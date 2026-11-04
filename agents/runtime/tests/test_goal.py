"""Goal mode (docs/WIRE_CONTRACT.md "Goal mode", DeepSeek harness idea 41)."""

from __future__ import annotations

from chuk_agents_runtime import build_runtime
from chuk_agents_runtime.goal import (
    BLOCK_ROUND_LIMIT,
    PHASE_ACTIVE,
    PHASE_BLOCKED,
    PHASE_COMPLETE,
    PHASE_PAUSED,
    GoalArming,
    GoalController,
    GoalError,
    admit_round,
    control_goal,
    goal_round_prompt,
    goal_view,
    interrupt_goal,
    load_goal,
    register_goal_tools,
    same_blocker,
)
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore

import pytest

KEY = "s1"


def _store(tmp_path) -> StateStore:
    return StateStore(str(tmp_path / "state.db"))


def _controller(store, arming=None, **kw) -> GoalController:
    return GoalController(store=store, session_key=KEY, arming=arming or GoalArming(), **kw)


def test_set_goal_creates_an_armed_active_goal(tmp_path):
    store = _store(tmp_path)
    changes: list = []
    c = _controller(store, on_change=changes.append)
    doc = c.create("Ship the feature", 7)
    assert doc["phase"] == PHASE_ACTIVE and doc["revision"] == 1 and doc["max_rounds"] == 7
    view = c.view()
    assert view["activation"] == "armed" and view["needs_user"] is False
    assert changes and changes[-1]["id"] == doc["id"]
    # One goal per session.
    with pytest.raises(GoalError, match="already exists"):
        c.create("Another")


def test_default_cap_is_fifty_and_configurable(tmp_path):
    store = _store(tmp_path)
    assert _controller(store).create("x")["max_rounds"] == 50
    store.save_feature(KEY, "goal", None)
    assert _controller(store, default_max_rounds=9).create("x")["max_rounds"] == 9


def test_update_is_compare_and_set(tmp_path):
    c = _controller(_store(tmp_path))
    doc = c.create("Objective")
    with pytest.raises(GoalError, match="stale"):
        c.update(doc["id"], 2, "edit", objective="New")
    new, _ = c.update(doc["id"], 1, "edit", objective="New")
    assert new["revision"] == 2 and new["objective"] == "New"
    with pytest.raises(GoalError, match="stale"):
        c.update(doc["id"], 1, "complete")


def test_pause_and_resume_need_the_user(tmp_path):
    store = _store(tmp_path)
    arming = GoalArming()
    doc = _controller(store, arming).create("Objective")
    in_round = _controller(store, arming, goal_round=2, direct_user=False)
    with pytest.raises(GoalError, match="direct request"):
        in_round.update(doc["id"], 1, "pause")
    paused, _ = _controller(store, arming).update(doc["id"], 1, "pause")
    assert paused["phase"] == PHASE_PAUSED
    assert not arming.armed(KEY, doc["id"])
    resumed, _ = _controller(store, arming).update(doc["id"], 2, "resume")
    assert resumed["phase"] == PHASE_ACTIVE and arming.armed(KEY, doc["id"])


def test_blocked_needs_the_same_blocker_three_rounds_in_a_row(tmp_path):
    store = _store(tmp_path)
    arming = GoalArming()
    doc = _controller(store, arming).create("Deploy")
    reason = "The deploy key is rejected by the server (permission denied)"

    def report(round_no, text=reason):
        c = _controller(store, arming, goal_round=round_no, direct_user=False)
        current = load_goal(store, KEY)
        return c.update(current["id"], current["revision"], "blocked", blocked_reason=text)

    doc1, note1 = report(1)
    assert doc1["phase"] == PHASE_ACTIVE and "1 of 3" in note1
    doc2, note2 = report(2, "deploy key rejected by the server: permission denied")
    assert doc2["phase"] == PHASE_ACTIVE and "2 of 3" in note2
    doc3, note3 = report(3)
    assert note3 is None and doc3["phase"] == PHASE_BLOCKED
    assert doc3["blocked_reason"]["code"] == "model-reported"
    assert goal_view(doc3, arming, KEY)["needs_user"] is True
    assert not arming.armed(KEY, doc["id"])


def test_a_different_blocker_or_a_gap_restarts_the_streak(tmp_path):
    store = _store(tmp_path)
    arming = GoalArming()
    _controller(store, arming).create("Deploy")

    def report(round_no, text):
        c = _controller(store, arming, goal_round=round_no, direct_user=False)
        current = load_goal(store, KEY)
        return c.update(current["id"], current["revision"], "blocked", blocked_reason=text)

    report(1, "network is down")
    _, note = report(2, "the test database is missing")
    assert "1 of 3" in note
    _, note = report(4, "the test database is missing")
    assert "1 of 3" in note


def test_same_blocker_tolerates_rewording():
    assert same_blocker("API key rejected (401)", "the API key is rejected: 401")
    assert not same_blocker("API key rejected", "disk is full")


def test_complete_in_a_goal_round_queues_a_wrapup_without_tools(tmp_path):
    store = _store(tmp_path)
    arming = GoalArming()
    doc = _controller(store, arming).create("Write the report")
    c = _controller(store, arming, goal_round=1, direct_user=False)
    c.update(doc["id"], 1, "complete")
    [row] = c.pending_context()
    assert row["final_step"] is True and row["source"] == "goal"
    assert "<goal_complete>" in row["content"] and "Do not call any more tools" in row["content"]
    assert c.pending_context() == []
    # A user turn that completes gets no forced wrap-up.
    store.save_feature(KEY, "goal", None)
    d2 = _controller(store, arming).create("Again")
    direct = _controller(store, arming)
    direct.update(d2["id"], 1, "complete")
    assert direct.pending_context() == []


def test_round_admission_counts_and_stops_at_the_cap(tmp_path):
    store = _store(tmp_path)
    arming = GoalArming()
    _controller(store, arming).create("Loop", 2)
    kind, doc = admit_round(store, KEY, arming)
    assert kind == "round" and doc["rounds_started"] == 1
    kind, doc = admit_round(store, KEY, arming)
    assert kind == "round" and doc["rounds_started"] == 2
    kind, doc = admit_round(store, KEY, arming)
    assert kind == "limit" and doc["phase"] == PHASE_BLOCKED
    assert doc["blocked_reason"]["code"] == BLOCK_ROUND_LIMIT
    assert admit_round(store, KEY, arming)[0] == "none"


def test_a_restart_brings_the_goal_back_disarmed(tmp_path):
    store = _store(tmp_path)
    _controller(store, GoalArming()).create("Survive a restart")
    fresh = GoalArming()  # a new process
    assert goal_view(load_goal(store, KEY), fresh, KEY)["activation"] == "disarmed"
    assert admit_round(store, KEY, fresh)[0] == "none"
    # The user resumes it: armed again, nothing else changes.
    doc, error = control_goal(store, KEY, fresh, "resume")
    assert error is None and fresh.armed(KEY, doc["id"])
    assert admit_round(store, KEY, fresh)[0] == "round"


def test_a_stopped_round_pauses_the_goal(tmp_path):
    store = _store(tmp_path)
    arming = GoalArming()
    _controller(store, arming).create("x")
    doc = interrupt_goal(store, KEY, arming, pause=True)
    assert doc["phase"] == PHASE_PAUSED and not arming.armed(KEY, doc["id"])


def test_the_round_prompt_names_objective_round_and_revision():
    text = goal_round_prompt(
        {"id": "g_1", "revision": 3, "objective": "Fix the build", "max_rounds": 50}, 4
    )
    assert text.startswith("<goal_round>") and text.endswith("</goal_round>")
    assert '"Fix the build"' in text and "Round: 4/50" in text and "revision 3" in text


def test_the_tools_are_deferrable(tmp_path):
    registry = ToolRegistry()
    register_goal_tools(registry, _controller(_store(tmp_path)))
    for name in ("set_goal", "update_goal", "get_goal"):
        assert registry.spec(name).deferrable is True
    result = registry.dispatch("update_goal", {"goal_id": "g", "revision": 1, "action": "complete"})
    assert result["ok"] is False and "no goal" in result["error"]
    created = registry.dispatch("set_goal", {"objective": "Do it"})
    assert created["ok"] is True and created["goal"]["phase"] == "active"
    assert registry.dispatch("get_goal", {})["goal"]["id"] == created["goal"]["id"]


class _ToolsSeen(MockModelClient):
    def __init__(self, responses):
        super().__init__(responses)
        self.tools_per_call: list = []
        self._tools = None

    def set_tools(self, tools):
        self._tools = tools

    def complete(self, messages):
        self.tools_per_call.append(self._tools)
        return super().complete(messages)


def test_a_goal_round_that_completes_ends_with_one_report_and_no_tools(tmp_path):
    db = str(tmp_path / "state.db")
    store = StateStore(db)
    arming = GoalArming()
    doc = _controller(store, arming).create("Write hello.txt")
    model = _ToolsSeen(
        [
            tool_call_response(
                ("update_goal", {"goal_id": doc["id"], "revision": 1, "action": "complete"})
            ),
            "Done: hello.txt exists and reads hello.",
        ]
    )
    controller = _controller(store, arming, goal_round=1, direct_user=False)
    loop = build_runtime(model, db_path=db, context_ladder=False, goal=controller)
    result = loop.run(KEY, goal_round_prompt(doc, 1), source="goal")
    assert result.final_answer == "Done: hello.txt exists and reads hello."
    assert load_goal(store, KEY)["phase"] == PHASE_COMPLETE
    # The wrap-up step was offered no tools.
    assert model.tools_per_call[-1] in (None, [])
    assert model.tools_per_call[0]
    rows = [m.content for m in store.get_conversation(result.session_id)]
    assert rows[1]["role"] == "user" and rows[1]["source"] == "goal"
    wrap = [r for r in rows if "<goal_complete>" in str(r.get("content"))]
    assert len(wrap) == 1 and wrap[0]["source"] == "goal" and "final_step" not in wrap[0]
