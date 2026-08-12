import os

import pytest

from cowork_agent.loop import (
    AgentLoop,
    IterationBudget,
    KillSwitch,
    StopReason,
)
from cowork_agent.model import MockModelClient, ModelResponse, ToolCall
from cowork_agent.registry import ToolRegistry
from cowork_agent.state import StateStore


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
    model = MockModelClient(
        [
            ModelResponse(
                tool_calls=[ToolCall(id="c1", name="echo", arguments={"v": "hi"})]
            ),
            ModelResponse(text="finished"),
        ]
    )
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
    # Model never finishes — always emits a tool call.
    class Endless:
        def complete(self, messages):
            return ModelResponse(
                tool_calls=[ToolCall(id="c", name="echo", arguments={})]
            )

    loop = AgentLoop(Endless(), _reg_with_echo(), _store(tmp_path), max_iterations=4)
    result = loop.run("k3", "go")
    assert result.reason is StopReason.MAX_ITERATIONS
    assert result.iterations == 4


def test_budget_exhausted_stops_before_ceiling(tmp_path):
    class Endless:
        def complete(self, messages):
            return ModelResponse(
                tool_calls=[ToolCall(id="c", name="echo", arguments={})]
            )

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
            ModelResponse(
                housekeeping=True,
                tool_calls=[ToolCall(id="h1", name="echo", arguments={})],
            ),
            ModelResponse(
                housekeeping=True,
                tool_calls=[ToolCall(id="h2", name="echo", arguments={})],
            ),
            ModelResponse(
                tool_calls=[ToolCall(id="c1", name="echo", arguments={})]
            ),
            ModelResponse(text="done"),
        ]
    )
    loop = AgentLoop(
        model, _reg_with_echo(), _store(tmp_path), max_iterations=100, budget=IterationBudget(2)
    )
    result = loop.run("k5", "go")
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "done"


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
