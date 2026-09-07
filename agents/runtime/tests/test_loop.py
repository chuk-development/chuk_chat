import os

import pytest

from cowork_agent.loop import (
    AgentLoop,
    IterationBudget,
    KillSwitch,
    StopReason,
)
from cowork_agent.model import (
    MockModelClient,
    ModelResponse,
    tool_call_response,
)
from cowork_agent.registry import ToolRegistry
from cowork_agent.state import StateStore


def _echo_call(**arguments) -> ModelResponse:
    """One native tool-calling turn asking for ``echo``.

    Tool calls never live in the assistant text: they arrive as structured
    ``tool_calls``, which is exactly what :func:`tool_call_response` builds — the
    one wire format shared by the mock and the real backend. A fresh response is
    built per call so a test may safely stamp usage onto ``raw``.
    """
    return tool_call_response(("echo", arguments))


def _store(tmp_path):
    return StateStore(str(tmp_path / "s.db"))


def _reg_with_echo():
    reg = ToolRegistry()
    reg.register(
        "echo",
        {"type": "object", "properties": {"v": {"type": "string"}}},
        lambda v="": {"echo": v},
    )
    return reg


# -- IterationBudget unit -------------------------------------------------


def test_budget_consume_and_refund():
    b = IterationBudget(3)
    b.consume()
    b.consume()
    assert b.remaining == 1
    b.refund()
    assert b.remaining == 2
    assert not b.exhausted()


def test_budget_refund_capped_at_initial():
    b = IterationBudget(2)
    b.refund()
    b.refund()
    assert b.remaining == 2  # never above the starting budget


def test_budget_exhaustion():
    b = IterationBudget(1)
    b.consume()
    assert b.exhausted()


# -- structural continue vs finish ---------------------------------------


def test_loop_finishes_on_bare_text(tmp_path):
    model = MockModelClient([ModelResponse(text="all done")])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path))
    result = loop.run("k1", "hello")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "all done"
    assert result.iterations == 1


def test_loop_continues_on_tool_call_then_finishes(tmp_path):
    model = MockModelClient([_echo_call(v="hi"), "finished"])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)
    result = loop.run("k2", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "finished"
    assert result.iterations == 2
    roles = [m.role for m in store.get_conversation(result.session_id)]
    assert roles == ["user", "assistant", "tool", "assistant"]


# The explicit terminal action: a `finish` tool call ends the run with its
# summary as the final answer, even though it is structurally a tool call (which
# would otherwise continue the loop).
def _finish_call(summary: str = "the result") -> ModelResponse:
    return tool_call_response(("finish", {"summary": summary}))


def test_finish_tool_terminates_with_summary(tmp_path):
    from cowork_agent.tools import register_finish

    reg = _reg_with_echo()
    register_finish(reg)
    store = _store(tmp_path)
    # A tool round, then the model calls `finish` instead of returning bare text.
    model = MockModelClient([_echo_call(v="hi"), _finish_call()])
    loop = AgentLoop(model, reg, store)
    result = loop.run("kf", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "the result"
    assert result.iterations == 2
    # The finish tool call is still recorded (audit trail) before the stop.
    roles = [m.role for m in store.get_conversation(result.session_id)]
    assert roles == ["user", "assistant", "tool", "assistant", "tool"]


# -- CodeAct python tool: really runs code in the env --------------------

PYTHON_CODE = "import sys\nprint(6 * 7)\nsys.exit(3)"


def test_python_tool_runs_code_in_env(tmp_path):
    from cowork_agent.environment import LocalEnvironment
    from cowork_agent.tools import register_run_python

    reg = _reg_with_echo()
    register_run_python(reg, LocalEnvironment())

    # The model calls `python`, then finishes with bare text.
    model = MockModelClient(
        [tool_call_response(("python", {"code": PYTHON_CODE})), "done"]
    )
    store = _store(tmp_path)
    loop = AgentLoop(model, reg, store)
    result = loop.run("kpy", "go")
    assert result.reason is StopReason.FINISHED

    tool_rows = [
        m for m in store.get_conversation(result.session_id) if m.role == "tool"
    ]
    assert len(tool_rows) == 1
    payload = tool_rows[0].content["content"]
    assert payload["exit_code"] == 3
    assert payload["stdout"].strip() == "42"
    assert payload["timed_out"] is False


# -- dual-counter termination --------------------------------------------


def test_max_iterations_ceiling(tmp_path):
    # Model never finishes — every turn carries a tool call, so the loop only
    # ever continues.
    class Endless:
        def complete(self, messages):
            return _echo_call()

    loop = AgentLoop(Endless(), _reg_with_echo(), _store(tmp_path), max_iterations=4)
    result = loop.run("k3", "go")
    assert result.reason is StopReason.MAX_ITERATIONS
    assert result.iterations == 4


def test_budget_exhausted_stops_before_ceiling(tmp_path):
    class Endless:
        def complete(self, messages):
            return _echo_call()

    loop = AgentLoop(
        Endless(),
        _reg_with_echo(),
        _store(tmp_path),
        max_iterations=100,
        budget=IterationBudget(3),
    )
    result = loop.run("k4", "go")
    assert result.reason is StopReason.BUDGET_EXHAUSTED
    assert result.iterations == 3


def test_housekeeping_round_is_refunded(tmp_path):
    # Two housekeeping rounds (refunded) + real work, under a tight budget of 2.
    # Without refunds this would exhaust; with refunds it reaches the answer.
    model = MockModelClient(
        [
            tool_call_response(("echo", {}), housekeeping=True),
            tool_call_response(("echo", {}), housekeeping=True),
            _echo_call(),
            "done",
        ]
    )
    loop = AgentLoop(
        model, _reg_with_echo(), _store(tmp_path), max_iterations=100, budget=IterationBudget(2)
    )
    result = loop.run("k5", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "done"


# -- token budget (§7.6) --------------------------------------------------


def _usage_turn(total):
    """A tool-call turn that reports ``total`` tokens spent, so a token budget
    can be driven deterministically."""
    r = _echo_call()
    r.raw = dict(r.raw)
    r.raw["usage"] = {"total_tokens": total}
    return r


def test_token_budget_stops_before_the_next_round(tmp_path):
    # Each round costs 40 tokens; the cap is 100. Round 1 (0 spent) runs, round 2
    # (40 spent) runs, round 3 (80 spent) runs, then 120 >= 100 stops it. So the
    # run makes exactly 3 model calls and the overshoot is one round, never more.
    class Spender:
        def __init__(self):
            self.calls = 0

        def complete(self, messages):
            self.calls += 1
            return _usage_turn(40)

    model = Spender()
    loop = AgentLoop(
        model,
        _reg_with_echo(),
        _store(tmp_path),
        max_iterations=100,
        token_budget=100,
    )
    result = loop.run("tk1", "go")
    assert result.reason is StopReason.TOKEN_BUDGET_EXHAUSTED
    assert model.calls == 3
    assert result.tokens_spent == 120
    assert loop.tokens_spent == 120


def test_no_token_budget_means_no_token_stop(tmp_path):
    model = MockModelClient([_usage_turn(10_000), "done"])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path))
    result = loop.run("tk2", "go")
    assert result.reason is StopReason.FINISHED
    # Spend is still tracked even without a cap, so the app can show a cost.
    assert result.tokens_spent == 10_000


def test_prompt_plus_completion_counts_when_no_total(tmp_path):
    def turn(p, c):
        r = _echo_call()
        r.raw = {"usage": {"prompt_tokens": p, "completion_tokens": c}}
        return r

    model = MockModelClient([turn(30, 30), turn(30, 30), "done"])
    loop = AgentLoop(
        model, _reg_with_echo(), _store(tmp_path), max_iterations=100, token_budget=100
    )
    result = loop.run("tk3", "go")
    # 0 -> run(+60) -> 60 run(+60) -> 120 >= 100 stop. Two model calls.
    assert result.reason is StopReason.TOKEN_BUDGET_EXHAUSTED
    assert result.tokens_spent == 120


def test_missing_usage_does_not_advance_the_budget(tmp_path):
    # A backend that sends no usage frame must not silently exhaust the cap; the
    # run instead ends on its own terms (here, the bare-text answer).
    model = MockModelClient([_echo_call(), "done"])
    loop = AgentLoop(
        model, _reg_with_echo(), _store(tmp_path), max_iterations=100, token_budget=50
    )
    result = loop.run("tk4", "go")
    assert result.reason is StopReason.FINISHED
    assert result.tokens_spent == 0


def test_negative_token_budget_is_refused(tmp_path):
    with pytest.raises(ValueError):
        AgentLoop(
            MockModelClient(["x"]),
            _reg_with_echo(),
            _store(tmp_path),
            token_budget=-1,
        )


# -- two-tier kill switch -------------------------------------------------


def test_interrupt_stops_at_loop_top(tmp_path):
    ks = KillSwitch()
    ks.interrupt()
    model = MockModelClient([ModelResponse(text="never reached")])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path), kill_switch=ks)
    result = loop.run("k6", "go")
    assert result.reason is StopReason.INTERRUPTED
    assert result.iterations == 0


def test_estop_engaged_when_sentinel_exists(tmp_path):
    sentinel = tmp_path / "ESTOP"
    sentinel.write_text("stop")
    ks = KillSwitch(estop_path=str(sentinel))
    model = MockModelClient([ModelResponse(text="never")])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path), kill_switch=ks)
    result = loop.run("k7", "go")
    assert result.reason is StopReason.ESTOP


def test_estop_absent_lets_loop_run(tmp_path):
    ks = KillSwitch(estop_path=str(tmp_path / "missing"))
    assert ks.estop_engaged() is False


def test_estop_stat_error_counts_as_engaged(tmp_path):
    # A path that traverses *through* a regular file makes os.stat raise
    # NotADirectoryError — an OSError that is not FileNotFoundError. The
    # fail-safe rule treats that as engaged.
    afile = tmp_path / "afile"
    afile.write_text("x")
    weird = str(afile / "under" / "ESTOP")
    with pytest.raises(OSError) as exc:
        os.stat(weird)
    assert not isinstance(exc.value, FileNotFoundError)  # it's NotADirectoryError
    ks = KillSwitch(estop_path=weird)
    assert ks.estop_engaged() is True


# -- the interrupt cancels work in flight ---------------------------------


def test_interrupt_notifies_its_listeners_once():
    """The listener is how a Stop reaches work already running (a command, a
    subagent tree) instead of only ending the loop between rounds."""
    ks = KillSwitch()
    fired: list[str] = []
    ks.on_interrupt(lambda: fired.append("a"))
    ks.on_interrupt(lambda: fired.append("b"))
    ks.interrupt()
    ks.interrupt()  # idempotent: a second Stop is not a second cancel
    assert fired == ["a", "b"]


def test_a_listener_registered_after_the_interrupt_fires_immediately():
    """A child whose runtime is built one instant too late must not keep running."""
    ks = KillSwitch()
    ks.interrupt()
    fired: list[str] = []
    ks.on_interrupt(lambda: fired.append("late"))
    assert fired == ["late"]


def test_a_broken_listener_does_not_block_the_others():
    ks = KillSwitch()
    fired: list[str] = []

    def boom() -> None:
        raise RuntimeError("no")

    ks.on_interrupt(boom)
    ks.on_interrupt(lambda: fired.append("still ran"))
    ks.interrupt()
    assert ks.interrupted() is True
    assert fired == ["still ran"]


def test_wait_interrupted_returns_false_on_timeout():
    ks = KillSwitch()
    assert ks.wait_interrupted(0.01) is False
    ks.interrupt()
    assert ks.wait_interrupted(0.01) is True


class _CancelledModel:
    """A model whose call dies because the caller cancelled it — the real
    ``BackendModelClient`` behaviour when its socket is closed under a blocking
    recv."""

    def __init__(self, kill: KillSwitch) -> None:
        self._kill = kill
        self.calls = 0

    def complete(self, messages):
        self.calls += 1
        self._kill.interrupt()  # stand-in for "Stop landed while we were waiting"
        raise RuntimeError("socket closed")


def test_a_model_call_that_dies_while_stopping_is_reported_as_interrupted(tmp_path):
    ks = KillSwitch()
    model = _CancelledModel(ks)
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path), kill_switch=ks)
    result = loop.run("k8", "go")
    assert result.reason is StopReason.INTERRUPTED
    assert result.final_answer is None
    assert model.calls == 1


def test_a_model_failure_without_a_stop_still_raises(tmp_path):
    """Only a stop turns a dead model call into a clean stop; a real failure must
    stay a failure."""

    class _Broken:
        def complete(self, messages):
            raise RuntimeError("upstream is down")

    loop = AgentLoop(_Broken(), _reg_with_echo(), _store(tmp_path))
    with pytest.raises(RuntimeError):
        loop.run("k9", "go")


def test_an_interrupt_during_the_turn_beats_a_finished_answer(tmp_path):
    """The model answered, but the user had already pressed Stop: reporting
    "finished" would tell the app the agent completed the task."""
    ks = KillSwitch()

    class _AnswersWhileStopping:
        def complete(self, messages):
            ks.interrupt()
            return ModelResponse(text="all done!")

    loop = AgentLoop(
        _AnswersWhileStopping(), _reg_with_echo(), _store(tmp_path), kill_switch=ks
    )
    result = loop.run("k10", "go")
    assert result.reason is StopReason.INTERRUPTED
    assert result.final_answer is None
    # The turn itself is kept: it is real history for the next session.
    assert any(
        m.content.get("content") == "all done!"
        for m in loop.store.get_conversation(loop.store.route("k10"))
    )


def test_an_interrupt_mid_batch_skips_the_rest_but_answers_every_call(tmp_path):
    """A turn can carry several tool calls, each of them slow. The stop lands
    between them — and every call still gets a result row, or a resumed session
    would read an assistant turn with a dangling tool call."""
    ks = KillSwitch()
    ran: list[str] = []

    def step(n: str = "") -> dict:
        ran.append(n)
        if n == "1":
            # The Stop frame lands on the serve thread while the worker is
            # halfway through this batch.
            ks.interrupt()
        return {"ok": n}

    reg = ToolRegistry()
    reg.register(
        "step", {"type": "object", "properties": {"n": {"type": "string"}}}, step
    )

    class _ThreeToolCalls:
        """One turn, three native tool calls — the batch the stop lands inside."""

        def complete(self, messages):
            return tool_call_response(
                *(("step", {"n": n}) for n in ("1", "2", "3"))
            )

    loop = AgentLoop(_ThreeToolCalls(), reg, _store(tmp_path), kill_switch=ks)
    result = loop.run("k11", "go")

    assert result.reason is StopReason.INTERRUPTED
    assert ran == ["1"]  # 2 and 3 were never executed
    rows = [
        m.content
        for m in loop.store.get_conversation(loop.store.route("k11"))
        if m.content.get("role") == "tool"
    ]
    assert len(rows) == 3  # every call answered, two of them "not run"
    assert rows[0]["content"] == {"ok": "1"}
    assert all("stopped" in str(r["content"]) for r in rows[1:])


# -- debug context tap ----------------------------------------------------


def test_debug_observer_gets_each_round_in_the_contract_shape(tmp_path):
    """The debug "copy raw context" tap fires once per model round with the exact
    outbound payload and the ladder's stats, in the fixed dict shape."""
    from cowork_agent.context import ContextLadder

    # Round 1 makes a tool call (continues); round 2 is bare text (finishes).
    model = MockModelClient([_echo_call(v="hi"), "done"])
    ladder = ContextLadder()
    captured: list[dict] = []

    loop = AgentLoop(
        model,
        _reg_with_echo(),
        _store(tmp_path),
        system_prompt="you are a tester",
        context_ladder=ladder,
        debug_observer=captured.append,
    )
    result = loop.run("dbg-1", "go")
    assert result.reason is StopReason.FINISHED

    # One call per model round.
    assert len(captured) == len(model.calls) == 2
    for i, event in enumerate(captured):
        assert event["type"] == "debug_context"
        assert event["session_key"] == "dbg-1"
        # Round is 1-based and increments.
        assert event["round"] == i + 1
        # The messages are exactly what went to the model that round.
        assert event["messages"] == model.calls[i]
        # Stats carry the four ladder fields.
        stats = event["stats"]
        assert set(stats) == {"tier", "pressure", "tokens_before", "tokens_after", "timing"}
        assert stats["timing"]["context_prepare_ms"] >= 0
        assert stats["timing"]["model_complete_ms"] >= 0
        assert isinstance(stats["tier"], int)
        assert isinstance(stats["pressure"], float)

    # The first round's payload is the seeded system prompt + the user message.
    first = captured[0]["messages"]
    assert first[0]["role"] == "system"
    assert first[-1]["content"] == "go"


def test_no_debug_observer_means_no_tap(tmp_path):
    """Unset observer -> the loop never tries to call one (zero overhead)."""
    model = MockModelClient(["done"])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path))
    result = loop.run("dbg-2", "go")
    # Nothing to assert but a clean finish: the point is it does not raise trying
    # to call a ``None`` observer.
    assert result.reason is StopReason.FINISHED


# -- reasoning persistence (the thinking block survives a replay) -----------


def test_assistant_turn_persists_its_reasoning_for_replay(tmp_path):
    """A thinking model's reasoning for a turn is stored on the assistant row
    (``reasoning``), so ``StateStore.replay_events`` can rebuild the thinking
    block. A turn without reasoning stores no such key."""
    thinking = ModelResponse(
        text="all done", raw={"reasoning": "first I check, then I answer"}
    )
    model = MockModelClient([thinking])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)
    result = loop.run("k-reason", "hello")
    assert result.reason is StopReason.FINISHED
    rows = store.get_conversation(result.session_id)
    assistant = [m for m in rows if m.role == "assistant"]
    assert len(assistant) == 1
    assert assistant[0].content["content"] == "all done"
    assert assistant[0].content["reasoning"] == "first I check, then I answer"


def test_assistant_turn_without_reasoning_stores_no_reasoning_key(tmp_path):
    model = MockModelClient([ModelResponse(text="plain", raw={"reasoning": "   "})])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)
    result = loop.run("k-plain", "hello")
    assistant = [m for m in store.get_conversation(result.session_id) if m.role == "assistant"]
    assert "reasoning" not in assistant[0].content


def test_tool_call_turn_persists_its_reasoning_too(tmp_path):
    """A thinking model reasons about its tool calls as well; that reasoning is
    kept on the tool-call turn, and the stored turn still round-trips to the
    model as a plain assistant turn (``_assistant_turn`` ignores the key)."""
    call = _echo_call(v="hi")
    call.raw["reasoning"] = "I should echo first"
    model = MockModelClient([call, "finished"])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)
    result = loop.run("k-tool-reason", "go")
    assert result.reason is StopReason.FINISHED
    assistant = [m for m in store.get_conversation(result.session_id) if m.role == "assistant"]
    assert assistant[0].content["reasoning"] == "I should echo first"
    assert assistant[0].content["tool_calls"][0]["function"]["name"] == "echo"
    assert "reasoning" not in assistant[1].content


# -- retry: replace the last answer, do not ask again (bead cowork-bkw) ------


def test_a_regenerate_replaces_the_turn_instead_of_repeating_it(tmp_path):
    """Retry sends the same prompt again. Without ``regenerate`` the model would
    be handed a history in which the user asked twice and it answered twice."""
    model = MockModelClient([ModelResponse(text="five"), ModelResponse(text="four")])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)

    first = loop.run("k", "what is 2+2")
    loop.run("k", "what is 2+2", regenerate=True)

    convo = store.get_conversation(first.session_id)
    assert [(m.role, m.content.get("content")) for m in convo] == [
        ("user", "what is 2+2"),
        ("assistant", "four"),
    ]


def test_four_retries_leave_one_question_and_the_newest_answer(tmp_path):
    """The reported shape: four Retries used to leave four copies of the
    question in the transcript and in the model's context."""
    model = MockModelClient([ModelResponse(text=t) for t in ("a", "b", "c", "d", "e")])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)

    result = loop.run("k", "why")
    for _ in range(4):
        loop.run("k", "why", regenerate=True)

    convo = store.get_conversation(result.session_id)
    assert [m.role for m in convo] == ["user", "assistant"]
    assert convo[1].content["content"] == "e"


def test_a_normal_send_still_appends(tmp_path):
    """Two different questions must stay two turns — the fix must not fold a
    conversation just because it is a conversation."""
    model = MockModelClient([ModelResponse(text="one"), ModelResponse(text="two")])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)

    result = loop.run("k", "first")
    loop.run("k", "second")

    convo = store.get_conversation(result.session_id)
    assert [m.role for m in convo] == [
        "user",
        "assistant",
        "user",
        "assistant",
    ]


def test_the_same_question_asked_twice_on_purpose_is_still_two_turns(tmp_path):
    """The case a text-matching fix would have broken: a reader may legitimately
    send the identical prompt again. Only an explicit ``regenerate`` folds."""
    model = MockModelClient([ModelResponse(text="one"), ModelResponse(text="two")])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)

    result = loop.run("k", "again")
    loop.run("k", "again")

    convo = store.get_conversation(result.session_id)
    assert len(convo) == 4


def test_a_regenerate_on_a_fresh_session_just_runs(tmp_path):
    model = MockModelClient([ModelResponse(text="hi")])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)

    result = loop.run("fresh", "hello", regenerate=True)

    assert result.reason is StopReason.FINISHED
    assert [m.role for m in store.get_conversation(result.session_id)] == [
        "user",
        "assistant",
    ]


# -- tool events: one per native tool call, after its result -------------------


def test_tool_event_observer_gets_one_event_per_native_call(tmp_path):
    """docs/WIRE_CONTRACT.md "Tool events and timestamps": the loop is the one
    source of live tool frames — one per native tool call, after the result,
    in the shared shape (name, arguments, result, status, clocks)."""
    seen: list[dict] = []
    model = MockModelClient([_echo_call(v="hi"), "finished"])
    loop = AgentLoop(
        model, _reg_with_echo(), _store(tmp_path), tool_event_observer=seen.append
    )
    result = loop.run("k-tool-ev", "go")
    assert result.reason is StopReason.FINISHED
    assert len(seen) == 1
    event = seen[0]
    assert event["name"] == "echo"
    assert event["arguments"] == {"v": "hi"}
    assert event["result"] == '{"echo":"hi"}'
    assert event["status"] == "completed"
    assert event["call_id"]
    assert event["started_at"] <= event["completed_at"]
    assert "command" not in event


def test_tool_event_marks_an_unknown_tool_as_error(tmp_path):
    seen: list[dict] = []
    model = MockModelClient([tool_call_response(("nope", {"a": 1})), "finished"])
    loop = AgentLoop(
        model, _reg_with_echo(), _store(tmp_path), tool_event_observer=seen.append
    )
    loop.run("k-tool-err", "go")
    assert len(seen) == 1
    assert seen[0]["name"] == "nope"
    assert seen[0]["status"] == "error"
    assert "unknown tool" in seen[0]["result"]


def test_a_raising_tool_event_observer_never_aborts_the_run(tmp_path):
    def boom(_event: dict) -> None:
        raise RuntimeError("sink gone")

    model = MockModelClient([_echo_call(v="hi"), "finished"])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path), tool_event_observer=boom)
    result = loop.run("k-tool-boom", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "finished"


def test_live_tool_event_matches_the_replayed_one(tmp_path):
    """Same frame on both paths (minus replay/mid and the exact clocks): what
    the loop streamed live is what the store replays."""
    seen: list[dict] = []
    model = MockModelClient([_echo_call(v="hi"), "finished"])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store, tool_event_observer=seen.append)
    result = loop.run("k-tool-same", "go")
    replayed = [e for e in store.replay_events(result.session_id) if e["type"] == "tool"]
    assert len(replayed) == 1 and len(seen) == 1

    def stable(event: dict) -> dict:
        return {
            k: v
            for k, v in event.items()
            if k not in ("type", "replay", "mid", "started_at", "completed_at", "duration_ms")
        }

    assert stable(replayed[0]) == stable(seen[0])
    assert replayed[0]["started_at"] <= replayed[0]["completed_at"]


# -- memory hooks (bead cowork-2tq.3): recall at task start, turn observer ------


def test_recall_provider_rows_land_after_the_prompt_as_memory_rows(tmp_path):
    seen: list[str] = []

    def recall(prompt: str) -> list[dict]:
        seen.append(prompt)
        return [{"role_tag": "memory", "role": "user", "content": "[memory recall]\n- port is 8787"}]

    model = MockModelClient([ModelResponse(text="ok")])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store, recall_provider=recall)
    result = loop.run("k-recall", "start the server")
    assert seen == ["start the server"]
    rows = store.get_conversation(result.session_id)
    assert [m.role for m in rows] == ["user", "memory", "assistant"]
    assert rows[1].content == {"role": "user", "content": "[memory recall]\n- port is 8787"}
    # The model saw the recall in its context.
    sent = model.calls[0] if hasattr(model, "calls") else None
    if sent is not None:
        assert any("port is 8787" in str(m.get("content")) for m in sent)


def test_memory_rows_never_replay_as_user_turns(tmp_path):
    def recall(prompt: str) -> list[dict]:
        return [{"role_tag": "memory", "role": "user", "content": "[memory recall]\n- x"}]

    store = _store(tmp_path)
    loop = AgentLoop(MockModelClient(["ok"]), _reg_with_echo(), store, recall_provider=recall)
    result = loop.run("k-recall-replay", "hello")
    kinds = [(e["type"], e.get("text")) for e in store.replay_events(result.session_id)]
    assert kinds == [("user", "hello"), ("delta", "ok")]


def test_turn_observer_gets_the_prompt_the_answer_and_the_tools(tmp_path):
    from cowork_agent.loop import TurnRecord

    records: list[TurnRecord] = []
    model = MockModelClient([_echo_call(v="hi"), "finished"])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path), turn_observer=records.append)
    result = loop.run("k-turn", "echo hi")
    assert len(records) == 1
    record = records[0]
    assert record.session_key == "k-turn" and record.session_id == result.session_id
    assert record.user_message == "echo hi"
    assert record.final_answer == "finished"
    assert record.reason is StopReason.FINISHED
    assert record.tool_names == ("echo",)


def test_raising_memory_hooks_never_break_the_run(tmp_path):
    def boom(*_a, **_k):
        raise RuntimeError("memory down")

    loop = AgentLoop(
        MockModelClient(["ok"]), _reg_with_echo(), _store(tmp_path),
        recall_provider=boom, turn_observer=boom,
    )
    result = loop.run("k-boom", "hello")
    assert result.reason is StopReason.FINISHED and result.final_answer == "ok"
