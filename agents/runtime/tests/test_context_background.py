"""Bead cowork-z9mo: a summary is made after the run and off the turn path.

Pinned here:

- a turn that needs a summary does not wait for it: it sends the tier-1
  payload (or the last valid summary plus the aged slice) while that stays
  under the hard ceiling, and a background job writes the summary;
- the next turn only loads it (no aux call in ``prepare``);
- a turn that starts while a job runs does not wait and starts no second job;
- only a payload over the hard ceiling waits for one blocking aux call, and
  that is logged;
- ``plan_ahead`` (the loop calls it after each run) starts the job when the
  next turn would need it;
- the idle rule: a user message after a long pause drops the old tool calls
  and tool results; the text stays.

No real model is called: the aux summarizer is a stub.
"""

from __future__ import annotations

import logging
import threading
import time

import pytest

from chuk_agents_runtime.context import (
    DUP_KEY,
    IDLE_DROP_KEY,
    SUMMARY_PREFIX,
    ContextLadder,
    LadderConfig,
    background_summaries,
    expand_back_references,
    idle_cut,
)
from chuk_agents_runtime.state import StateStore


class StubSummarizer:
    """Counts calls; optionally blocks until released (a slow aux model)."""

    def __init__(self, gate: threading.Event | None = None) -> None:
        self.calls: list[tuple[str, str | None]] = []
        self.gate = gate
        self.started = threading.Event()
        self.closed = False

    def summarize(self, transcript: str, previous: str | None) -> str:
        self.calls.append((transcript, previous))
        self.started.set()
        if self.gate is not None:
            assert self.gate.wait(10)
        return f"GOAL: ship\nCOMPLETED: pass {len(self.calls)}"

    def close(self) -> None:
        self.closed = True


class Factory:
    """``summarizer_factory``: every background job gets a fresh stub."""

    def __init__(self, gate: threading.Event | None = None) -> None:
        self.built: list[StubSummarizer] = []
        self.gate = gate

    def __call__(self) -> StubSummarizer:
        stub = StubSummarizer(self.gate)
        self.built.append(stub)
        return stub


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
                    "function": {
                        "name": "read_file",
                        "arguments": {"path": f"f{index}.py"},
                    },
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
    # Budget 5000 tokens; tier 2 at 2500; hard ceiling at 4500. One tool
    # round is ~500 tokens; the tail holds about one round.
    base = dict(
        context_length=6_000,
        reserved_output=1_000,
        tier1_threshold=0.10,
        tier2_threshold=0.50,
        hard_threshold=0.90,
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


def _ladder(
    store, blocking: StubSummarizer, factory: Factory | None, **overrides
) -> ContextLadder:
    return ContextLadder(
        config=_config(**overrides),
        summarizer=blocking,
        summary_store=store,
        summarizer_factory=factory,
    )


def _summary_of(out: list[dict]) -> str | None:
    for message in out:
        content = message.get("content")
        if isinstance(content, str) and content.startswith(SUMMARY_PREFIX):
            return content
    return None


# -- the turn does not wait ------------------------------------------------------


def test_a_needed_summary_goes_to_the_background_and_the_turn_does_not_wait(tmp_path):
    store, sid = _store(tmp_path)
    blocking = StubSummarizer()
    factory = Factory()
    ladder = _ladder(store, blocking, factory)
    history = _history(8)

    out = ladder.prepare(history, session_id=sid)
    assert blocking.calls == []  # nothing on the turn path
    assert ladder.last_stats.deferred is True
    assert ladder.last_stats.blocking_aux is False
    assert ladder.last_stats.tier == 1
    assert _summary_of(out) is None  # the tier-1 payload, it fits the ceiling
    assert ladder._pressure(ladder._measure(out)) < ladder.config.hard_threshold

    assert ladder.wait_background(5)
    assert len(factory.built) == 1 and len(factory.built[0].calls) == 1
    assert factory.built[0].closed is True  # the job closes its own client
    row = store.load_context_summary(sid)
    assert row is not None and row["summary"].startswith("GOAL: ship")


def test_the_next_turn_only_loads_the_background_summary(tmp_path):
    store, sid = _store(tmp_path)
    history = _history(8)
    first = _ladder(store, StubSummarizer(), Factory())
    first.prepare(history, session_id=sid)
    assert first.wait_background(5)

    later = history + [
        {"role": "assistant", "content": "done"},
        {"role": "user", "content": "hi"},
    ]
    blocking = StubSummarizer()
    factory = Factory()
    second = _ladder(store, blocking, factory)
    started = time.perf_counter()
    out = second.prepare(later, session_id=sid)
    elapsed = time.perf_counter() - started
    assert blocking.calls == [] and factory.built == []
    assert second.last_stats.tier == 3
    assert _summary_of(out) is not None
    assert out[-1] == {"role": "user", "content": "hi"}
    assert elapsed < 1.0


def test_a_live_ladder_picks_up_the_background_summary_in_its_next_round(tmp_path):
    store, sid = _store(tmp_path)
    ladder = _ladder(store, StubSummarizer(), Factory())
    history = _history(8)
    ladder.prepare(history, session_id=sid)
    assert ladder.wait_background(5)

    history = history + _tool_round(100)
    out = ladder.prepare(history, session_id=sid)
    assert ladder.last_stats.tier == 3
    assert _summary_of(out) is not None


def test_a_turn_during_a_running_job_does_not_wait_and_starts_no_second_job(tmp_path):
    store, sid = _store(tmp_path)
    gate = threading.Event()
    factory = Factory(gate)
    first = _ladder(store, StubSummarizer(), factory)
    history = _history(8)
    try:
        first.prepare(history, session_id=sid)
        assert factory.built and factory.built[0].started.wait(5)

        blocking = StubSummarizer()
        second = _ladder(store, blocking, factory)
        later = history + [{"role": "user", "content": "hi"}]
        started = time.perf_counter()
        out = second.prepare(later, session_id=sid)
        assert time.perf_counter() - started < 1.0
        assert blocking.calls == []
        assert len(factory.built) == 1  # still the one job
        assert second.last_stats.deferred is True
        assert out[-1] == {"role": "user", "content": "hi"}
    finally:
        gate.set()
    assert first.wait_background(5)
    assert store.load_context_summary(sid) is not None


def test_during_a_job_the_last_valid_summary_is_used(tmp_path):
    store, sid = _store(tmp_path)
    history = _history(8)
    seed = _ladder(store, StubSummarizer(), Factory())
    seed.prepare(history, session_id=sid)
    assert seed.wait_background(5)
    old = store.load_context_summary(sid)["summary"]

    # Enough new rounds that the summary needs an update.
    for i in range(100, 106):
        history = history + _tool_round(i)
    gate = threading.Event()
    factory = Factory(gate)
    try:
        ladder = _ladder(store, StubSummarizer(), factory)
        out = ladder.prepare(history, session_id=sid)
        assert ladder.last_stats.deferred is True
        assert ladder.last_stats.tier == 3
        assert old in _summary_of(out)  # the last valid one, plus the slice verbatim
        assert any("line 103 " in str(m.get("content")) for m in out)
    finally:
        gate.set()
    assert ladder.wait_background(5)
    assert factory.built[0].calls[0][1] == old  # the job UPDATES the old summary


def test_over_the_hard_ceiling_the_turn_blocks_once_and_says_so(tmp_path, caplog):
    store, sid = _store(tmp_path)
    blocking = StubSummarizer()
    factory = Factory()
    ladder = _ladder(store, blocking, factory)
    history = _history(14)  # ~7000 tokens: over the 4500-token ceiling
    with caplog.at_level(logging.WARNING, logger="chuk_agents_runtime.context"):
        out = ladder.prepare(history, session_id=sid)
    assert len(blocking.calls) == 1
    assert ladder.last_stats.blocking_aux is True
    assert ladder.last_stats.deferred is False
    assert factory.built == []
    assert _summary_of(out) is not None
    assert ladder._pressure(ladder._measure(out)) < ladder.config.hard_threshold
    assert any("blocking aux summary" in r.getMessage() for r in caplog.records)
    assert store.load_context_summary(sid) is not None


def test_a_background_result_never_replaces_a_newer_stored_summary(tmp_path):
    store, sid = _store(tmp_path)
    gate = threading.Event()
    factory = Factory(gate)
    ladder = _ladder(store, StubSummarizer(), factory)
    history = _history(8)
    try:
        ladder.prepare(history, session_id=sid)
        assert factory.built[0].started.wait(5)
        # Meanwhile a longer history paid a blocking summary on the turn path.
        store.save_context_summary(
            sid, summary="NEWER", summarized_upto=len(history) + 10, prefix_digest="x"
        )
    finally:
        gate.set()
    assert ladder.wait_background(5)
    assert store.load_context_summary(sid)["summary"] == "NEWER"


def test_without_a_factory_the_ladder_blocks_as_before(tmp_path):
    store, sid = _store(tmp_path)
    blocking = StubSummarizer()
    ladder = _ladder(store, blocking, None)
    ladder.prepare(_history(8), session_id=sid)
    assert len(blocking.calls) == 1
    assert ladder.last_stats.blocking_aux is True


# -- plan_ahead: after the run ---------------------------------------------------


def test_plan_ahead_starts_the_summary_the_next_turn_would_need(tmp_path):
    store, sid = _store(tmp_path)
    factory = Factory()
    history = _history(8) + [{"role": "assistant", "content": "done"}]
    ladder = _ladder(store, StubSummarizer(), factory)
    assert ladder.plan_ahead(history, session_id=sid) is True
    assert ladder.wait_background(5)
    assert len(factory.built) == 1

    # The next turn of the session: a fresh ladder, no aux call at all.
    blocking = StubSummarizer()
    nxt = _ladder(store, blocking, Factory())
    out = nxt.prepare(history + [{"role": "user", "content": "hi"}], session_id=sid)
    assert blocking.calls == []
    assert nxt.last_stats.deferred is False
    assert _summary_of(out) is not None


def test_plan_ahead_does_nothing_for_a_short_session(tmp_path):
    store, sid = _store(tmp_path)
    factory = Factory()
    ladder = _ladder(store, StubSummarizer(), factory)
    assert ladder.plan_ahead(_history(2), session_id=sid) is False
    assert factory.built == []


def test_plan_ahead_does_nothing_while_the_summary_still_fits(tmp_path):
    store, sid = _store(tmp_path)
    history = _history(8)
    seed = _ladder(store, StubSummarizer(), Factory())
    seed.plan_ahead(history, session_id=sid)
    assert seed.wait_background(5)

    factory = Factory()
    ladder = _ladder(store, StubSummarizer(), factory)
    assert ladder.plan_ahead(history + _tool_round(50), session_id=sid) is False
    assert factory.built == []


def test_plan_ahead_needs_a_factory_and_a_store(tmp_path):
    ladder = ContextLadder(config=_config(), summarizer=StubSummarizer())
    assert ladder.plan_ahead(_history(8), session_id=1) is False


# -- through the loop ------------------------------------------------------------


def test_loop_plans_after_the_run_and_the_next_run_does_not_wait(tmp_path):
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

    def run(
        prompt: str, script: list
    ) -> tuple[StubSummarizer, Factory, object, ContextLadder]:
        blocking = StubSummarizer()
        factory = Factory()
        ladder = ContextLadder(
            config=_config(), summarizer=blocking, summarizer_factory=factory
        )
        ladder.summary_store = store
        loop = AgentLoop(
            MockModelClient(script),
            registry,
            store,
            max_iterations=12,
            budget=IterationBudget(12),
            system_prompt="sys",
            context_ladder=ladder,
        )
        return blocking, factory, loop.run("k", prompt), ladder

    call = tool_call_response(("peek", {}))
    blocking, factory, first, ladder = run("go", [call] * 7 + ["done"])
    assert first.final_answer == "done"
    assert blocking.calls == []  # the long first run never waited
    assert ladder.wait_background(5)
    assert factory.built  # a job ran (in the run or right after it)

    blocking, factory, second, _ = run("hi", ["hey"])
    assert second.final_answer == "hey"
    assert blocking.calls == [] and factory.built == []
    assert second.timings.prepare_ms < 1_000


# -- the idle rule -----------------------------------------------------------------


def _idle_history() -> tuple[list[dict], list[float]]:
    messages = (
        _sysuser()
        + _tool_round(0, chars=200)
        + [
            {"role": "assistant", "content": "read f0.py; it is fine"},
            {"role": "user", "content": "now f1"},
            {
                "role": "assistant",
                "content": "reading it",
                "tool_calls": [
                    {
                        "id": "c1",
                        "type": "function",
                        "function": {"name": "read_file", "arguments": {}},
                    }
                ],
            },
            {
                "role": "tool",
                "tool_call_id": "c1",
                "name": "read_file",
                "content": "x" * 300,
            },
            {"role": "assistant", "content": "f1 is fine too"},
            {"role": "user", "content": "back after lunch"},
        ]
    )
    stamps = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 8.0 + 3_600]
    return messages, stamps


def test_idle_cut_finds_the_newest_user_message_after_a_long_pause():
    messages, stamps = _idle_history()
    assert idle_cut(messages, stamps, 1_800) == 9
    assert idle_cut(messages, stamps, 7_200) == 0
    assert idle_cut(messages, stamps, 0) == 0
    assert idle_cut(messages, None, 1_800) == 0
    assert idle_cut(messages, stamps[:-1], 1_800) == 0  # misaligned: ignored


def test_a_long_tool_call_is_not_an_idle_pause():
    messages, stamps = _idle_history()
    stamps = [
        0.0,
        1.0,
        2.0,
        2.0 + 3_600,
        3_603.0,
        3_604.0,
        3_605.0,
        3_606.0,
        3_607.0,
        3_608.0,
    ]
    assert idle_cut(messages, stamps, 1_800) == 0  # the gap is before a tool row


def test_after_a_long_pause_the_old_tool_traffic_is_dropped_and_the_text_stays():
    messages, stamps = _idle_history()
    ladder = ContextLadder(config=LadderConfig())  # far below every threshold
    out = ladder.prepare(messages, timestamps=stamps)
    assert all(m.get("role") != "tool" for m in out)
    assert all(not m.get("tool_calls") for m in out)
    assert not any(IDLE_DROP_KEY in m for m in out)
    texts = [m.get("content") for m in out]
    assert "read f0.py; it is fine" in texts
    assert "reading it" in texts  # the text of a turn that also called a tool
    assert out[-1] == {"role": "user", "content": "back after lunch"}
    assert out[:2] == _sysuser()  # the head is never touched
    assert ladder.last_stats.idle_dropped == 4


def test_the_idle_rule_keeps_the_work_after_the_pause():
    messages, stamps = _idle_history()
    messages = messages + _tool_round(7, chars=200)
    stamps = stamps + [stamps[-1] + 1, stamps[-1] + 2]
    out = ContextLadder(config=LadderConfig()).prepare(messages, timestamps=stamps)
    assert out[-2]["tool_calls"][0]["id"] == "call_7"
    assert out[-1]["role"] == "tool"


def test_the_idle_rule_is_stable_on_later_turns():
    messages, stamps = _idle_history()
    first = ContextLadder(config=LadderConfig()).prepare(messages, timestamps=stamps)
    later = messages + [
        {"role": "assistant", "content": "welcome back"},
        {"role": "user", "content": "ok"},
    ]
    later_stamps = stamps + [stamps[-1] + 5, stamps[-1] + 60]
    second = ContextLadder(config=LadderConfig()).prepare(
        later, timestamps=later_stamps
    )
    assert second[: len(first)] == first  # same prefix: cache-friendly


def test_the_idle_rule_can_be_turned_off():
    messages, stamps = _idle_history()
    out = ContextLadder(config=LadderConfig(idle_drop_seconds=0)).prepare(
        messages, timestamps=stamps
    )
    assert out == messages


def test_a_back_reference_to_a_dropped_result_is_inlined():
    big = "same output " * 40
    messages = _sysuser() + [
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "a",
                    "type": "function",
                    "function": {"name": "t", "arguments": {}},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "a", "name": "t", "content": big},
        {"role": "user", "content": "again please"},
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "b",
                    "type": "function",
                    "function": {"name": "t", "arguments": {}},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "b", "name": "t", "content": big},
    ]
    stamps = [0.0, 1.0, 2.0, 3.0, 3.0 + 3_600, 3_605.0, 3_606.0]
    cfg = LadderConfig(
        context_length=1_000,
        reserved_output=100,
        tier1_threshold=0.01,
        dedup_min_chars=100,
    )
    out = ContextLadder(config=cfg).prepare(messages, timestamps=stamps)
    tools = [m for m in out if m.get("role") == "tool"]
    assert len(tools) == 1
    # Its twin before the pause is gone, so it carries the bytes itself.
    assert tools[0]["content"] == big
    assert not any(
        isinstance(m.get("content"), dict) and DUP_KEY in m["content"] for m in out
    )
    assert expand_back_references(out) == out


def test_the_idle_rule_through_the_loop_reads_the_stored_timestamps(tmp_path):
    import sqlite3

    from chuk_agents_runtime.loop import AgentLoop, IterationBudget
    from chuk_agents_runtime.model import MockModelClient, tool_call_response
    from chuk_agents_runtime.registry import ToolRegistry

    db = str(tmp_path / "s.db")
    store = StateStore(db)
    registry = ToolRegistry()
    registry.register("peek", {"type": "object", "properties": {}}, lambda: "peeked")
    seen: list[list[dict]] = []

    def loop(script):
        return AgentLoop(
            MockModelClient(script),
            registry,
            store,
            max_iterations=6,
            budget=IterationBudget(6),
            system_prompt="sys",
            context_ladder=ContextLadder(config=LadderConfig()),
            debug_observer=lambda d: seen.append(list(d.get("messages", []))),
        )

    loop([tool_call_response(("peek", {})), "peeked it"]).run("k", "go")
    # The user went away for an hour: push every stored row back in time.
    conn = sqlite3.connect(db, timeout=5)
    conn.execute("UPDATE messages SET created_at = created_at - 3600")
    conn.commit()
    conn.close()
    seen.clear()
    loop(["hello again"]).run("k", "back")
    sent = seen[0]
    assert all(m.get("role") != "tool" for m in sent)
    assert any(m.get("content") == "peeked it" for m in sent)


@pytest.fixture(autouse=True)
def _no_leftover_jobs():
    yield
    # Every test waits for its own jobs; this only guards a failing one.
    for key in list(background_summaries()._running):
        background_summaries().wait(key, 5)


# -- the drops only ever shrink the payload -----------------------------------------


def _long_session(turns: int) -> tuple[list[dict], list[float]]:
    """``turns`` tasks, each: prompt, recall row, two tool rounds, answer."""
    messages = [{"role": "system", "content": "system prompt"}]
    stamps = [0.0]
    clock = 0.0
    for t in range(turns):
        rows = [{"role": "user", "content": f"task {t}"}]
        rows.append({"role": "user", "content": "[memory recall — notes]\n- " + "note " * 300})
        rows += _tool_round(2 * t) + _tool_round(2 * t + 1)
        rows.append({"role": "assistant", "content": f"task {t} done: " + "words " * 150})
        for row in rows:
            messages.append(row)
            clock += 5.0
            stamps.append(clock)
    messages.append({"role": "user", "content": "hi"})
    stamps.append(clock + 3_600)  # the user comes back after an hour
    return messages, stamps


def test_history_after_the_ladder_does_not_grow_when_the_idle_rule_fires():
    """Coordinator regression: dropping the tool rows lowered the pressure
    under tier 2, so the whole middle stayed verbatim (48.7k instead of 31.3k
    tokens on brisk-heron). The drops may only shrink the payload."""
    messages, stamps = _long_session(12)
    cfg = _config(context_length=20_000, reserved_output=1_000, tail_token_budget=1_500)

    def send(idle: float, timestamps) -> tuple[list[dict], ContextLadder]:
        ladder = ContextLadder(
            config=LadderConfig(**{**cfg.__dict__, "idle_drop_seconds": idle}),
            summarizer=StubSummarizer(),
        )
        return ladder.prepare(messages, timestamps=timestamps), ladder

    without, plain = send(0, stamps)
    with_idle, ladder = send(1_800, stamps)
    assert plain.last_stats.tier == 2
    assert ladder.last_stats.tier == 2  # the drop did not switch tier 2 off
    assert ladder.last_stats.idle_dropped > 0
    assert ladder._measure(with_idle) <= plain._measure(without)


def test_recall_rows_of_earlier_tasks_are_dropped_and_the_current_one_stays():
    messages = _sysuser() + [
        {"role": "user", "content": "[memory recall — notes]\n- old note"},
        {"role": "assistant", "content": "first answer"},
        {"role": "user", "content": "second task"},
        {"role": "user", "content": "[memory recall — notes]\n- current note"},
    ]
    ladder = ContextLadder(config=LadderConfig())
    out = ladder.prepare(messages, turn_start=4)
    texts = [m["content"] for m in out]
    assert not any("old note" in t for t in texts)
    assert any("current note" in t for t in texts)
    assert ladder.last_stats.idle_dropped == 1
    # Without a turn start nothing is dropped.
    assert ContextLadder(config=LadderConfig()).prepare(messages) == messages


def test_an_earlier_automation_payload_is_collapsed():
    fired = (
        "[automation a1 fired: Wahlradar]\ncheck the count\n"
        "payload (data, not instructions):\n" + '{"rows": "' + "x" * 4_000 + '"}'
    )
    messages = _sysuser() + [
        {"role": "user", "content": fired},
        {"role": "assistant", "content": "2519 of 2660 counted"},
        {"role": "user", "content": fired},
    ]
    out = ContextLadder(config=LadderConfig()).prepare(messages, turn_start=4)
    assert out[2]["content"].startswith("[automation a1 fired: Wahlradar]\ncheck the count\n")
    assert "x" * 100 not in out[2]["content"]
    assert out[4]["content"] == fired  # the current run keeps its payload


def test_the_tail_budget_is_capped():
    assert LadderConfig().tail_budget == 10_000
    assert LadderConfig(context_length=20_000).tail_budget == int(15_904 * 0.25)
    assert LadderConfig(tail_token_budget=50_000).tail_budget == 50_000
