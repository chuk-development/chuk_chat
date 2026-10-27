"""The short history window of a fired automation run (beads chuk_chat-kq1g,
chuk_chat-n69s).

A fired run gets the system prompt, the cached summary, the newest
conversation turns within a token budget and its own turn. Earlier automation
runs and all old tool traffic stay out. A chat turn of the user is not
affected."""

from __future__ import annotations

from chuk_agents_runtime.automations import fired_prompt
from chuk_agents_runtime.context import (
    SUMMARY_PREFIX,
    ContextLadder,
    LadderConfig,
    _prefix_digest,
    automation_runs_note,
    estimate_messages_tokens,
)

SYSTEM = {"role": "system", "content": "You are Agents. " + "rules " * 400}


def _fired(n: int) -> str:
    return fired_prompt("22d2ae8b", "Fastmail check", f"check inbox #{n}")


def _clock(n: int) -> dict:
    return {"role": "user", "content": f"[clock] Now: run {n}"}


def _recall() -> dict:
    return {"role": "user", "content": "[memory recall — notes]\n- inbox was empty"}


def _automation_run(n: int) -> list[dict]:
    call_id = f"call-{n}"
    return [
        {"role": "user", "content": _fired(n)},
        _clock(n),
        {
            "role": "assistant",
            "tool_calls": [
                {"id": call_id, "type": "function", "function": {"name": "mail_list", "arguments": "{}"}}
            ],
        },
        {"role": "tool", "tool_call_id": call_id, "name": "mail_list", "content": "x" * 800},
        _recall(),
        {"role": "assistant", "content": "Nothing relevant, inbox empty."},
    ]


def _history(runs: int = 40) -> list[dict]:
    rows = [
        SYSTEM,
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "Hi! What can I help you with?"},
        {"role": "user", "content": "Go through my mail. Never send a mail. " + "detail " * 50},
        {"role": "assistant", "content": "Understood, I will only read."},
    ]
    for n in range(runs):
        rows.extend(_automation_run(n))
    return rows


def _with_new_fired_turn(rows: list[dict]) -> tuple[list[dict], int]:
    out = rows + [{"role": "user", "content": _fired(999)}, _clock(999)]
    return out, len(rows)


def test_fired_run_gets_a_short_window_without_earlier_runs():
    rows, turn_start = _with_new_fired_turn(_history())
    ladder = ContextLadder(config=LadderConfig())
    out = ladder.prepare(rows, turn_start=turn_start)

    stats = ladder.last_stats
    assert stats.automation_window
    assert stats.automation_runs_omitted == 40
    assert out[0] == SYSTEM
    # The current turn is sent verbatim and last.
    assert out[-2:] == rows[turn_start:]
    # No earlier fired prompt, no earlier answer of a run, no tool traffic,
    # no injected rows of earlier turns.
    earlier = out[1:-2]
    assert not any(str(m.get("content", "")).startswith("[automation ") for m in earlier)
    assert not any(m.get("role") == "tool" or m.get("tool_calls") for m in earlier)
    assert not any("inbox empty" in str(m.get("content")) for m in earlier)
    assert not any(str(m.get("content", "")).startswith(("[clock]", "[memory recall")) for m in earlier)
    # The user's own instructions stay.
    assert any("Never send a mail" in str(m.get("content")) for m in earlier)
    assert {"role": "user", "content": automation_runs_note(40)} in out
    # History (everything but system and the current turn) fits the budget.
    history = [m for m in earlier]
    assert estimate_messages_tokens(history) <= LadderConfig().automation_history_tokens + 100


def test_fired_run_window_does_not_grow_with_more_runs():
    small = ContextLadder(config=LadderConfig())
    big = ContextLadder(config=LadderConfig())
    rows_small, start_small = _with_new_fired_turn(_history(5))
    rows_big, start_big = _with_new_fired_turn(_history(200))
    out_small = small.prepare(rows_small, turn_start=start_small)
    out_big = big.prepare(rows_big, turn_start=start_big)
    assert len(out_small) == len(out_big)
    # Only the note's run count differs.
    assert abs(estimate_messages_tokens(out_big) - estimate_messages_tokens(out_small)) < 5


def test_interactive_turn_is_unchanged():
    rows = _history(40) + [{"role": "user", "content": "what did you find this week?"}]
    turn_start = len(rows) - 1
    auto = ContextLadder(config=LadderConfig())
    forced_off = ContextLadder(config=LadderConfig(), automation_window=False)
    assert auto.prepare(rows, turn_start=turn_start) == forced_off.prepare(
        rows, turn_start=turn_start
    )
    assert not auto.last_stats.automation_window


def test_forced_off_sends_the_full_ladder_output_for_a_fired_run():
    rows, turn_start = _with_new_fired_turn(_history(40))
    ladder = ContextLadder(config=LadderConfig(), automation_window=False)
    out = ladder.prepare(rows, turn_start=turn_start)
    assert not ladder.last_stats.automation_window
    assert sum(1 for m in out if str(m.get("content", "")).startswith("[automation ")) == 41


def test_turn_start_is_found_without_the_loop():
    rows, _ = _with_new_fired_turn(_history(10))
    ladder = ContextLadder(config=LadderConfig())
    out = ladder.prepare(rows)
    assert ladder.last_stats.automation_window
    assert out[-2]["content"] == _fired(999)


def test_window_keeps_the_newest_turns_within_budget_and_turn_cap():
    rows = [SYSTEM]
    for n in range(10):
        rows.append({"role": "user", "content": f"question {n} " + "w" * 2000})
        rows.append({"role": "assistant", "content": f"answer {n}"})
    rows, turn_start = _with_new_fired_turn(rows)
    config = LadderConfig(automation_history_tokens=1_500, automation_history_turns=4)
    ladder = ContextLadder(config=config)
    out = ladder.prepare(rows, turn_start=turn_start)
    texts = [str(m.get("content")) for m in out]
    # ~510 tokens per turn: two fit 1500 tokens, the newest two.
    assert any(t.startswith("question 9") for t in texts)
    assert any(t.startswith("question 8") for t in texts)
    assert not any(t.startswith("question 7") for t in texts)
    # Chronological order.
    assert texts.index(next(t for t in texts if t.startswith("question 8"))) < texts.index(
        next(t for t in texts if t.startswith("question 9"))
    )
    roomy = ContextLadder(config=LadderConfig(automation_history_tokens=100_000, automation_history_turns=3))
    out = roomy.prepare(rows, turn_start=turn_start)
    assert sum(1 for m in out if str(m.get("content")).startswith("question ")) == 3


def test_current_turn_tool_rounds_stay_intact():
    rows, turn_start = _with_new_fired_turn(_history(10))
    rows = rows + [
        {
            "role": "assistant",
            "tool_calls": [
                {"id": "now", "type": "function", "function": {"name": "mail_list", "arguments": "{}"}}
            ],
        },
        {"role": "tool", "tool_call_id": "now", "name": "mail_list", "content": "y" * 300},
    ]
    ladder = ContextLadder(config=LadderConfig())
    out = ladder.prepare(rows, turn_start=turn_start)
    assert out[-4:] == rows[turn_start:]


def test_old_big_tool_results_of_the_current_run_are_truncated():
    rows, turn_start = _with_new_fired_turn(_history(5))
    for n in range(6):
        rows.extend(
            [
                {
                    "role": "assistant",
                    "tool_calls": [
                        {"id": f"r{n}", "type": "function", "function": {"name": "web_fetch", "arguments": "{}"}}
                    ],
                },
                {"role": "tool", "tool_call_id": f"r{n}", "name": "web_fetch", "content": str(n) * 8_000},
            ]
        )
    cfg = LadderConfig()
    ladder = ContextLadder(config=cfg)
    out = ladder.prepare(rows, turn_start=turn_start)

    tool_rows = [m for m in out if m.get("role") == "tool" and m.get("name") == "web_fetch"]
    assert len(tool_rows) == 6
    # The oldest result is cut to the tier-1 cap; the newest stays whole.
    assert len(tool_rows[0]["content"]) < 8_000
    assert tool_rows[-1]["content"] == "5" * 8_000
    assert estimate_messages_tokens(out) < estimate_messages_tokens(rows[turn_start:])


class _Store:
    def __init__(self, row: dict | None) -> None:
        self.row = row
        self.saved: list[dict] = []

    def load_context_summary(self, session_id: int) -> dict | None:
        return self.row

    def save_context_summary(self, session_id: int, **row) -> None:
        self.saved.append(row)


class _NoSummarizer:
    def summarize(self, transcript: str, previous: str | None) -> str:
        raise AssertionError("a fired run must not call the aux model")


def test_cached_summary_is_used_and_no_aux_call_is_made():
    history = _history(40)
    rows, turn_start = _with_new_fired_turn(history)
    upto = 20
    store = _Store(
        {
            "summary": "Goal: read mail, never send.",
            "summarized_upto": upto,
            "prefix_digest": _prefix_digest(rows, 2, upto),
        }
    )
    ladder = ContextLadder(
        config=LadderConfig(context_length=8_000), summarizer=_NoSummarizer(), summary_store=store
    )
    out = ladder.prepare(rows, session_id=7, turn_start=turn_start)
    assert ladder.last_stats.automation_window
    assert out[1]["content"] == SUMMARY_PREFIX + "Goal: read mail, never send."
    # Everything before the summarized point is in the summary, not verbatim.
    assert not any("Never send a mail" in str(m.get("content")) for m in out)
    assert store.saved == []


def test_stale_cached_summary_is_not_used():
    rows, turn_start = _with_new_fired_turn(_history(10))
    store = _Store({"summary": "old", "summarized_upto": 20, "prefix_digest": "nope"})
    ladder = ContextLadder(config=LadderConfig(), summary_store=store)
    out = ladder.prepare(rows, session_id=7, turn_start=turn_start)
    assert not any(str(m.get("content")).startswith(SUMMARY_PREFIX) for m in out)


def test_a_chat_prompt_that_only_looks_alike_is_not_a_fired_run():
    rows = _history(3) + [{"role": "user", "content": "[automation ideas] what could I automate?"}]
    ladder = ContextLadder(config=LadderConfig())
    ladder.prepare(rows, turn_start=len(rows) - 1)
    assert not ladder.last_stats.automation_window


def test_answer_whose_prompt_is_in_the_summary_stays_out():
    rows, turn_start = _with_new_fired_turn(_history(10))
    # Summarize up to the middle of a run: its prompt is in the summary, its
    # answer is not.
    upto = next(i for i in range(10, turn_start) if rows[i].get("role") == "tool") + 1
    store = _Store(
        {"summary": "Goal: mail.", "summarized_upto": upto, "prefix_digest": _prefix_digest(rows, 2, upto)}
    )
    ladder = ContextLadder(config=LadderConfig(), summary_store=store)
    out = ladder.prepare(rows, session_id=7, turn_start=turn_start)
    assert not any("inbox empty" in str(m.get("content")) for m in out)
