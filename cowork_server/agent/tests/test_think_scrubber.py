"""Tests for the streaming reasoning scrubber (§7.3)."""

from __future__ import annotations

from cowork_agent.think_scrubber import ThinkScrubber, scrub_history, scrub_text

TOOL_CALL = '<tool_call>{"name":"write_file","arguments":{"path":"a.py"}}</tool_call>'


def _stream(chunks: list[str]) -> tuple[str, str]:
    scrubber = ThinkScrubber()
    out = "".join(scrubber.feed(c) for c in chunks)
    out += scrubber.finish()
    return out, scrubber.reasoning


# -- the basic contract ---------------------------------------------------


def test_strips_think_block_in_one_chunk():
    visible, reasoning = _stream(["before<think>secret plan</think>after"])
    assert visible == "beforeafter"
    assert reasoning == "secret plan"


def test_strips_reasoning_tag_too_and_is_case_insensitive():
    visible, reasoning = _stream(["a<Reasoning>hmm</REASONING>b"])
    assert visible == "ab"
    assert reasoning == "hmm"


# -- chunk-boundary safety (the hard one) ---------------------------------


def test_tag_split_across_two_chunks():
    # The opening tag is cut in half by the transport.
    visible, reasoning = _stream(["hello <thi", "nk>plan</think> world"])
    assert visible == "hello  world"
    assert reasoning == "plan"


def test_closing_tag_split_across_two_chunks():
    visible, reasoning = _stream(["<think>plan</thi", "nk>done"])
    assert visible == "done"
    assert reasoning == "plan"


def test_tag_split_character_by_character():
    text = "keep<think>drop</think>keep2"
    visible, reasoning = _stream(list(text))
    assert visible == "keepkeep2"
    assert reasoning == "drop"


def test_partial_tag_that_never_completes_is_emitted():
    # "<thi" was never a tag; finish() must give it back, not swallow it.
    visible, reasoning = _stream(["ok <thi"])
    assert visible == "ok <thi"
    assert reasoning == ""


# -- nested / incomplete --------------------------------------------------


def test_nested_think_blocks_are_stripped_whole():
    visible, reasoning = _stream(["a<think>x<think>y</think>z</think>b"])
    assert visible == "ab"
    assert reasoning == "xyz"


def test_unterminated_think_swallows_the_rest():
    # Fail safe: a half-open think block must not leak into the answer.
    scrubber = ThinkScrubber()
    visible = scrubber.feed("answer<think>still thinking")
    visible += scrubber.finish()
    assert visible == "answer"
    assert scrubber.inside
    assert "still thinking" in scrubber.reasoning


def test_stray_closing_tag_is_dropped_not_emitted():
    visible, _ = _stream(["a</think>b"])
    assert "</think>" not in visible


# -- <tool_call> integrity ------------------------------------------------


def test_tool_call_block_passes_through_untouched():
    visible, _ = _stream([f"here you go {TOOL_CALL}"])
    assert TOOL_CALL in visible


def test_tool_call_split_across_chunks_survives():
    mid = len(TOOL_CALL) // 2
    visible, _ = _stream(["<think>plan</think>", TOOL_CALL[:mid], TOOL_CALL[mid:]])
    assert visible == TOOL_CALL


def test_tool_call_prefix_does_not_trigger_a_holdback_loss():
    # "<t" is a prefix of "<think>", so it is held back — and must come back.
    visible, _ = _stream(["<t", "ool_call>{}", "</tool_call>"])
    assert visible == "<tool_call>{}</tool_call>"


def test_think_block_containing_a_tool_call_is_removed_with_it():
    # A tool call the model only *considered* inside its thinking is not a call.
    visible, reasoning = _stream([f"<think>maybe {TOOL_CALL}</think>final"])
    assert visible == "final"
    assert TOOL_CALL in reasoning


# -- send-side: only the newest turn replays its reasoning -----------------


def test_scrub_history_keeps_only_the_newest_turns_reasoning():
    messages = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "go"},
        {"role": "assistant", "content": "<think>old</think>step one"},
        {"role": "user", "content": "next"},
        {"role": "assistant", "content": "<think>new</think>step two"},
    ]
    out = scrub_history(messages)
    assert out[2]["content"] == "step one"
    assert out[4]["content"] == "<think>new</think>step two"
    # The input list is never mutated — the store stays the source of truth.
    assert messages[2]["content"] == "<think>old</think>step one"


def test_scrub_history_can_strip_every_turn():
    messages = [{"role": "assistant", "content": "<think>x</think>y"}]
    assert scrub_history(messages, keep_newest=False)[0]["content"] == "y"


def test_scrub_text_one_shot():
    visible, reasoning = scrub_text("<think>a</think>b")
    assert (visible, reasoning) == ("b", "a")
    assert scrub_text(None) == ("", "")
