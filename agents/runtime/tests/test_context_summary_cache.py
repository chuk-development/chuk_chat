"""Bead chuk_chat-p5xm: a turn must not block on the aux model for a summary
it already has.

Measured on the owner's host: "hi" to a long session waited 100-180 s in
``prepare`` before a 3 s model call. The executor builds a fresh ladder per
task, so every task folded the same ~90k-token middle again, synchronously.
Two fixes are pinned here:

- the summary outlives the run (``SummaryStore`` on the state database), and
  is used only while the slice it covers is unchanged;
- tier 3 updates the summary only when the payload is over the tier-2
  threshold again, not every time the tail moves by one unit.

No real model is ever called: the aux model is a mock.
"""

from __future__ import annotations

from chuk_agents_runtime.context import (
    SUMMARY_PREFIX,
    AuxSummarizer,
    ContextLadder,
    LadderConfig,
)
from chuk_agents_runtime.model import ModelResponse
from chuk_agents_runtime.state import StateStore


class RecordingAux:
    def __init__(self) -> None:
        self.prompts: list[str] = []

    def complete(self, messages: list[dict]) -> ModelResponse:
        self.prompts.append(messages[-1]["content"])
        return ModelResponse(text=f"GOAL: ship\nCOMPLETED: pass {len(self.prompts)}")


def _sysuser() -> list[dict]:
    return [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "build the thing"},
    ]


def _tool_round(index: int, chars: int = 2_000) -> list[dict]:
    return [
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": f"call_{index}",
                    "type": "function",
                    "function": {"name": "read_file", "arguments": {"path": f"f{index}.py"}},
                }
            ],
        },
        {
            "role": "tool",
            "tool_call_id": f"call_{index}",
            "name": "read_file",
            "content": (f"line {index} " * (chars // 8)),
        },
    ]


def _history(rounds: int) -> list[dict]:
    messages = _sysuser()
    for i in range(rounds):
        messages += _tool_round(i)
    return messages


def _config(**overrides) -> LadderConfig:
    # Budget 3000 tokens; tier 2 at 1500; each tool round is ~500 tokens; the
    # tail holds about one round.
    base = dict(
        context_length=4_000,
        reserved_output=1_000,
        tier1_threshold=0.10,
        tier2_threshold=0.50,
        head_messages=2,
        tail_token_budget=600,
        max_tool_result_tokens=10_000_000,
        dedup_min_chars=10_000_000,
    )
    base.update(overrides)
    return LadderConfig(**base)


def _store(tmp_path) -> tuple[StateStore, int]:
    store = StateStore(str(tmp_path / "s.db"))
    return store, store.create_session()


def _ladder(store: StateStore | None, aux: RecordingAux, **overrides) -> ContextLadder:
    return ContextLadder(
        config=_config(**overrides), summarizer=AuxSummarizer(aux), summary_store=store
    )


def _summary_text(out: list[dict]) -> str | None:
    for message in out:
        content = message.get("content")
        if isinstance(content, str) and content.startswith(SUMMARY_PREFIX):
            return content
    return None


# -- the state store ---------------------------------------------------------


def test_state_store_round_trips_the_context_summary(tmp_path):
    store, sid = _store(tmp_path)
    assert store.load_context_summary(sid) is None
    store.save_context_summary(sid, summary="A", summarized_upto=7, prefix_digest="d1")
    store.save_context_summary(sid, summary="B", summarized_upto=9, prefix_digest="d2")
    assert store.load_context_summary(sid) == {
        "summary": "B",
        "summarized_upto": 9,
        "prefix_digest": "d2",
    }
    # A second store on the same file (the next task) sees it.
    again = StateStore(str(tmp_path / "s.db"))
    assert again.load_context_summary(sid)["summary"] == "B"


# -- the summary outlives the run --------------------------------------------


def test_a_new_run_reuses_the_stored_summary_without_an_aux_call(tmp_path):
    store, sid = _store(tmp_path)
    history = _history(8)

    first_aux = RecordingAux()
    first = _ladder(store, first_aux).prepare(history, session_id=sid)
    assert len(first_aux.prompts) == 1  # the one summary this middle costs
    assert store.load_context_summary(sid) is not None

    # The next task: a fresh ladder (the executor builds one per task), the
    # user says "hi". Nothing in the summarized middle changed.
    later = history + [
        {"role": "assistant", "content": "done"},
        {"role": "user", "content": "hi"},
    ]
    second_aux = RecordingAux()
    second_ladder = _ladder(store, second_aux)
    second = second_ladder.prepare(later, session_id=sid)
    assert second_aux.prompts == []  # no blocking aux call
    assert second_ladder.last_stats.tier == 3
    assert _summary_text(second) == _summary_text(first)
    assert second[-1] == {"role": "user", "content": "hi"}


def test_the_payload_matches_what_a_fresh_summary_would_produce(tmp_path):
    """The cache changes the latency, not the shape: same head, same summary
    position, same tail as the run that paid for the summary."""
    store, sid = _store(tmp_path)
    history = _history(8)
    paid = _ladder(store, RecordingAux()).prepare(history, session_id=sid)
    reused = _ladder(store, RecordingAux()).prepare(history, session_id=sid)
    assert reused == paid


def test_a_changed_summarized_slice_drops_the_stored_summary(tmp_path):
    store, sid = _store(tmp_path)
    history = _history(8)
    _ladder(store, RecordingAux()).prepare(history, session_id=sid)

    edited = [dict(m) for m in history]
    edited[3] = {**edited[3], "content": "a different result"}  # inside the middle
    aux = RecordingAux()
    out = _ladder(store, aux).prepare(edited, session_id=sid)
    assert len(aux.prompts) == 1  # a fresh summary, never the stale one
    assert "a different result" in aux.prompts[0]
    assert _summary_text(out) is not None


def test_a_shorter_history_drops_the_stored_summary(tmp_path):
    store, sid = _store(tmp_path)
    _ladder(store, RecordingAux()).prepare(_history(12), session_id=sid)

    aux = RecordingAux()
    _ladder(store, aux).prepare(_history(8), session_id=sid)
    assert len(aux.prompts) == 1  # regenerated history: summarize what is there


def test_the_summary_is_kept_per_session(tmp_path):
    store, sid = _store(tmp_path)
    other = store.create_session()
    _ladder(store, RecordingAux()).prepare(_history(8), session_id=sid)

    aux = RecordingAux()
    _ladder(store, aux).prepare(_history(8), session_id=other)
    assert len(aux.prompts) == 1


def test_a_failing_store_costs_a_summary_not_the_turn(tmp_path):
    class BrokenStore:
        def load_context_summary(self, session_id):
            raise RuntimeError("disk gone")

        def save_context_summary(self, session_id, **kwargs):
            raise RuntimeError("disk gone")

    aux = RecordingAux()
    ladder = ContextLadder(
        config=_config(), summarizer=AuxSummarizer(aux), summary_store=BrokenStore()
    )
    out = ladder.prepare(_history(8), session_id=1)
    assert len(aux.prompts) == 1
    assert _summary_text(out) is not None


def test_without_a_session_id_nothing_is_stored(tmp_path):
    store, sid = _store(tmp_path)
    _ladder(store, RecordingAux()).prepare(_history(8))
    assert store.load_context_summary(sid) is None


# -- tier 3 only when it is needed --------------------------------------------


def test_tier3_waits_until_the_payload_is_over_the_threshold_again():
    aux = RecordingAux()
    ladder = _ladder(None, aux)
    history = _history(8)
    ladder.prepare(history)
    assert len(aux.prompts) == 1

    # One more round ages one unit out of the tail. Summary + that unit
    # verbatim + tail is still under tier 2: no aux call, nothing dropped.
    history = history + _tool_round(100)
    out = ladder.prepare(history)
    assert len(aux.prompts) == 1
    assert ladder.last_stats.tier == 3
    assert any("line 7 " in str(m.get("content")) for m in out)  # the aged unit, verbatim
    assert ladder._pressure(ladder._measure(out)) < ladder.config.tier2_threshold

    # Enough new rounds push the payload over tier 2 again: now it updates.
    for i in range(101, 106):
        history = history + _tool_round(i)
    ladder.prepare(history)
    assert len(aux.prompts) == 2
    assert "UPDATE the existing summary" in aux.prompts[1]


def test_loop_reuses_the_summary_across_runs_of_one_session(tmp_path):
    """End to end through AgentLoop and build_runtime's wiring: the second task
    of the session makes no aux call before its model request."""
    from chuk_agents_runtime.loop import AgentLoop, IterationBudget
    from chuk_agents_runtime.model import MockModelClient, tool_call_response
    from chuk_agents_runtime.registry import ToolRegistry

    store = StateStore(str(tmp_path / "s.db"))
    registry = ToolRegistry()
    counter = iter(range(1_000))
    registry.register(
        "peek",
        {"type": "object", "properties": {}},
        lambda: f"result {next(counter)} " * 250,
    )

    def run(prompt: str, script: list) -> tuple[RecordingAux, object]:
        aux = RecordingAux()
        ladder = ContextLadder(config=_config(), summarizer=AuxSummarizer(aux))
        ladder.summary_store = store  # what build_runtime wires
        loop = AgentLoop(
            MockModelClient(script), registry, store, max_iterations=12,
            budget=IterationBudget(12), system_prompt="sys", context_ladder=ladder,
        )
        return aux, loop.run("k", prompt)

    call = tool_call_response(("peek", {}))
    first_aux, first = run("go", [call] * 6 + ["done"])
    assert first.final_answer == "done"
    assert first_aux.prompts  # the long first task paid for a summary

    second_aux, second = run("hi", ["hey"])
    assert second.final_answer == "hey"
    assert second.session_id == first.session_id
    assert second_aux.prompts == []


def test_build_runtime_gives_the_ladder_the_state_store(tmp_path):
    from chuk_agents_runtime.model import MockModelClient
    from chuk_agents_runtime.runtime import build_runtime

    loop = build_runtime(
        MockModelClient([]), db_path=str(tmp_path / "a.db"), aux_model=MockModelClient([])
    )
    assert loop.context_ladder is not None
    assert isinstance(loop.context_ladder.summary_store, StateStore)
