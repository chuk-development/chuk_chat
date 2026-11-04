"""Subagent additions (DeepSeek harness #44, Hermes delegation): ``fork=true``,
the "subagent settled" note after ``wait=false``, ``output_schema`` with one
correction turn, and the ``stalled`` outcome with a partial result.

Fake runners only, except one test that drives the real child runtime with a
scripted model to prove the fork seeds the child's session."""

import json
import threading
import time

from chuk_agents_runtime.loop import LoopResult, StopReason
from chuk_agents_runtime.model import MockModelClient
from chuk_agents_runtime.runtime import SubagentConfig, build_runtime, seed_fork_history
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.subagents import (
    ChildContext,
    SubagentLimits,
    SubagentRecord,
    SubagentState,
    SubagentSupervisor,
    delegate_schema,
    fork_rows,
    make_delegate_handler,
    parse_json_answer,
    validate_output,
)

WAIT_S = 10.0


def _wait_until(predicate, timeout: float = WAIT_S) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return False


def _done(answer, *, tokens: int = 0) -> LoopResult:
    return LoopResult(
        reason=StopReason.FINISHED,
        final_answer=answer,
        iterations=1,
        session_id=1,
        tokens_spent=tokens,
    )


def _supervisor(tmp_path, runner, **kwargs) -> SubagentSupervisor:
    return SubagentSupervisor(
        parent_key="agent:test",
        store=StateStore(str(tmp_path / "parent.db")),
        runner=runner,
        root=str(tmp_path / "subagents"),
        **kwargs,
    )


# -- fork ------------------------------------------------------------------


PARENT_ROWS = [
    {"role": "system", "content": "you are the parent"},
    {"role": "user", "content": "plan the trip"},
    {
        "role": "assistant",
        "content": "",
        "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "web_search", "arguments": "{}"}}],
    },
    {"role": "tool", "tool_call_id": "c1", "name": "web_search", "content": "results"},
    {
        "role": "assistant",
        "content": "delegating",
        "tool_calls": [{"id": "c2", "type": "function", "function": {"name": "delegate_task", "arguments": "{}"}}],
    },
]


def test_fork_rows_drop_the_unanswered_delegate_call():
    rows = fork_rows(PARENT_ROWS)
    assert rows[0]["role"] == "system"
    # c1 is answered and stays; the in-flight c2 call goes, its text stays.
    assert rows[2]["tool_calls"][0]["id"] == "c1"
    assert rows[3]["role"] == "tool"
    assert rows[-1] == {"role": "assistant", "content": "delegating"}
    assert not any(
        c.get("id") == "c2" for r in rows for c in r.get("tool_calls") or []
    )


def test_fork_rows_drop_a_result_without_its_call():
    rows = fork_rows([{"role": "tool", "tool_call_id": "zz", "content": "x"}])
    assert rows == []


def test_fork_hands_the_parent_history_to_the_child(tmp_path):
    seen: list[ChildContext] = []

    def runner(ctx):
        seen.append(ctx)
        return _done("forked ok")

    sup = _supervisor(tmp_path, runner, history_provider=lambda: PARENT_ROWS)
    out = sup.delegate([{"prompt": "next step"}], fork=True)
    assert out["ok"], out
    assert out["subagents"][0]["forked"] is True
    assert seen[0].fork_history[0] == {"role": "system", "content": "you are the parent"}
    assert seen[0].prompt == "next step"


def test_fork_per_item_overrides_the_top_level(tmp_path):
    seen: list[ChildContext] = []

    def runner(ctx):
        seen.append(ctx)
        return _done("x")

    sup = _supervisor(tmp_path, runner, history_provider=lambda: PARENT_ROWS)
    out = sup.delegate([{"prompt": "a", "fork": True}, {"prompt": "b"}])
    assert out["ok"], out
    by_prompt = {c.prompt: c for c in seen}
    assert by_prompt["a"].fork_history
    assert by_prompt["b"].fork_history is None


def test_fork_without_history_is_refused(tmp_path):
    sup = _supervisor(tmp_path, lambda ctx: _done("x"))
    out = sup.delegate("go", fork=True)
    assert out["ok"] is False
    assert "fork" in out["error"]


def test_seed_fork_history_writes_once(tmp_path):
    store = StateStore(str(tmp_path / "child.db"))
    rows = fork_rows(PARENT_ROWS)
    assert seed_fork_history(store, "subagent:x", rows) is True
    # A follow-up turn in the same session gets nothing twice.
    assert seed_fork_history(store, "subagent:x", rows) is False
    sid = store.route("subagent:x")
    assert [m.content for m in store.get_conversation(sid)] == rows


def test_forked_child_runtime_keeps_the_parents_system_prompt(tmp_path):
    """The real child runner: the child session starts with the parent's rows,
    and the child's own (different) system prompt is not added, so the cached
    prefix is the parent's."""
    sent: list[list[dict]] = []

    class Recording(MockModelClient):
        def complete(self, messages):
            sent.append([dict(m) for m in messages])
            return super().complete(messages)

    config = SubagentConfig(
        model_factory=lambda: Recording(["child answer"]),
        system_prompt="CHILD SYSTEM PROMPT",
        version_workspace=False,
        runtime_kwargs={"enable_memory": False, "enable_mcp": False},
    )
    parent = build_runtime(
        MockModelClient(["parent"]),
        db_path=str(tmp_path / "parent.db"),
        workspace=str(tmp_path),
        version_workspace=False,
        enable_memory=False,
        enable_mcp=False,
        subagents=config,
    )
    sup = config.supervisor
    sup.history_provider = lambda: PARENT_ROWS
    out = sup.delegate([{"prompt": "do the next step"}], fork=True)
    sup.shutdown()
    parent_ok = out["ok"] and out["subagents"][0]["state"] == "succeeded"
    assert parent_ok, out
    first = sent[0]
    systems = [m for m in first if m.get("role") == "system"]
    assert systems and "you are the parent" in str(systems[0].get("content"))
    assert not any("CHILD SYSTEM PROMPT" in str(m.get("content")) for m in first)
    assert any("plan the trip" in str(m.get("content")) for m in first)


# -- settled notice --------------------------------------------------------


def test_wait_false_queues_one_settled_note(tmp_path):
    release = threading.Event()

    def runner(ctx):
        release.wait(WAIT_S)
        return _done("the answer is 42")

    sup = _supervisor(tmp_path, runner)
    out = sup.delegate("compute", wait=False)
    assert out["ok"] and out["waited"] is False
    assert "[subagent settled]" in out["note"]
    assert sup.pending_context() == []
    release.set()
    assert _wait_until(lambda: sup.live_count() == 0)
    notes = sup.pending_context()
    assert len(notes) == 1
    note = notes[0]
    assert note["role"] == "user" and note["role_tag"] == "subagent"
    assert note["content"].startswith("[subagent settled]")
    assert "the answer is 42" in note["content"]
    assert sup.pending_context() == []  # drained


def test_a_waited_child_gets_no_settled_note(tmp_path):
    sup = _supervisor(tmp_path, lambda ctx: _done("x"))
    out = sup.delegate("compute")
    assert out["waited"] is True
    assert sup.pending_context() == []


# -- output schema ---------------------------------------------------------

SCHEMA = {
    "type": "object",
    "properties": {"count": {"type": "integer"}},
    "required": ["count"],
}


def test_parse_json_answer_strips_a_fence_and_prose():
    assert parse_json_answer('```json\n{"a": 1}\n```') == (True, {"a": 1})
    assert parse_json_answer('Here: {"a": 2} done') == (True, {"a": 2})
    assert parse_json_answer("no json") == (False, None)


def test_validate_output_lists_errors():
    ok, value, errors = validate_output(SCHEMA, '{"count": "three"}')
    assert not ok and value == {"count": "three"}
    assert errors and "count" in errors[0]


def test_valid_output_comes_back_parsed(tmp_path):
    sup = _supervisor(tmp_path, lambda ctx: _done('{"count": 3}'))
    out = sup.delegate([{"prompt": "count", "output_schema": SCHEMA}])
    child = out["subagents"][0]
    assert child["schema_valid"] is True
    assert child["output"] == {"count": 3}


def test_one_correction_turn_fixes_the_answer(tmp_path):
    calls: list[ChildContext] = []

    def runner(ctx):
        calls.append(ctx)
        return _done("three", tokens=5) if not ctx.followup else _done('{"count": 3}', tokens=7)

    sup = _supervisor(tmp_path, runner)
    out = sup.delegate("count", output_schema=json.dumps(SCHEMA))
    child = out["subagents"][0]
    assert len(calls) == 2
    assert calls[1].followup is True and "output schema" in calls[1].prompt
    assert calls[1].session_key == calls[0].session_key  # same child session
    assert child["schema_valid"] is True and child["output"] == {"count": 3}
    assert child["tokens_spent"] == 12


def test_still_invalid_keeps_raw_text_and_flags_it(tmp_path):
    calls = []

    def runner(ctx):
        calls.append(ctx)
        return _done("still prose")

    sup = _supervisor(tmp_path, runner)
    out = sup.delegate([{"prompt": "count", "output_schema": SCHEMA}])
    child = out["subagents"][0]
    assert len(calls) == 2  # exactly one correction
    assert child["state"] == "succeeded"
    assert child["schema_valid"] is False
    assert child["result"] == "still prose"
    assert "output" not in child


def test_a_broken_schema_is_refused(tmp_path):
    sup = _supervisor(tmp_path, lambda ctx: _done("x"))
    out = sup.delegate("x", output_schema={"type": "nonsense-type"})
    assert out["ok"] is False and "output_schema" in out["error"]
    out = sup.delegate("x", output_schema="{not json")
    assert out["ok"] is False


def test_record_with_new_fields_round_trips():
    record = SubagentRecord(
        subagent_id="sa_1",
        parent_key="p",
        task_id="t",
        title="x",
        prompt="y",
        depth=1,
        state=SubagentState.STALLED,
        forked=True,
        schema_valid=True,
        output={"a": [1]},
        stall_note="no progress for 9s",
    )
    assert SubagentRecord.from_dict(json.loads(json.dumps(record.to_dict()))) == record
    assert SubagentState.STALLED.terminal


# -- stalled ---------------------------------------------------------------


def test_a_silent_child_is_stalled_and_returns_its_partial_text(tmp_path):
    def runner(ctx):
        ctx.emit({"type": "delta", "text": "found three of five sources"})
        # Then silence until stopped.
        ctx.kill_switch.wait_interrupted(WAIT_S)
        return LoopResult(
            reason=StopReason.INTERRUPTED, final_answer=None, iterations=2, session_id=1
        )

    limits = SubagentLimits(stall_idle_s=0.2, heartbeat_s=0.05, stall_grace_s=5.0)
    sup = _supervisor(tmp_path, runner, limits=limits)
    out = sup.delegate("research")
    child = out["subagents"][0]
    assert child["state"] == "stalled"
    assert child["partial"] is True
    assert "no progress" in child["stall_note"]
    assert child["result"] == "found three of five sources"


def test_a_child_that_keeps_working_is_never_stalled(tmp_path):
    def runner(ctx):
        for i in range(15):
            ctx.emit({"type": "tool", "name": "read_file", "summary": str(i)})
            time.sleep(0.03)
        return _done("done")

    limits = SubagentLimits(stall_idle_s=0.2, heartbeat_s=0.02)
    sup = _supervisor(tmp_path, runner, limits=limits)
    out = sup.delegate("work")
    assert out["subagents"][0]["state"] == "succeeded"


def test_the_wall_clock_cap_is_a_stall_too(tmp_path):
    def runner(ctx):
        while not ctx.kill_switch.wait_interrupted(0.02):
            ctx.emit({"type": "tool", "name": "loop", "summary": ""})
        return LoopResult(
            reason=StopReason.INTERRUPTED, final_answer=None, iterations=1, session_id=1
        )

    limits = SubagentLimits(stall_idle_s=None, child_timeout_s=0.2, heartbeat_s=0.05)
    sup = _supervisor(tmp_path, runner, limits=limits)
    child = sup.delegate("spin")["subagents"][0]
    assert child["state"] == "stalled"
    assert "time limit" in child["stall_note"]
    assert "tools used: loop" in child["result"]


def test_a_child_that_ignores_the_interrupt_is_settled_after_the_grace(tmp_path):
    release = threading.Event()

    def runner(ctx):
        release.wait(WAIT_S)  # one long blocking command
        return _done("late")

    limits = SubagentLimits(stall_idle_s=0.1, heartbeat_s=0.05, stall_grace_s=0.2)
    sup = _supervisor(tmp_path, runner, limits=limits)
    child = sup.delegate("block")["subagents"][0]
    assert child["state"] == "stalled"
    release.set()
    # The late return does not overwrite the settled record.
    time.sleep(0.1)
    assert sup.get(child["subagent_id"]).state is SubagentState.STALLED


# -- backends in the schema -------------------------------------------------


def test_backend_choice_is_offered_only_when_enabled(tmp_path):
    assert "backend" not in json.dumps(delegate_schema(()))
    assert "claude" in json.dumps(delegate_schema(("claude",)))


def test_an_unknown_backend_is_refused(tmp_path):
    sup = _supervisor(tmp_path, lambda ctx: _done("x"))
    out = make_delegate_handler(sup)(tasks=[{"prompt": "x", "backend": "claude"}])
    assert out["ok"] is False and "not available" in out["error"]


def test_an_external_backend_cannot_fork(tmp_path):
    sup = _supervisor(
        tmp_path, lambda ctx: _done("x"), backends=("claude",),
        history_provider=lambda: PARENT_ROWS,
    )
    out = sup.delegate([{"prompt": "x", "backend": "claude", "fork": True}])
    assert out["ok"] is False and "native" in out["error"]
