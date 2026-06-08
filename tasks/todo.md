# Fix: Kimi k2.6 reasoning/draft-code leaking into answer + live streaming

## Problem (from live session + 2 debug exports, chat 0635cd09)

Model: moonshotai/kimi-k2.6 (fireworks). Kimi dumps chain-of-thought AND draft
HTML into the **content channel** between tool calls. The send loop treats
interim content-channel prose as the *answer* → it renders as the message body.

Final message `Text:` field = 14,201 chars of CoT ("Wait for real results…",
"Lass mich die Folien strukturieren:", a full ```html``` draft) instead of a
real answer. Block order ends `… → sandboxArtifact → text` (the leaked CoT).

### Symptoms
- A. Reasoning prose shown as answer body
- B. Draft ```html``` code block shown as answer
- C. Answer doesn't stream live during tool passes — "snaps" at end
- D. Final answer after last tool round empty / is actually leaked CoT
- E. (user) sent HTML file should show only the file card, not the code

### Decisions (user)
- Interim content-channel text -> **fold into reasoning** (general, not just Kimi)
- Live streaming -> **yes, live trailing text** during passes
- The draft code must **not** be shown to the user at all

## Plan

### Phase 1 — Stop the leak (A, B, D, E)  [core]
- [ ] `round_content_block_service.dart`: add `foldInterimIntoReasoning` mode to
      `buildRoundBlocks` (and segmented variant). When set:
      - interim content text merged into the round's reasoning block (with
        provider reasoning), NOT emitted as a `text` block
      - strip fenced ```code``` blocks from the folded interim text
      - `interimOutputText` returns '' so it never pollutes the answer field
- [ ] `desktop_send_logic.dart:522` (interim branch): use fold mode; stop
      writing `interimOutputText` into `accumulatedText`
- [ ] `desktop_send_logic.dart:1623` (other build site): same treatment
- [ ] `streaming_message_handler.dart:648/653` (mobile): same treatment
- [ ] Terminal (final-answer) pass unchanged — its content stays the answer

### Phase 2 — Live trailing text (C)
- [ ] Verify `message_bubble.dart` trailingText (l.1056-1111) shows current
      pass's streaming content live now that `accumulatedText` isn't polluted
- [ ] Strip complete fenced code blocks from the live display
- [ ] Confirm the real final answer streams live and stays

### Phase 3 — verify
- [ ] `flutter test` green (+ tests for fold mode + fenced-code strip)
- [ ] `flutter analyze`
- [ ] Manual: re-run Schlaf-Präsentation prompt
- [ ] coderabbit review

### Deferred (note, not now)
- HTML file inline preview/webview on Linux — user OK with file card for now

## Review — STRUCTURAL redesign (no text filtering)

Hard rule from user: never classify model output by its TEXT (always varies).
Classify by PROTOCOL only.

Implemented:
- `round_content_block_service.dart`: `foldInterimIntoReasoning` on both
  `buildRoundBlocks` + `buildSegmentedRoundBlocks`. A round that emits tool
  calls -> its content is folded VERBATIM into that round's reasoning (collapsed
  in the tool bar); `interimOutputText` returns ''. No text edits, no code
  stripping. `_mergeReasoning` dedups only by containment.
- Wired fold at all 3 build sites (desktop x2 + mobile handler); interim text
  no longer accumulates into the answer field.
- Live (onUpdate, all 3 sites): a round's streamed content stays OUT of the
  answer body whenever `contentBlocks.isNotEmpty` (mid tool-loop) OR
  `hasToolCallStartMarker(content)` (a tool-call token has appeared). Purely
  structural. A plain round with no tool calls streams live as before.
- `tool_parser.dart`: `hasToolCallStartMarker` now also detects Kimi
  `<|tool_calls_section_begin|>` / `<|tool_call_begin|>` tokens (structural).
- Tests: fold-verbatim + Kimi-token detection. 765 green, analyze clean.

Behaviour: tool bar collapses all CoT/draft; answer body shows only a round
with no tool calls. Final answer of a tool-turn appears on completion (not
char-streamed) — the structural cost of "no text heuristics". Plain answers
still stream live.

Known structural limit: a terminal round whose content is itself pure CoT (no
tool calls) still shows as the answer — unavoidable without text heuristics.

Deferred: Linux HTML inline preview (file card is fine for now).
