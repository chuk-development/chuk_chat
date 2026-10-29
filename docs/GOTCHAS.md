# Gotchas & Important Fixes

Critical things to remember when working on this codebase.

## Message Fields Preservation
**Problem:** Data loss and message duplication due to realtime sync loops.

**Rule:** When loading messages from storage (`_loadChatFromIndex()` or `_handleRealtimeChatUpdate()`), ALWAYS preserve ALL fields including `images` and `attachments`.

Both desktop and mobile UIs must handle these fields identically.

## Image Sending on Mobile
**Problem:** Images not sent to AI on first message, but work on resend.

**Cause:** `_fileHandler.attachedFiles` cleared in `setState` BEFORE passed to streaming handler.

**Fix:** Capture files BEFORE clearing:
```dart
final List<AttachedFile> attachedFilesForApi = List.from(_fileHandler.attachedFiles);
// ... setState clears _fileHandler.attachedFiles ...
await _streamingHandler.sendMessage(
  attachedFiles: attachedFilesForApi,  // Use captured list!
  ...
);
```

See `chat_ui_mobile.dart:1202-1314`

## Image Persistence in Messages
**Rule:** When sending messages with images, use `MessageCompositionService.prepareMessage()` result:
```dart
final result = await MessageCompositionService.prepareMessage(...);
final displayMessageText = result.displayMessageText!;
final images = result.images;

userMessage['images'] = jsonEncode(images);
```

## Mobile Streaming Focus
**Problem:** Keyboard focus fight when user tries to dismiss while AI is responding.

**Rule:** DO NOT refocus text field on every streaming token.

Only focus when user initiates send (`chat_ui_mobile.dart:884`), NOT during updates.

## Deprecation: withOpacity
**Use:** `color.withValues(alpha: 0.5)` instead of `color.withOpacity(0.5)`

## Platform-Specific Code
When adding UI features, implement BOTH:
- `lib/platform_specific/chat/chat_ui_desktop.dart`
- `lib/platform_specific/chat/chat_ui_mobile.dart`

## Theme/Customization Sync
Changes must update BOTH:
1. `SharedPreferences` (local)
2. Supabase (remote via service)

## Encryption
All chat data is encrypted client-side. Never log or commit unencrypted sensitive data.

## Build with Features
For testing all features:
```bash
flutter build apk \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_PROJECTS=true \
  --tree-shake-icons \
  --target-platform android-arm64
```

## Git Ignored Directories
- `releases/`
- `debian/`
- `rpm/`
- `AppDir/`
- `tools/`

## Chat scroll performance (scrolling up a long thread)
Measured 2026-10-29, after the owner reported that scrolling up a long Agents
thread lags, most of all at the start of the scroll. The anchored transcript
(`ChatScrollMixin.buildAnchoredTranscript`) builds every row above the
viewport for the first time while the reader scrolls up, so anything a row
does on mount lands in the scroll. Causes found, by measurement:

- **The jump button rebuilt the whole screen.** `onScrollChanged` ran
  `setState` on the chat State when the reader passed 260 px, a few frames
  into every scroll up: composer, app bar and every visible row, mid-drag.
  Now `scrollToBottomVisible` is a `ValueNotifier` and only the button
  listens. Never put per-scroll UI state into the chat screen's `setState`.
- **One isolate per code block.** `_AsyncCodeBlock` sent every block to
  `compute()`, and each spawn built all ~40 highlight grammars again. Blocks
  up to 3000 chars now highlight inline in `initState`; the registry
  (`highlight_registry.dart`) builds only the grammar asked for plus the ones
  it embeds (`registerLanguageWithEmbeds`). Do not touch `allLanguages` on
  the UI isolate: building that map builds every grammar.
- **Every bubble built twice on mount.** `_MessageBubbleState` set state from
  its SharedPreferences read one frame after mounting, with the same values.
  It now starts from the process-wide copy and only rebuilds on a change.

Numbers. Real screen (`MessengerShell`, 300 mixed messages, 412x892), first
30 frames of a drag up, profile build on the x86_64 AVD, two runs each:
build worst 15.2 / 25.0 ms before, 6.4 / 8.3 ms after, mean 1.3-1.6 -> 0.8 ms,
frames over 16 ms 1 -> 0. The same scroll in a debug widget test: the
button frame 41 -> 9 ms, the highlight frames (15-30 ms each) gone. The
phone's UI thread is slower than this host, so the spikes there were bigger.

How to measure (the files stay in the repo):
- `flutter test test/perf/chat_scroll_real_screen_perf_test.dart` (debug,
  real screen; `--dart-define=PERF_DIRTY=true` prints the dirty widgets of
  every slow frame) and `test/perf/chat_scroll_up_perf_test.dart` (the list
  alone).
- On a device: `flutter drive --profile -d <serial>
  --driver=test_driver/perf_driver.dart
  --target=integration_test/chat_scroll_screen_perf_test.dart
  --dart-define=FEATURE_AGENTS=true --dart-define=PLATFORM_MOBILE=true`
  (`chat_scroll_perf_test.dart` is the list alone; `PERF_MIX=prose|list|
  table|tableonly|code|tools|plain` narrows it to one kind of answer,
  `PERF_TRACE=true` records a timeline and needs `--no-dds`, otherwise the
  test cannot reach the VM service).
- Traps: **raster times on the AVD mean nothing.** They are almost all
  `AndroidContextGL::SwapBuffers` waiting on the emulated GPU, and the same
  build gives 3 ms or 16 ms per frame from one run to the next; the first
  run after a cold boot is far slower still. Compare build (UI thread) times
  only, and take the before and after on the same warm emulator. The running
  `cowork_x64` AVD cannot be started twice; a second AVD (`perf_x64`, same
  image) on port 5556 keeps a benchmark install away from the app another
  agent is testing. Do not run `flutter drive` on the owner's phone: it
  replaces his installed app and its login.
