# Fix interleaved streaming content blocks

## Problems (from debug export)

1. Reasoning text appears twice per round in contentBlocks (`buildRoundBlocks`
   reappends on pass retries).
2. Final answer text appears twice back-to-back as two text blocks.
3. Flat `text` field contains interim fragments plus final answer repeated twice.
4. Live tool calls during streaming appear at the tail instead of interleaved
   in true emission order.

## Plan

- [ ] Make `RoundContentBlockService.buildRoundBlocks` idempotent: caller
      passes the current `contentBlocks` list; if the newly-built tail exactly
      matches the existing tail, return empty.
- [ ] Update `streaming_message_handler.dart` to call the new API and stop
      accumulating interim text that is already represented as a block (for the
      back-compat flat `text` field). In practice: prevent final-answer
      duplication via suffix/prefix trimming in `mergeAccumulatedWithFinal`.
- [ ] Strengthen `dedupeFinalTextAgainstBlocks` to also drop final text when it
      equals the last text block in `contentBlocks` (not just the joined
      prefix).
- [ ] Clean up `_buildContentBlocksLayout` in `message_bubble.dart`: treat
      live tool calls as a synthetic in-progress tool-calls block appended to
      the ordered block list before rendering, rather than as a
      post-trailing-text tail. Preserve current visible ordering.
- [ ] Add unit tests for:
  - Idempotent `buildRoundBlocks` (appending same input twice → second call
    returns no new blocks).
  - `dedupeFinalTextAgainstBlocks` via a small extracted helper (make pure so
    we can test it).
- [ ] `flutter analyze` clean.
- [ ] `flutter test` all pass.
- [ ] `coderabbit review --plain --type uncommitted` clean.
- [ ] Commit + push.
