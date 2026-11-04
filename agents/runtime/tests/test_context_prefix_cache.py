"""The context ladder keeps the provider prompt cache hitting.

Providers cache the request prefix byte by byte: the first changed byte makes
the rest a miss. So within a task each round's payload must extend the one
before it; earlier rows never change, except in rare, large steps.

- bead chuk_chat-8i9z: tier-1 truncation used to change a row in place on the
  round the tail moved past it. Now a frontier moves in steps.
- bead chuk_chat-74ey: the old-task rule used to drop the previous task's tool
  traffic at every new task. Now it drops in blocks past a threshold.
- A compaction that folds a skill body away leaves a reload note.

No real model is called: the aux model is a mock.
"""

from __future__ import annotations

import json

from chuk_agents_runtime.context import (
    SUMMARY_PREFIX,
    AuxSummarizer,
    ContextLadder,
    LadderConfig,
    old_task_cut,
    skill_reload_note,
)
from chuk_agents_runtime.model import ModelResponse
from chuk_agents_runtime.skills import SKILL_BODY_PREFIX, Skill, SkillLibrary


def _dump(rows: list[dict]) -> list[str]:
    return [json.dumps(row, sort_keys=True, ensure_ascii=False) for row in rows]


def _is_extension(before: list[dict], after: list[dict]) -> bool:
    """``after`` starts with ``before``, byte for byte."""
    a, b = _dump(before), _dump(after)
    return len(b) >= len(a) and b[: len(a)] == a


def _tool_round(index: int, chars: int, *, name: str = "read_file") -> list[dict]:
    return [
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": f"call_{index}",
                    "type": "function",
                    "function": {"name": name, "arguments": {"path": f"f{index}.py"}},
                }
            ],
        },
        {
            "role": "tool",
            "tool_call_id": f"call_{index}",
            "name": name,
            # Unique per round, so dedup does not hide the effect.
            "content": (f"r{index} " * (chars // 4 + 1))[:chars],
        },
    ]


# -- tier 1 (bead chuk_chat-8i9z) --------------------------------------------


def _tier1_config(**overrides) -> LadderConfig:
    base = dict(
        context_length=40_000,
        reserved_output=4_000,  # input budget 36k
        tier1_threshold=0.05,  # tier 1 is on from the first rounds
        max_tool_result_tokens=500,
        tail_token_budget=6_000,
        tier1_step_tokens=8_000,
        tier1_step_fraction=1.0,
        old_task_tools_drop_tokens=0,
    )
    base.update(overrides)
    return LadderConfig(**base)


def _task_steps(rounds: int, chars: int) -> list[list[dict]]:
    """The stored history at each model request of one task: after the
    prompt, and after every tool round."""
    messages = [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "build the thing"},
    ]
    steps = [list(messages)]
    for i in range(rounds):
        messages += _tool_round(i, chars)
        steps.append(list(messages))
    return steps


def test_tier1_rows_do_not_change_between_rounds_except_in_rare_steps():
    steps = _task_steps(rounds=30, chars=8_000)  # ~2k tokens per result
    ladder = ContextLadder(config=_tier1_config())
    payloads = [ladder.prepare(step, turn_start=1) for step in steps]

    breaks = [
        k for k in range(1, len(payloads)) if not _is_extension(payloads[k - 1], payloads[k])
    ]
    # The old rule broke the prefix on nearly every round once the tail was
    # full (about 27 times here). A step needs 8k tokens of savings, i.e.
    # about 5 results of ~1.5k savings each.
    assert 0 < len(breaks) <= 6, breaks
    # Between two steps there are several rounds of pure extension.
    assert all(b - a >= 3 for a, b in zip(breaks, breaks[1:])), breaks

    # Tier 1 still does its job: old results are cut, the newest stays whole.
    last = payloads[-1]
    results = [m for m in last if m.get("role") == "tool"]
    assert "dropped by the context ladder" in results[0]["content"]
    assert results[-1]["content"] == steps[-1][-1]["content"]


def test_rows_left_whole_save_less_than_one_step():
    """The cost of the step rule is bounded: the rows outside the tail that
    are not cut yet would save less than one step."""
    cfg = _tier1_config()
    steps = _task_steps(rounds=30, chars=8_000)
    ladder = ContextLadder(config=cfg)
    for step in steps[1:]:
        out = ladder.prepare(step, turn_start=1)
        whole_old = [
            m
            for m in out[:-8]  # well outside the 6k tail
            if m.get("role") == "tool" and "dropped by the context ladder" not in m["content"]
        ]
        assert len(whole_old) * 1_500 < cfg.tier1_step + 2 * 1_500


def test_a_new_round_never_changes_a_row_sent_in_the_same_step():
    """Byte-identical earlier rows: an exact check of each row between two
    consecutive rounds outside a step."""
    steps = _task_steps(rounds=12, chars=8_000)
    ladder = ContextLadder(config=_tier1_config(tier1_step_tokens=1_000_000))
    payloads = [ladder.prepare(step, turn_start=1) for step in steps]
    for before, after in zip(payloads, payloads[1:]):
        assert _dump(after)[: len(before)] == _dump(before)


def test_bloated_arguments_follow_the_same_frontier():
    messages = [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "write it"},
    ]
    payloads = []
    for i in range(12):
        messages = messages + [
            {
                "role": "assistant",
                "tool_calls": [
                    {
                        "id": f"w{i}",
                        "type": "function",
                        "function": {
                            "name": "write_file",
                            "arguments": {"content": chr(ord("a") + i) * 12_000},
                        },
                    }
                ],
            },
            {"role": "tool", "tool_call_id": f"w{i}", "name": "write_file", "content": "ok"},
        ]
        ladder = ContextLadder(config=_tier1_config(max_tool_arg_chars=200))
        payloads.append(ladder.prepare(messages, turn_start=1))
    breaks = [
        k for k in range(1, len(payloads)) if not _is_extension(payloads[k - 1], payloads[k])
    ]
    assert len(breaks) <= 3, breaks
    first_args = payloads[-1][2]["tool_calls"][0]["function"]["arguments"]["content"]
    assert len(first_args) < 1_000


# -- old-task drop (bead chuk_chat-74ey) ------------------------------------


def _tasks(count: int, rounds: int, chars: int) -> list[tuple[list[dict], int]]:
    """The history at the start of each task (its prompt is the last row)
    and the prompt's index, plus the history after its tool rounds."""
    messages = [{"role": "system", "content": "system prompt"}]
    states: list[tuple[list[dict], int]] = []
    for t in range(count):
        turn_start = len(messages)
        messages = messages + [{"role": "user", "content": f"task {t}"}]
        for r in range(rounds):
            messages = messages + _tool_round(t * 100 + r, chars)
            states.append((list(messages), turn_start))
        messages = messages + [{"role": "assistant", "content": f"answer {t}"}]
    return states


def test_old_task_tools_are_dropped_in_blocks_not_at_every_task():
    cfg = LadderConfig(old_task_tools_drop_tokens=10_000, head_messages=1)
    # 3 rounds of ~1k tokens each: ~3k tool tokens per task.
    states = _tasks(count=12, rounds=3, chars=4_000)
    payloads = [ContextLadder(config=cfg).prepare(m, turn_start=ts) for m, ts in states]

    breaks = [
        k for k in range(1, len(payloads)) if not _is_extension(payloads[k - 1], payloads[k])
    ]
    # A drop needs ~10k tokens, i.e. about 4 tasks of old traffic. The old
    # rule (4k floor) dropped at every task from the second one on.
    assert 1 <= len(breaks) <= 3, breaks
    # Within a task, never a break.
    task_of = [ts for _, ts in states]
    for k in breaks:
        assert task_of[k] != task_of[k - 1]


def test_old_task_cut_moves_only_past_the_threshold():
    states = _tasks(count=6, rounds=3, chars=4_000)
    messages, turn_start = states[-1]
    # Below the threshold: no cut at all.
    assert old_task_cut(messages, 1, turn_start, threshold=1_000_000) == 1
    # A threshold of about two tasks: the cut lands on a task prompt, and the
    # tool traffic kept after it is under the threshold.
    cut = old_task_cut(messages, 1, turn_start, threshold=6_000)
    assert 1 < cut <= turn_start
    assert messages[cut]["role"] == "user"
    # Same rows, same cut: a function of the stored rows only.
    assert old_task_cut(list(messages), 1, turn_start, threshold=6_000) == cut


def test_old_tool_traffic_carried_stays_bounded():
    cfg = LadderConfig(old_task_tools_drop_tokens=10_000, head_messages=1)
    for messages, turn_start in _tasks(count=15, rounds=3, chars=4_000):
        out = ContextLadder(config=cfg).prepare(messages, turn_start=turn_start)
        prompt = {"role": "user", "content": messages[turn_start]["content"]}
        old = out[: out.index(prompt)]
        old_tool_chars = sum(len(m["content"]) for m in old if m.get("role") == "tool")
        # Under the threshold plus one task of traffic (~3k tokens).
        assert old_tool_chars // 4 < 10_000 + 3_500


# -- skill bodies (Hermes finding) ------------------------------------------


class _Aux:
    def __init__(self) -> None:
        self.prompts: list[str] = []

    def complete(self, messages: list[dict]) -> ModelResponse:
        self.prompts.append(messages[-1]["content"])
        return ModelResponse(text="GOAL: ship\nCOMPLETED: loaded deploy skill, ran it")


def _skill_rows(name: str) -> list[dict]:
    return [
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "s1",
                    "type": "function",
                    "function": {"name": "skill", "arguments": {"name": name}},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "s1", "name": "skill", "content": {"ok": True}},
        {"role": "user", "content": f"{SKILL_BODY_PREFIX}{name}\n\nRun ./deploy.sh then check."},
    ]


def test_a_summary_that_folds_a_skill_body_away_leaves_a_reload_note():
    messages = [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "deploy it"},
    ]
    messages += _skill_rows("deploy")
    for i in range(12):
        messages += _tool_round(i, 2_000)
    dropped: list[str] = []
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            tier2_threshold=0.10,
            tail_token_budget=600,
            max_tool_result_tokens=10_000_000,
            dedup_min_chars=10_000_000,
        ),
        summarizer=AuxSummarizer(_Aux()),
        on_skill_dropped=dropped.append,
    )
    out = ladder.prepare(messages, turn_start=1)

    summary = next(m for m in out if str(m.get("content", "")).startswith(SUMMARY_PREFIX))
    assert skill_reload_note("deploy") in summary["content"]
    assert not any(str(m.get("content", "")).startswith(SKILL_BODY_PREFIX) for m in out)
    assert dropped == ["deploy"]

    # The next round reuses the summary; the note is part of the same bytes.
    later = messages + _tool_round(99, 200)
    again = ladder.prepare(later, turn_start=1)
    assert _dump(again)[: out.index(summary) + 1] == _dump(out)[: out.index(summary) + 1]


def test_a_skill_body_that_stays_is_not_reported():
    messages = [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "deploy it"},
    ]
    messages += _skill_rows("deploy")
    dropped: list[str] = []
    out = ContextLadder(on_skill_dropped=dropped.append).prepare(messages, turn_start=1)
    assert out == messages
    assert dropped == []


def test_the_automation_window_notes_the_skills_it_leaves_out():
    messages = [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "deploy it"},
    ]
    messages += _skill_rows("deploy")
    messages += [{"role": "assistant", "content": "deployed"}]
    turn_start = len(messages)
    messages += [{"role": "user", "content": "[automation a1 fired: nightly]\ncheck it"}]
    dropped: list[str] = []
    out = ContextLadder(on_skill_dropped=dropped.append).prepare(
        messages, turn_start=turn_start
    )
    contents = [m.get("content") for m in out]
    assert skill_reload_note("deploy") in contents
    assert dropped == ["deploy"]


def test_a_forgotten_skill_is_sent_again():
    library = SkillLibrary()
    library.skills["deploy"] = Skill(name="deploy", description="d", body="Run ./deploy.sh")
    assert library.activate("deploy")["status"] == "active"
    assert len(library.pending_context()) == 1
    assert library.activate("deploy")["status"] == "already_active"
    library.forget("deploy")
    assert library.activate("deploy")["status"] == "active"
    body = library.pending_context()
    assert body and body[0]["content"].startswith(SKILL_BODY_PREFIX + "deploy")
