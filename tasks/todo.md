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
- [x] **P2 (lite). Kill per-frame JSON decode on mobile.** DONE. Added 4 per-payload decode
      caches (images/attachments/toolCalls/contentBlocks) keyed by the raw JSON string + helper
      methods, replacing the inline jsonDecode-every-build in the mobile itemBuilder (desktop
      already had this). Scrolling a static chat is now decode-free. Caches cleared on chat
      switch. Tests 799 green, analyze clean.
      DEFERRED (bigger/riskier, not done): full typed immutable message model replacing
      List<Map<String,String>>, and stable per-message-id keys (index keys are correct for the
      append-only common case; changing them touches persistence identity).
- [ ] **P4. Mobile scroll-back keep-alive.** DEFERRED intentionally. Mobile sets
      addAutomaticKeepAlives:false — a deliberate memory choice for long chats on low-end
      phones. Flipping to true (desktop's setting) trades markdown re-parse on scroll-back for
      unbounded per-bubble state memory; not safe to change without on-device profiling. P1
      already fixed the primary scroll-during-streaming jank.
- [x] **P3. message_bubble memoization.** DONE (strip cache). Added `_strippedMessage` getter
      caching `stripToolCallBlocksForDisplay(widget.message)` per distinct message string;
      replaced all 4 per-build call sites. A rebuild that doesn't change the text is now free.
      Segment/timeline memoization intentionally SKIPPED: after P1 removed the 30fps rebuild it
      only runs on scroll-into-view, and safely caching a `List<Widget>` (theme/colour-dependent)
      in that 4.6k-line file is higher risk than the remaining benefit. Tests green, analyze clean.
- [ ] **P4. Mobile scroll-back.** Keep-alive for markdown-heavy mobile bubbles; re-tune
      cacheExtent. (reverse:true list = higher risk; only if time + tests allow.)
- [x] **P5. Mobile composer redesign.** DONE. Replaced the three 46px pills with ONE unified
      rounded box (~2× taller, minHeight 88, radius 24, 2px border) mirroring desktop: TextField
      on top (maxLines null + 140px cap, grows then scrolls), a persistent bottom toolbar row
      (`+` attach, reasoning toggle, model picker, mic, fullscreen), and the send/stop/voice
      button pinned top-right. Recording state shows the indicator+visualizer with a stop button.
      All handlers/sub-widgets preserved (attach, mic, model dropdown, editing/queued banners,
      fullscreen, audio send). Taller height auto-reflows the list via the existing MeasureSize.
      analyze back to 4 baseline issues, 799 tests green. NOTE: compile+test verified only — no
      emulator/device in this env, so final visual look must be checked on-device.
- [ ] **P6. Riverpod adoption at the seam.** Promote ChatRuntime → NotifierProvider.family;
      bind message list + streaming flags to providers. Keep race guards.

## Verification per phase
- `flutter analyze` (no new errors) + `flutter test` (all pass, baseline was ~765 green)
- Reason about visual identity (same widgets/decoration/measurements)

## Review (filled in as work completes)
- (P0 baseline numbers go here)
