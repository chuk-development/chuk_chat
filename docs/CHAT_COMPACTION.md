# Chat compaction (2026-11-05)

Long chats are summarized before they fill the model's window. The short
rules are in `docs/GOTCHAS.md` ("Chat compaction"); this is the full
reference.

Code: `lib/services/chat_compaction.dart` (pure logic),
`lib/services/chat_compaction_runner.dart` (catalogue, model choice, send),
test: `test/services/chat_compaction_test.dart` + the "chat compaction"
group in `prompt_cache_stability_test.dart`.

- **When:** before the first pass of a normal send (desktop
  `desktop_send_logic.dart`, mobile `streaming_message_handler.dart`), after
  the turn's system prompt is built. Trigger `min(W*0.8, W-O-H)`, H = 65536
  but at most `(W-O)/2` so small windows still work; O = the model's
  completion cap, else W/4. Keep the newest `0.16*(W-O)` tokens verbatim
  (always at least the last user turn). The old hard "Too much context"
  stop in `message_composition_service.dart` is gone.
- **Estimate (14):** anchored on the last real usage (prompt + completion of
  the newest answer with a stored `usage`, not older than the latest
  compaction's `madeAt`) plus an estimate of what came after. Without one it
  is the full estimate. Images use the per-model formula
  (`lib/utils/image_token_estimator.dart`: DeepSeek patch grid, Anthropic
  w*h/750, OpenAI 512 tiles) from the data URL header; unknown = 1000.
- **The summary request is a continuation**: the same system prompt, the same
  `tools[]` (`tool_choice: none`), the history byte for byte up to the kept
  tail (`ChatHistoryBuilder.build(messageStarts:)` gives the cut), plus one
  user instruction (8 sections), `x_chuk.purpose = compact`. A summary that
  is not smaller than the span it replaces is rejected; a failed compaction
  sends the turn as it is.
- **Model switch (17):** when the last answer came from a model with a larger
  window, that model writes the summary (its prefix is cached, the history
  fits it). Threshold and tail come from the new model.
- **Storage:** `compactSummary` on the first kept user message (see
  `docs/CHAT_PAYLOAD_FORMAT.md`). From then on the history is
  `[checkpoint preamble + <compacted-summary>…]` + the tail, after the frozen
  system prompt; earlier messages still feed the prompt-state walk
  (snapshot, state diffs) but add no entry, and the transcript budget counts
  only the tail. The chat list draws `CompactionDivider` above that message.
- **Resend, regenerate and continue compact too.** Desktop
  `_submitEditedMessage` runs `beforeSend` with `end` = the edited
  message (and recomputes the answer budget after a compaction); a
  continue compacts a copy of its history rows (`end` = their length, the
  last row is the answer it continues) and copies the summary onto the
  chat's own row at `tailStart`. Mobile resend/regenerate pass the live
  list (user row before the placeholder), the continue goes through
  `StreamingMessageHandler.onCompactionStored`. Not compacted: Agents
  threads (the host has its own context ladder) and the headless outbox
  turn (`headless_chat_turn.dart`, its rows do not carry the queued user
  message).
- **`/compact`** (composer `/` menu, `onCompact`):
  `lib/platform_specific/chat/manual_compaction.dart` builds the request
  a send of the chat would build (turn system prompt with an empty user
  message, `tools[]`, history of the whole chat) and calls
  `ChatCompactionRunner.compactNow`, which runs `beforeSend` with
  `force: true` and `end` = the chat length. It summarizes everything
  before the last user turn, whatever the size; with an unknown window it
  keeps `manualRetainTokens` (16000). One run per chat at a time.
