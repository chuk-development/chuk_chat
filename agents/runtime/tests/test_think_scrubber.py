"""Tests for the streaming reasoning scrubber (§7.3)."""

from __future__ import annotations

from cowork_agent.think_scrubber import ThinkScrubber, scrub_history, scrub_text

# The scrubber removes think/reasoning tags and NOTHING else. Any other markup
# in the stream is ordinary text and must survive byte-identical, even when the
# transport cuts it in half. This stand-in stands for all of it.
SNIPPET = '<snippet lang="py">print("hi")</snippet>'


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


# -- markup integrity: non-think tags are never touched -------------------


def test_non_think_markup_passes_through_untouched():
    visible, _ = _stream([f"here you go {SNIPPET}"])
    assert SNIPPET in visible


def test_non_think_markup_split_across_chunks_survives():
    mid = len(SNIPPET) // 2
    visible, _ = _stream(["<think>plan</think>", SNIPPET[:mid], SNIPPET[mid:]])
    assert visible == SNIPPET


def test_a_think_prefix_boundary_does_not_lose_text():
    # "<t" is a prefix of "<think>", so it is held back — and must come back
    # whole once the next chunk proves it was never a think tag.
    visible, _ = _stream(["<t", "able>cell", "</table>"])
    assert visible == "<table>cell</table>"


def test_markup_inside_a_think_block_is_removed_with_it():
    # Whatever the model only *considered* inside its thinking stays there.
    visible, reasoning = _stream([f"<think>maybe {SNIPPET}</think>final"])
    assert visible == "final"
    assert SNIPPET in reasoning


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


def test_a_pure_reasoning_turn_with_tool_calls_gets_null_content():
    """Native round-trip shape: an assistant turn that was only <think> around
    its tool calls has no visible text left, and the wire form for that is
    ``content: null`` (the same "tool-calls only" rule the backend applies) —
    not an empty string. A pure-reasoning turn WITHOUT tool calls keeps the
    empty string, since there is no call for null to mark."""
    call = {"id": "call_0", "type": "function", "function": {"name": "run_command", "arguments": "{}"}}
    with_calls = {"role": "assistant", "content": "<think>plan</think>", "tool_calls": [call]}
    without_calls = {"role": "assistant", "content": "<think>plan</think>"}

    out = scrub_history([with_calls, without_calls], keep_newest=False)

    assert out[0]["content"] is None
    assert out[0]["tool_calls"] == [call]
    assert out[1]["content"] == ""
