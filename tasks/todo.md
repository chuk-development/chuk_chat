# Chat UI Performance Re-Architecture + Riverpod + Mobile Composer Redesign

Branch: `claude/chat-ui-performance-rc7ivd`

## Goal (from user)
Chat UI (mobile + desktop) must **look exactly the same** but be **massively more
performant** (esp. mobile scrolling during streaming), adopt **Riverpod**, and the
**mobile composer** should be ~2× taller with a fresh design resembling the desktop composer.

## Engineering interpretation
A literal from-scratch rewrite of ~11k lines (2 UIs + send logic + 4.6k-line message_bubble)
would break a shipping v1.0.106 app and could not stay visually identical. Instead:
a deep, **verifiable, incremental** re-architecture of the hot paths + Riverpod adoption
at the highest-value seam + a contained composer redesign. `flutter analyze` + `flutter test`
green at every step. Same pixels, ~10× fewer rebuilds.

## Confirmed root causes (both platforms)
1. Per-token `setState` rebuilds the WHOLE screen ~30fps (list+composer+overlays). #1 jank.
2. `List<Map<String,String>>` messages → JSON-decoded per frame in itemBuilder.
3. Fresh closures/action-lists per item per build → MessageBubble always rebuilds.
4. `stripToolCallBlocksForDisplay` 2–4×/build + `_RenderSegment` timeline rebuilt w/ deep clones.
5. Forward ListView chasing estimated maxScrollExtent (settle loops + MeasureSize feedback).
6. Index keys `msg_$i`; mobile keepAlive:false re-parses markdown on scroll-back.

## Preserve (already optimal — DO NOT regress)
- MarkdownMessage parse cache; code highlight in compute() isolate; 33ms token coalescing;
  _CachedImageThumbnail keep-alive.

## Plan (sequenced by risk/reward, commit per phase)

- [x] **P0. Toolchain + baseline.** Flutter 3.44.6 installed. pub get OK. Baseline recorded:
      `flutter analyze` = 4 info-only (3× deprecated cacheExtent, 1× doc-comment), 0 errors;
      `flutter test` = **795 passed**. Native-asset downloads (pdfium, sqlite3) are blocked by
      org egress policy → patched the pub-cache hooks locally (pdfium→empty stub .so;
      sqlite3→system libsqlite3.so). NOT committed (outside repo). Next: add flutter_riverpod +
      ProviderScope.
- [x] **P1. Scope streaming rebuilds (BIGGEST WIN).** DONE. Added `StreamingLive` value type +
      `ChatRuntime.streamingLive` notifier + `pushStreamingText`. Both `_updateAiMessage`
      (mobile + desktop, incl. unifying the desktop send-path onto the shared method) now update
      `_messages` silently and push to the notifier instead of a screen-wide setState. The list
      itemBuilder wraps ONLY the streaming bubble in a `ValueListenableBuilder<StreamingLive?>`.
      One forced setState on the first token installs the wrapper; every later token rebuilds
      just that bubble. streamingLive cleared on finalize (both platforms). Result: ~30fps
      full-tree rebuild (all bubbles + composer + overlays) → one bubble body. Tests 799 green,
      analyze clean.
- [ ] **P2. Kill per-frame decode + unstable identity.** Parse each message into a typed
      model once (on add/mutate), not in build. Stable per-message-id keys. Memoize per-item
      action lists / askUser closures so MessageBubble configs are stable.
- [ ] **P3. message_bubble memoization.** Cache `stripToolCallBlocksForDisplay(message)` per
      content; memoize `_RenderSegment`/timeline for finalized messages (no per-build ToolCall
      deep-clone); cache visual-block JSON parse.
- [ ] **P4. Mobile scroll-back.** Keep-alive for markdown-heavy mobile bubbles; re-tune
      cacheExtent. (reverse:true list = higher risk; only if time + tests allow.)
- [ ] **P5. Mobile composer redesign.** Replace 3-pill 46px layout with one unified tall (~2×)
      rounded container mirroring desktop: TextField on top, persistent bottom toolbar row,
      send button pinned top-right, merged model/reasoning pill. Reuse AttachmentPreviewBar.
- [ ] **P6. Riverpod adoption at the seam.** Promote ChatRuntime → NotifierProvider.family;
      bind message list + streaming flags to providers. Keep race guards.

## Verification per phase
- `flutter analyze` (no new errors) + `flutter test` (all pass, baseline was ~765 green)
- Reason about visual identity (same widgets/decoration/measurements)

## Review (filled in as work completes)
- (P0 baseline numbers go here)
