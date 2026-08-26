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
    response_from_content,
)
from cowork_agent.registry import ToolRegistry
from cowork_agent.state import StateStore

# A tool call is written as a <tool_call> block in the assistant content — the one
# wire format shared by the mock and the real backend.
ECHO_CALL = '<tool_call>{"name":"echo","arguments":{"v":"hi"}}</tool_call>'
ECHO_CALL_EMPTY = '<tool_call>{"name":"echo","arguments":{}}</tool_call>'


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
    model = MockModelClient([ECHO_CALL, "finished"])
    store = _store(tmp_path)
    loop = AgentLoop(model, _reg_with_echo(), store)
    result = loop.run("k2", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "finished"
    assert result.iterations == 2
    roles = [m.role for m in store.get_conversation(result.session_id)]
    assert roles == ["user", "assistant", "tool", "assistant"]


# -- dual-counter termination --------------------------------------------


def test_max_iterations_ceiling(tmp_path):
    # Model never finishes — always emits a tool call (via the content path).
    class Endless:
        def complete(self, messages):
            return response_from_content(ECHO_CALL_EMPTY)

    loop = AgentLoop(Endless(), _reg_with_echo(), _store(tmp_path), max_iterations=4)
    result = loop.run("k3", "go")
    assert result.reason is StopReason.MAX_ITERATIONS
    assert result.iterations == 4


def test_budget_exhausted_stops_before_ceiling(tmp_path):
    class Endless:
        def complete(self, messages):
            return response_from_content(ECHO_CALL_EMPTY)

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
            response_from_content(ECHO_CALL_EMPTY, housekeeping=True),
            response_from_content(ECHO_CALL_EMPTY, housekeeping=True),
            ECHO_CALL_EMPTY,
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


def _usage_turn(content, total):
    """A tool-call turn that reports ``total`` tokens spent, so a token budget
    can be driven deterministically."""
    r = response_from_content(content)
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
            return _usage_turn(ECHO_CALL_EMPTY, 40)

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
    model = MockModelClient([_usage_turn(ECHO_CALL_EMPTY, 10_000), "done"])
    loop = AgentLoop(model, _reg_with_echo(), _store(tmp_path))
    result = loop.run("tk2", "go")
    assert result.reason is StopReason.FINISHED
    # Spend is still tracked even without a cap, so the app can show a cost.
    assert result.tokens_spent == 10_000


def test_prompt_plus_completion_counts_when_no_total(tmp_path):
    def turn(p, c):
        r = response_from_content(ECHO_CALL_EMPTY)
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
    model = MockModelClient([ECHO_CALL_EMPTY, "done"])
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
    three_calls = "".join(
        '<tool_call>{"name":"step","arguments":{"n":"%s"}}</tool_call>' % n
        for n in ("1", "2", "3")
    )

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
        def complete(self, messages):
            return response_from_content(three_calls)

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
