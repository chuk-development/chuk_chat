"""Near its step limit a run is told to finish, and its last step has no
tools (live test 2026-10-09: an image job spent all 50 steps in browser
loops and ended with no file, no answer and the state "finished")."""

from __future__ import annotations

from chuk_agents_runtime.loop import (
    LAST_STEP_NOTE,
    WRAP_UP_NOTE,
    AgentLoop,
    StopReason,
)
from chuk_agents_runtime.model import ModelResponse, tool_call_response
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.state import RUN_INCOMPLETE, StateStore


def _registry() -> ToolRegistry:
    reg = ToolRegistry()
    reg.register(
        "echo",
        {"type": "object", "properties": {"v": {"type": "string"}}},
        lambda v="": {"echo": v},
    )
    return reg


def _texts(messages: list[dict]) -> list[str]:
    return [m.get("content") for m in messages if isinstance(m.get("content"), str)]


class Collector:
    """Keeps searching until the last-step note arrives, then answers."""

    def __init__(self) -> None:
        self.calls: list[list[dict]] = []

    def complete(self, messages):
        self.calls.append(list(messages))
        if any(t.startswith("[runtime] This is the last step") for t in _texts(messages)):
            return ModelResponse(text="Gefunden: 3 von 6 Tassen. Es fehlen Köln, Frankfurt, Germany.")
        response = tool_call_response(("echo", {"v": "search"}))
        response.text = f"Suche weiter (Schritt {len(self.calls)})."
        return response


class Stubborn:
    """Calls a tool on every step, also on the last one."""

    def complete(self, messages):
        response = tool_call_response(("echo", {"v": "again"}))
        response.text = "Ich werde jetzt die restlichen Angebote suchen."
        return response


def test_the_run_is_told_to_finish_and_answers_on_its_last_step(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    model = Collector()
    loop = AgentLoop(model, _registry(), store, max_iterations=10)
    result = loop.run("k", "find six mugs")

    assert result.reason is StopReason.FINISHED
    assert result.iterations == 10
    assert result.final_answer.endswith("Es fehlen Köln, Frankfurt, Germany.")
    # The wrap-up note went out once, at 80 % of the limit, and the last step
    # note once, on step 10.
    rows = [m.content.get("content") for m in store.get_conversation(store.route("k"))]
    wrap = [r for r in rows if isinstance(r, str) and r.startswith("[runtime] Only")]
    assert wrap == [WRAP_UP_NOTE.format(left=2)]
    assert rows.count(LAST_STEP_NOTE) == 1
    assert any(WRAP_UP_NOTE.format(left=2) in _texts(m) for m in model.calls[8:9])
    # The toolset is back on for the next run.
    assert loop._toolset.enabled is True


def test_a_run_that_hits_the_limit_still_says_what_happened(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    loop = AgentLoop(Stubborn(), _registry(), store, max_iterations=6)
    result = loop.run("k", "find six mugs")

    assert result.reason is StopReason.MAX_ITERATIONS
    assert result.final_answer  # never NULL
    assert "Ich werde jetzt die restlichen Angebote suchen." in result.final_answer
    assert "stopped at its limit (max_iterations, 6 steps)" in result.final_answer
    assert loop._toolset.enabled is True


def test_a_short_limit_gets_no_notes(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    loop = AgentLoop(Stubborn(), _registry(), store, max_iterations=2)
    result = loop.run("k", "go")
    assert result.reason is StopReason.MAX_ITERATIONS
    rows = [m.content.get("content") for m in store.get_conversation(store.route("k"))]
    assert not any(isinstance(r, str) and r.startswith("[runtime]") for r in rows)


def test_a_limit_stopped_run_is_recorded_as_incomplete(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("k")
    store.append_message(sid, "user", {"role": "user", "content": "go"})
    store.begin_run("r1", sid, "k", "go")
    store.finish_run("r1", reason="max_iterations", final_answer="partial", iterations=50,
                     tokens_spent=1)
    store.append_message(sid, "user", {"role": "user", "content": "again"})
    store.begin_run("r2", sid, "k", "again")
    store.finish_run("r2", reason="finished", final_answer="done", iterations=3, tokens_spent=1)
    states = {r["run_id"]: r["state"] for r in store._conn().execute("SELECT run_id, state FROM runs")}
    assert states == {"r1": RUN_INCOMPLETE, "r2": "finished"}
    # A client that was away still gets the stopped run's end.
    reasons = [e["reason"] for e in store.run_terminals("k")]
    assert "max_iterations" in reasons
