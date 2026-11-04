"""Repeat-call reminder (research item 23) and the failed-action footer
(research H29), both driven in the loop."""

from __future__ import annotations

from chuk_agents_runtime.loop import AgentLoop
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import StateStore


def _store(tmp_path):
    return StateStore(str(tmp_path / "s.db"))


def _context_rows(store, session_id):
    return [
        m.content["content"]
        for m in store.get_conversation(session_id)
        if m.content.get("role") == "user" and str(m.content.get("content", "")).startswith("[runtime]")
    ]


def test_repeat_reminder_fires_at_three_identical_calls(tmp_path):
    reg = ToolRegistry()
    reg.register(
        "echo",
        {"type": "object", "properties": {"v": {"type": "string"}}},
        lambda v="": {"ok": True, "echo": v},
    )
    model = MockModelClient(
        [
            tool_call_response(("echo", {"v": "a"})),
            tool_call_response(("echo", {"v": "a"})),
            tool_call_response(("echo", {"v": "a"})),
            "done",
        ]
    )
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store)
    result = loop.run("s", "go")
    rows = _context_rows(store, result.session_id)
    assert any("repeating the exact same tool call" in r for r in rows)


def test_repeat_reminder_resets_on_a_new_user_message(tmp_path):
    reg = ToolRegistry()
    reg.register("echo", {"type": "object", "properties": {"v": {"type": "string"}}}, lambda v="": {"ok": True})
    store = _store(tmp_path)

    def run_two(v):
        model = MockModelClient(
            [tool_call_response(("echo", {"v": v})), tool_call_response(("echo", {"v": v})), "done"]
        )
        loop = AgentLoop(model, reg, store)
        return loop.run("s", "go")

    run_two("a")
    result = run_two("a")  # a new task: the count started over, so no reminder
    rows = _context_rows(store, result.session_id)
    # Two calls per task never reaches the first threshold (3).
    assert not any("repeating the exact same tool call" in r for r in rows)


def test_failed_action_footer_names_the_failed_write(tmp_path):
    reg = ToolRegistry()
    reg.register(
        "write_file",
        {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}},
        lambda path="", content="": {"ok": False, "path": path, "error": "disk full"},
    )
    model = MockModelClient(
        [
            tool_call_response(("write_file", {"path": "out.txt", "content": "x"})),
            "All set, your report is ready.",
        ]
    )
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store)
    result = loop.run("s", "write it")
    assert "Not done" in result.final_answer
    assert "out.txt" in result.final_answer
    assert "disk full" in result.final_answer


def test_no_footer_when_the_answer_mentions_the_failure(tmp_path):
    reg = ToolRegistry()
    reg.register(
        "write_file",
        {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}},
        lambda path="", content="": {"ok": False, "path": path, "error": "disk full"},
    )
    model = MockModelClient(
        [
            tool_call_response(("write_file", {"path": "out.txt", "content": "x"})),
            "I could not write out.txt because the disk is full.",
        ]
    )
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store)
    result = loop.run("s", "write it")
    assert "Not done" not in result.final_answer


def test_a_later_success_clears_the_failure(tmp_path):
    state = {"calls": 0}

    def write(path="", content=""):
        state["calls"] += 1
        if state["calls"] == 1:
            return {"ok": False, "path": path, "error": "locked"}
        return {"ok": True, "path": path}

    reg = ToolRegistry()
    reg.register(
        "write_file",
        {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}},
        write,
    )
    model = MockModelClient(
        [
            tool_call_response(("write_file", {"path": "out.txt", "content": "x"})),
            tool_call_response(("write_file", {"path": "out.txt", "content": "x"})),
            "Saved.",
        ]
    )
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store)
    result = loop.run("s", "write it")
    assert "Not done" not in result.final_answer
