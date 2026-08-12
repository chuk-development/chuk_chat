"""Tests for the context / long-run cost ladder (§7.3).

Every guarantee the plan states is pinned here: the trigger fires on prompt
tokens only and not a token earlier, tier-1 dedup is losslessly referenceable, a
tool_call/tool_result pair is never split, the head is verbatim, the tail holds a
*token* budget, the anti-thrashing guard bites after two lean passes, tier 3
updates the summary instead of regenerating it, and no secret survives into the
summary.

No real model is ever called: the aux model is a mock.
"""

from __future__ import annotations

import json
from dataclasses import replace

import pytest

from cowork_agent.context import (
    DUP_KEY,
    SUMMARY_PREFIX,
    AuxSummarizer,
    ContextLadder,
    LadderConfig,
    estimate_messages_tokens,
    estimate_tokens,
    expand_back_references,
    prompt_tokens_from_usage,
    redact_secrets,
)
from cowork_agent.model import ModelResponse

# -- helpers --------------------------------------------------------------


class RecordingAux:
    """A mock aux model. Records every prompt and replies from a script."""

    def __init__(self, replies: list[str] | None = None) -> None:
        self.prompts: list[str] = []
        self._replies = list(replies or [])

    def complete(self, messages: list[dict]) -> ModelResponse:
        prompt = messages[-1]["content"]
        self.prompts.append(prompt)
        if self._replies:
            return ModelResponse(text=self._replies.pop(0))
        return ModelResponse(text=f"GOAL: ship\nCOMPLETED: pass {len(self.prompts)}")


class EchoAux:
    """A mock aux model that replies with the prompt it was given. Any secret in
    its answer proves the transcript reached it unredacted."""

    def complete(self, messages: list[dict]) -> ModelResponse:
        return ModelResponse(text=messages[-1]["content"])


def _sysuser() -> list[dict]:
    return [
        {"role": "system", "content": "system prompt"},
        {"role": "user", "content": "build the thing"},
    ]


def _tool_round(index: int, payload: str, *, name: str = "read_file") -> list[dict]:
    """One assistant tool_call plus its matching tool result."""
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
        {"role": "tool", "tool_call_id": f"call_{index}", "name": name, "content": payload},
    ]


def _long_history(rounds: int, payload_chars: int = 4_000, *, unique: bool = True) -> list[dict]:
    messages = _sysuser()
    for i in range(rounds):
        body = (f"line {i} " if unique else "line ") * (payload_chars // 8)
        messages += _tool_round(i, body)
    return messages


# -- token accounting -----------------------------------------------------


def test_estimate_is_deterministic_and_proportional():
    assert estimate_tokens("") == 0
    assert estimate_tokens("abcd") == 1
    assert estimate_tokens("a" * 400) == 100
    assert estimate_tokens("x" * 40) == estimate_tokens("y" * 40)


def test_usage_reads_prompt_tokens_only():
    assert prompt_tokens_from_usage({"prompt_tokens": 120}) == 120
    assert prompt_tokens_from_usage({"input_tokens": "77"}) == 77
    # Completion / reasoning / total must never be mistaken for input pressure.
    assert prompt_tokens_from_usage({"completion_tokens": 900}) is None
    assert prompt_tokens_from_usage({"reasoning_tokens": 50_000}) is None
    assert prompt_tokens_from_usage({"total_tokens": 9_000}) is None
    assert prompt_tokens_from_usage(None) is None


# -- the trigger ----------------------------------------------------------


def _threshold_ladder() -> ContextLadder:
    # effective budget = 1000 - 200 = 800; tier 1 fires at 30% = 240 tokens.
    return ContextLadder(
        config=LadderConfig(
            context_length=1_000,
            reserved_output=200,
            tier1_threshold=0.30,
            dedup_min_chars=10,
            max_tool_result_tokens=10,
            tail_token_budget=0,
        )
    )


# Message framing (role, name, the assistant tool_call turn) costs ~58 tokens on
# top of the payload, so these two sizes straddle the 240-token trigger exactly.
_UNDER_THRESHOLD = "x" * 700   # -> 233 estimated tokens
_OVER_THRESHOLD = "x" * 800    # -> 258 estimated tokens


def test_trigger_does_not_fire_below_the_threshold():
    ladder = _threshold_ladder()
    # Just under 30% of the 800-token effective budget.
    messages = _sysuser() + _tool_round(0, _UNDER_THRESHOLD)
    assert estimate_messages_tokens(messages) < 240
    out = ladder.compress(messages)
    assert out is messages
    assert ladder.last_stats.skipped_reason == "below_threshold"
    assert ladder.last_stats.tier == 0


def test_trigger_fires_at_the_threshold():
    ladder = _threshold_ladder()
    messages = _sysuser() + _tool_round(0, _OVER_THRESHOLD)
    assert estimate_messages_tokens(messages) >= 240
    out = ladder.compress(messages)
    assert ladder.last_stats.skipped_reason is None
    assert ladder.last_stats.tier == 1
    assert ladder.last_stats.tokens_after < ladder.last_stats.tokens_before
    assert out is not messages


def test_reasoning_tokens_do_not_trigger():
    """A thinking model can burn 50k reasoning tokens on one turn. That must not
    move the input pressure by a single token."""
    ladder = _threshold_ladder()
    messages = _sysuser() + _tool_round(0, _UNDER_THRESHOLD)  # below the threshold

    ladder.prepare(messages)
    assert ladder.last_stats.skipped_reason == "below_threshold"

    ladder.record_usage(
        {"completion_tokens": 60_000, "reasoning_tokens": 50_000, "total_tokens": 60_239}
    )
    assert ladder.calibration == 1.0  # no prompt_tokens -> no recalibration
    ladder.prepare(messages)
    assert ladder.last_stats.skipped_reason == "below_threshold"

    # Real prompt_tokens, on the other hand, do move it.
    ladder.record_usage({"prompt_tokens": ladder.last_stats.tokens_before * 4})
    ladder.prepare(messages)
    assert ladder.last_stats.skipped_reason is None


def test_tool_schema_tokens_count_toward_pressure():
    messages = _sysuser() + _tool_round(0, _UNDER_THRESHOLD)
    base = LadderConfig(
        context_length=1_000, reserved_output=200, dedup_min_chars=10,
        max_tool_result_tokens=10, tail_token_budget=0,
    )
    assert ContextLadder(config=base).compress(messages) is messages
    with_schemas = ContextLadder(config=replace(base, tool_schema_tokens=100))
    with_schemas.compress(messages)
    assert with_schemas.last_stats.skipped_reason is None


def test_disabled_ladder_is_a_pass_through():
    ladder = ContextLadder(config=LadderConfig(context_length=1_000, reserved_output=200, enabled=False))
    messages = _long_history(6)
    assert ladder.compress(messages) is messages
    assert ladder.last_stats.skipped_reason == "disabled"


# -- tier 1: dedup is lossless -------------------------------------------


def _dedup_ladder() -> ContextLadder:
    return ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            dedup_min_chars=100,
            # No truncation and no tail exemption, so dedup is the only effect.
            max_tool_result_tokens=10_000_000,
            max_tool_arg_chars=10_000_000,
            tail_token_budget=0,
        )
    )


def test_dedup_replaces_repeats_and_is_losslessly_referenceable():
    payload = "same bytes " * 200
    messages = _sysuser() + _tool_round(0, payload) + _tool_round(1, payload) + _tool_round(2, payload)
    ladder = _dedup_ladder()
    out = ladder.compress(messages)

    first_result = next(i for i, m in enumerate(out) if m.get("role") == "tool")
    markers = [m for m in out if isinstance(m.get("content"), dict) and DUP_KEY in m["content"]]
    assert len(markers) == 2  # the first copy stays, the repeats become refs
    assert all(m["content"][DUP_KEY] == first_result for m in markers)
    assert ladder.last_stats.tokens_after < ladder.last_stats.tokens_before

    # Lossless: the omitted bytes are one hop away, and expanding restores the
    # original list exactly.
    assert expand_back_references(out) == messages


def test_dedup_leaves_distinct_results_alone():
    ladder = _dedup_ladder()
    messages = _sysuser() + _tool_round(0, "a" * 500) + _tool_round(1, "b" * 500)
    out = ladder.compress(messages)
    assert not [m for m in out if isinstance(m.get("content"), dict) and DUP_KEY in m["content"]]


def test_dedup_survives_a_summarization_pass():
    """A back-reference must never dangle after the middle is summarized away."""
    payload = "identical payload " * 300
    messages = _sysuser()
    for i in range(6):
        messages += _tool_round(i, payload)
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=2_000,
            reserved_output=500,
            tier1_threshold=0.10,
            tier2_threshold=0.10,
            dedup_min_chars=100,
            max_tool_result_tokens=10_000_000,
            tail_token_budget=400,
        ),
        summarizer=AuxSummarizer(RecordingAux()),
    )
    out = ladder.compress(messages)
    for message in out:
        content = message.get("content")
        if isinstance(content, dict) and DUP_KEY in content:
            target = out[content[DUP_KEY]]
            assert isinstance(target.get("content"), str)  # resolvable, not a marker
    # Everything still resolves to a real payload.
    for message in expand_back_references(out):
        content = message.get("content")
        assert not (isinstance(content, dict) and DUP_KEY in content)


# -- tier 1: truncation ---------------------------------------------------


def test_oversized_tool_output_is_truncated_outside_the_tail():
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            max_tool_result_tokens=50,
            # Big enough for the newest unit, so the tail exemption applies.
            tail_token_budget=2_500,
            dedup_min_chars=10_000_000,  # dedup off
        )
    )
    messages = _sysuser() + _tool_round(0, "old " * 2_000) + _tool_round(1, "new " * 2_000)
    out = ladder.compress(messages)
    old_result, new_result = [m for m in out if m.get("role") == "tool"]
    assert "dropped by the context ladder" in old_result["content"]
    assert new_result["content"] == messages[-1]["content"]  # the tail is untouched


def test_bloated_tool_call_arguments_are_trimmed():
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            max_tool_arg_chars=100,
            tail_token_budget=100,
            dedup_min_chars=10_000_000,
        )
    )
    messages = _sysuser() + [
        {
            "role": "assistant",
            "tool_calls": [
                {
                    "id": "call_0",
                    "type": "function",
                    "function": {"name": "write_file", "arguments": {"content": "z" * 8_000}},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_0", "name": "write_file", "content": "ok"},
        {"role": "user", "content": "next"},
    ]
    out = ladder.compress(messages)
    trimmed = out[2]["tool_calls"][0]["function"]["arguments"]["content"]
    assert len(trimmed) < 400
    assert "dropped by the context ladder" in trimmed
    # The original stored message is untouched — the store stays authoritative.
    assert len(messages[2]["tool_calls"][0]["function"]["arguments"]["content"]) == 8_000


# -- shape: head verbatim, tail by token budget, pairs intact -------------


def _shape_ladder(summarizer=None, tail_budget: int = 600) -> ContextLadder:
    return ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            tier2_threshold=0.10,
            head_messages=2,
            tail_token_budget=tail_budget,
            max_tool_result_tokens=10_000_000,
            dedup_min_chars=10_000_000,
        ),
        summarizer=summarizer,
    )


def test_head_stays_verbatim():
    messages = _long_history(10)
    ladder = _shape_ladder(AuxSummarizer(RecordingAux()))
    out = ladder.compress(messages)
    assert out[0] == messages[0]
    assert out[1] == messages[1]
    assert out[2]["content"].startswith(SUMMARY_PREFIX)


def test_tail_holds_its_token_budget():
    """The tail is kept by TOKEN budget, not message count: with 12 rounds of
    ~1000-token results, a 3500-token tail keeps 3 rounds, not "the last N
    messages"."""
    messages = _long_history(12)
    ladder = _shape_ladder(AuxSummarizer(RecordingAux()), tail_budget=3_500)
    out = ladder.compress(messages)
    summary_at = next(
        i for i, m in enumerate(out) if str(m.get("content", "")).startswith(SUMMARY_PREFIX)
    )
    tail = out[summary_at + 1 :]
    assert tail  # a tail exists
    assert estimate_messages_tokens(tail) <= 3_500
    # ...and it really is the END of the conversation, verbatim.
    assert tail == messages[len(messages) - len(tail) :]
    # A tighter budget keeps strictly less, and a wider one strictly more.
    def _tail_len(budget: int) -> int:
        led = _shape_ladder(AuxSummarizer(RecordingAux()), tail_budget=budget)
        result = led.compress(messages)
        at = next(
            i for i, m in enumerate(result)
            if str(m.get("content", "")).startswith(SUMMARY_PREFIX)
        )
        return len(result) - at - 1

    assert _tail_len(1_500) < _tail_len(3_500) < _tail_len(7_000)


def test_oversized_newest_unit_is_truncated_rather_than_blowing_the_budget():
    """If not even the newest unit fits the tail budget it is still kept — the
    model needs the result it just received — but it loses its truncation
    exemption instead of blowing the budget."""
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000, reserved_output=1_000, tier1_threshold=0.10,
            max_tool_result_tokens=50, tail_token_budget=100,
            dedup_min_chars=10_000_000,
        )
    )
    messages = _sysuser() + _tool_round(0, "huge " * 4_000)
    out = ladder.compress(messages)
    assert "dropped by the context ladder" in out[-1]["content"]
    assert estimate_messages_tokens(out[-2:]) < 200


def test_tool_call_and_result_are_never_split():
    for tail_budget in range(50, 1_500, 37):
        messages = _long_history(12)
        ladder = _shape_ladder(AuxSummarizer(RecordingAux()), tail_budget=tail_budget)
        out = ladder.compress(messages)
        _assert_pairs_intact(out)


def test_pairs_intact_when_the_head_boundary_lands_mid_pair():
    # head_messages=3 would cut between the assistant tool_call and its result.
    messages = _long_history(8)
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000, reserved_output=1_000, tier1_threshold=0.10,
            tier2_threshold=0.10, head_messages=3, tail_token_budget=400,
            max_tool_result_tokens=10_000_000, dedup_min_chars=10_000_000,
        ),
        summarizer=AuxSummarizer(RecordingAux()),
    )
    out = ladder.compress(messages)
    _assert_pairs_intact(out)
    assert out[2] == messages[2] and out[3] == messages[3]  # the pair came along


def _assert_pairs_intact(messages: list[dict]) -> None:
    """Every tool result is preceded by its assistant tool_call, and every
    assistant tool_call is followed by a tool result."""
    for i, message in enumerate(messages):
        if message.get("role") == "tool":
            assert i > 0, "orphaned tool result at position 0"
            previous = messages[i - 1]
            assert previous.get("role") in ("assistant", "tool"), (
                f"tool result at {i} lost its tool_call (prev={previous.get('role')})"
            )
        if message.get("tool_calls"):
            assert i + 1 < len(messages), "trailing tool_call with no result"
            assert messages[i + 1].get("role") == "tool", (
                f"tool_call at {i} lost its result"
            )


# -- tier 2 / 3: summarization -------------------------------------------


def test_tier2_summarizes_the_middle_without_an_aux_model_doing_nothing():
    messages = _long_history(10)
    without = _shape_ladder(None)
    without.compress(messages)
    assert without.last_stats.tier == 1  # no aux model -> tier 1 only, no spend

    aux = RecordingAux()
    with_aux = _shape_ladder(AuxSummarizer(aux))
    with_aux.compress(messages)
    assert with_aux.last_stats.tier == 2
    assert len(aux.prompts) == 1
    assert with_aux.last_stats.saved_ratio > 0.5


def test_summary_prompt_carries_the_hard_instructions():
    aux = RecordingAux()
    _shape_ladder(AuxSummarizer(aux)).compress(_long_history(10))
    prompt = aux.prompts[0]
    assert "SUMMARIZE, DO NOT ANSWER" in prompt
    assert "PAST TENSE" in prompt  # past-tense anchoring
    assert "[REDACTED]" in prompt  # forced redaction instruction
    for section in ("GOAL:", "CONSTRAINTS:", "COMPLETED:", "ACTIVE:", "BLOCKED:",
                    "DECISIONS:", "FILES:", "CRITICAL:"):
        assert section in prompt


def test_tier3_updates_the_existing_summary_instead_of_regenerating_it():
    aux = RecordingAux(["GOAL: ship\nCOMPLETED: read the early files",
                        "GOAL: ship\nCOMPLETED: read every file"])
    ladder = _shape_ladder(AuxSummarizer(aux))

    history = _long_history(10)
    ladder.compress(history)
    assert ladder.last_stats.tier == 2
    first_summary = ladder.summary

    # The run continues; the history grew. The second pass must UPDATE.
    history = history + sum((_tool_round(100 + i, f"later {i} " * 500) for i in range(6)), [])
    ladder.compress(history)
    assert ladder.last_stats.tier == 3

    second = aux.prompts[1]
    assert "UPDATE the existing summary" in second
    assert first_summary in second  # the prior summary is the base
    assert "later 0" in second  # only the newly-aged slice is re-sent
    assert "f0.py" not in second  # ...the already-summarized part is NOT
    assert ladder.summary != first_summary


def test_secrets_never_reach_the_summary():
    secret = "sk-live-AbCdEf0123456789ZzYy"
    password = 'password="hunter2-correct-horse"'
    messages = _sysuser() + [
        {"role": "assistant", "content": f"exporting {secret}"},
        {"role": "user", "content": password},
    ]
    messages += _long_history(8)[2:]

    ladder = _shape_ladder(AuxSummarizer(EchoAux()))
    ladder.compress(messages)
    summary = ladder.summary or ""
    assert secret not in summary
    assert "hunter2-correct-horse" not in summary
    assert "[REDACTED]" in summary


def test_redact_secrets_covers_the_common_shapes():
    samples = {
        "sk-ABCDEFGH01234567890": "sk-",
        "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345": "ghp_",
        "AKIAIOSFODNN7EXAMPLE": "AKIA",
        'api_key: "s3cr3t-value-here"': "s3cr3t-value-here",
        '{"token":"abcdef123456"}': "abcdef123456",
        "Authorization: Bearer abcdef123456789": "abcdef123456789",
    }
    for raw, needle in samples.items():
        assert needle not in redact_secrets(raw), raw
    # Redacting a JSON blob leaves it parseable.
    assert json.loads(redact_secrets('{"token":"abcdef123456"}'))["token"] == "[REDACTED]"


# -- anti-thrashing -------------------------------------------------------


def test_anti_thrash_skips_after_two_lean_passes():
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            thrash_min_savings=0.10,
            thrash_window=2,
            # Nothing to dedup or truncate -> every pass saves ~0%.
            dedup_min_chars=10_000_000,
            max_tool_result_tokens=10_000_000,
            max_tool_arg_chars=10_000_000,
        )
    )
    messages = _long_history(6)

    ladder.compress(messages)
    assert ladder.last_stats.saved_ratio < 0.10
    assert ladder.last_stats.skipped_reason is None
    ladder.compress(messages)
    assert ladder.last_stats.skipped_reason is None

    # Two lean passes in a row: stop paying for the attempt.
    out = ladder.compress(messages)
    assert out is messages
    assert ladder.last_stats.skipped_reason == "anti_thrash"


def test_a_fat_pass_keeps_the_ladder_alive():
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000, reserved_output=1_000, tier1_threshold=0.10,
            dedup_min_chars=100, max_tool_result_tokens=10_000_000,
            tail_token_budget=0, thrash_window=2,
        )
    )
    payload = "repeat me " * 400
    messages = _sysuser() + _tool_round(0, payload) + _tool_round(1, payload)
    ladder.compress(messages)
    assert ladder.last_stats.saved_ratio > 0.10
    ladder.compress(messages)
    ladder.compress(messages)
    assert ladder.last_stats.skipped_reason is None


# -- prepare(): scrub + compress -----------------------------------------


def test_prepare_scrubs_stale_reasoning_before_compressing():
    ladder = ContextLadder(config=LadderConfig(context_length=100_000))
    messages = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "go"},
        {"role": "assistant", "content": "<think>old plan</think>did a thing"},
        {"role": "user", "content": "more"},
        {"role": "assistant", "content": "<think>new plan</think>doing"},
    ]
    out = ladder.prepare(messages)
    assert out[2]["content"] == "did a thing"
    assert out[4]["content"] == "<think>new plan</think>doing"


def test_calibration_uses_real_prompt_tokens():
    ladder = ContextLadder(config=LadderConfig(context_length=100_000))
    sent = ladder.prepare(_sysuser())
    estimate = estimate_messages_tokens(sent)
    ladder.record_usage({"prompt_tokens": estimate * 2})
    assert ladder.calibration == pytest.approx(2.0)


# -- wiring: the loop actually sends the compressed payload ---------------


def _big_result(tag: str) -> str:
    return (f"{tag} " * 2_000)


def test_loop_sends_the_compressed_payload_and_keeps_the_full_history(tmp_path):
    """The store stays the source of truth; only the wire payload is compressed."""
    from cowork_agent.loop import AgentLoop, IterationBudget
    from cowork_agent.model import MockModelClient
    from cowork_agent.registry import ToolRegistry
    from cowork_agent.state import StateStore

    registry = ToolRegistry()
    payload = _big_result("same")
    registry.register(
        "peek", {"type": "object", "properties": {}}, lambda: payload
    )

    call = '<tool_call>{"name":"peek","arguments":{}}</tool_call>'
    model = MockModelClient([call, call, call, "done"])
    store = StateStore(str(tmp_path / "s.db"))
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            dedup_min_chars=100,
            max_tool_result_tokens=10_000_000,
            tail_token_budget=0,
        )
    )
    loop = AgentLoop(
        model, registry, store, max_iterations=8, budget=IterationBudget(8),
        system_prompt="sys", context_ladder=ladder,
    )
    result = loop.run("k", "go")
    assert result.final_answer == "done"

    # The last payload the model saw carries back-references, not three copies.
    last = model.calls[-1]
    markers = [m for m in last if isinstance(m.get("content"), dict) and DUP_KEY in m["content"]]
    assert markers
    assert sum(1 for m in last if m.get("content") == payload) == 1

    # The stored history is untouched: all three results are there in full.
    stored = [m.content for m in store.get_conversation(result.session_id)]
    assert sum(1 for m in stored if m.get("content") == payload) == 3


def test_loop_feeds_backend_usage_into_the_ladder(tmp_path):
    from cowork_agent.loop import AgentLoop, IterationBudget
    from cowork_agent.registry import ToolRegistry
    from cowork_agent.state import StateStore

    class UsageModel:
        def complete(self, messages: list[dict]) -> ModelResponse:
            return ModelResponse(text="done", raw={"usage": {"prompt_tokens": 999}})

    ladder = ContextLadder(config=LadderConfig())
    loop = AgentLoop(
        UsageModel(), ToolRegistry(), StateStore(str(tmp_path / "s.db")),
        max_iterations=2, budget=IterationBudget(2), system_prompt="sys",
        context_ladder=ladder,
    )
    loop.run("k", "go")
    assert ladder.calibration != 1.0  # the real prompt_tokens landed


def test_build_runtime_enables_the_ladder_by_default(tmp_path):
    from cowork_agent.model import MockModelClient
    from cowork_agent.runtime import build_runtime

    loop = build_runtime(MockModelClient([]), db_path=str(tmp_path / "a.db"))
    assert loop.context_ladder is not None
    assert loop.context_ladder.summarizer is None  # tier 1 only without an aux model

    with_aux = build_runtime(
        MockModelClient([]), db_path=str(tmp_path / "b.db"), aux_model=MockModelClient([])
    )
    assert with_aux.context_ladder is not None
    assert with_aux.context_ladder.summarizer is not None

    off = build_runtime(
        MockModelClient([]), db_path=str(tmp_path / "c.db"), context_ladder=False
    )
    assert off.context_ladder is None


def test_lean_tier1_passes_do_not_lock_out_a_tier2_escalation():
    """Two lean deterministic passes say nothing about whether the summary would
    pay off. The guard must not block a tier it has never tried."""
    aux = RecordingAux()
    ladder = ContextLadder(
        config=LadderConfig(
            context_length=4_000,
            reserved_output=1_000,
            tier1_threshold=0.10,
            tier2_threshold=0.90,
            head_messages=2,
            tail_token_budget=400,
            dedup_min_chars=10_000_000,
            max_tool_result_tokens=10_000_000,
            max_tool_arg_chars=10_000_000,
            thrash_window=2,
        ),
        summarizer=AuxSummarizer(aux),
    )
    small = _long_history(2)  # over tier 1, under tier 2 -> two lean passes
    ladder.compress(small)
    ladder.compress(small)
    assert ladder.last_stats.tier == 1
    assert ladder.last_stats.saved_ratio < 0.10
    assert ladder.last_stats.skipped_reason is None

    # The run grows past the tier-2 threshold: the summary must still be tried.
    ladder.compress(_long_history(12))
    assert ladder.last_stats.skipped_reason is None
    assert ladder.last_stats.tier == 2
    assert aux.prompts
