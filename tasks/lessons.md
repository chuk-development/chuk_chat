# Lessons

## Never classify model output by its TEXT — classify by PROTOCOL/structure

**Date:** 2026-06-08

**Mistake:** To stop Kimi's chain-of-thought + draft HTML leaking into the
answer body, I first stripped fenced ```code``` blocks and matched on the
streamed text. User rejected this hard: "du kannst nicht nach Text filtern, das
ein Modell gibt — immer einen anderen Text. Es ist unmöglich danach zu filtern."

**Why it's wrong:** A model emits arbitrary, ever-changing text. Any
text-pattern heuristic (fenced code, key phrases, language) is brittle and
breaks on the next prompt.

**Rule for myself:** Decide what is "answer" vs "reasoning" vs "tool" using the
PROTOCOL only:
- "Did this round emit tool calls?" (known at round end) -> if yes, its content
  is working text -> fold into reasoning, never the answer.
- "Has a tool-call token appeared in the stream?" (`hasToolCallStartMarker`,
  structural delimiters incl. Kimi `<|tool_calls_section_begin|>`) -> suppress
  content from the answer body live.
- Fold content VERBATIM — never edit/strip the model's text.

If the only fix I can think of requires reading what the words say, stop — the
boundary I want is almost always available structurally (channel, delimiter,
round outcome).
