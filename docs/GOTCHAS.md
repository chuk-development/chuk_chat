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

## "Auto (cheapest)" provider is a marker, not a provider

- `kAutoCheapestProviderSlug` (`__auto_cheapest__`) is stored when the reader
  picks Auto. The server does not know it. Resolve it only through
  `ProviderResolutionService.resolveForSend` (`lib/services/provider_resolution_service.dart`),
  which reads the model catalogue from `ModelCacheService` and fetches it once
  (`ModelPrefetchService.prefetch(force: true)`) when the model is missing.
- Never resolve providers through `ModelSelectionDropdown` state: that widget is
  not built anywhere any more, so its lists are always empty. That is why every
  send with Auto failed with "No provider is configured" until 2026-11-03.
- `MessageCompositionService.prepareMessage` and the multiplex send both run the
  resolver again as a last guard. Tests: `test/services/provider_resolution_service_test.dart`.
- The composer's model menu (`pickedModels`) rebuilds on
  `ModelSelectionEventBus().refreshStream` in `ChatModelSelectionMixin`. The model
  screen writes its fresh `/v1/models_info` payload to `ModelCacheService`, so a
  newly enabled model has its name and providers at once.
  Test: `test/services/composer_model_menu_sync_test.dart`.

## Stream end, finish_reason and tool-call ids (2026-11-04)

- **A hosted stream that ends without `done` is an error, not an answer.**
  The idle timeout (`idle_timeout`), a close without `done`
  (`stream_interrupted`) and the server's `upstream_interrupted` all go to
  `onError`. The cut text is parked in the StreamingManager; the error
  handlers read it once with `takeInterruptedPartial(chatId)` and keep it
  above the error. An Agents thread still completes on close (its transport
  owns the terminal events).
- **Out of credits is the error code `billing`** (or class `quota`), not
  HTTP 402. `StreamingManagerBase` maps both to `kPaymentRequiredError`
  (`__PAYMENT_REQUIRED__`), which opens the upgrade dialog on mobile
  (`onPaymentRequired`) and desktop (`_showPaymentRequiredDialog`).
- **`finish_reason` reaches the tool loop as a `MetaEvent`.** Old servers
  send it only on the `timing` frame of phase `complete`, new ones on a
  `meta` frame and on `done`; `multiplex_connection.dart` reads all three.
  Meta events merge into `latestMeta`, they do not replace it.
- **Native tool-call ids are made unique per conversation** before a round
  runs (`_nativeCallsToParsed`), and `validateToolPairing`
  (`lib/services/tool_pairing_validator.dart`) repairs the history before
  every request. Two calls with one id used to overwrite each other.
- **Shut tools keep `tools[]` and send `tool_choice: "none"`**
  (`ToolCallHandler.nativeToolChoice`), so the prompt cache still hits.
  `nativeToolChoice` is static because `AgentsToolCallHandler` implements
  `ToolCallHandler` as an interface: a new instance member breaks it.

## Prompt cache: keep the prefix stable (2026-11-04)

Providers cache the request prefix byte by byte: system prompt, `tools[]`,
then the history. The first changed byte makes everything after it a cache
miss at full price. Within a chat, every request must be an exact extension
of the one before it: across tool-loop passes, turns and app restarts.
Code: `lib/services/prompt_cache/`, test:
`test/services/prompt_cache_stability_test.dart`.

- **Nothing in the system prompt changes during a chat.** No date: each user
  message starts with `[Sent: Wed 2026-11-04 14:32]`, made from its stored
  `sentAt` string alone (`sentStampLine`, no clock, no time zone lookup), for
  the turn being sent and for every later history alike. The tool loop builds
  the system prompt once per turn (`ToolLoopSession.frozenSystemPrompt`); the
  "after tool results" guidance is always in it, not only on pass 2+.
- **Soul / user info / memory and the MCP server list are a snapshot**, taken
  at the chat's first request and stored on that user message
  (`ChatMessage.modelContext`, JSON `TurnPromptContext`). A later change is a
  tagged note at the head of the next user message (`[memory updated]`,
  `[connectors updated]`), stored with it. Never rewrite message 0.
- **Skill bodies are a `<skill_content name="…">` user message** after the
  round that loaded the skill, stored with the turn. Never `## ACTIVE SKILL`
  in the system prompt. Prompt-based mode lists no discovered tools in the
  prompt; their definitions arrive as the `find_tools` result.
- **The send path must send `toolSession.firstPassMessage`** (not the raw
  text) and pass `userSentAt` to `createSession`, or pass 1 and pass 2 differ
  at the user message.
- **`tools[]` order is fixed** (`ToolExecutor.allTools`): built-ins in
  `builtinTools` order, then MCP / Chukdoo tools by name. An MCP reconnect
  must not reorder them.
- **Tool results are capped once**, when they go into the history: head 4096
  + `\n\n[... tool result middle pruned ...]\n\n` + tail 1024 code points
  (`capToolResultForModel`). Never shorten an older round later. The
  api_server applies the same cap (`chat/tool_history.py`).
- **Images stay in the history.** No "last N turns" window. At send,
  `ImageBudget.apply` checks per-family limits (Anthropic 100, OpenAI 500,
  Google 3000, others 50; 12 MB of base64 for all) and replaces the OLDEST
  images with `[image omitted: <name>]` in steps of half the limit, so the
  cut point moves rarely. A text-only model (catalog `supports_vision:
  false`) gets placeholders for all. History parts carry the storage path;
  the send loads only the kept images, with the same bytes and type label as
  the turn that first sent them.
- Requests carry `x_chuk: {purpose, chat_hash, pass}` (`chat`, `title`,
  `final`; hash = first 16 hex of sha256(chat id), never the id or the user).
  The server strips it.
- Usage: unknown cache counts stay null and show as "—", never 0.
- **A turn replays exactly what it sent.** `TurnPromptContext.sent` is the
  user text as sent (`Document: … User query: …`); in storage each document
  body is a private-use marker pointing into `attachments`
  (`PromptContextLedger.storedContextOf`). `transcript` is everything the
  tool loop sent after the user message (native `tool_calls` + `tool`
  messages with the capped results, `<skill_content>`, prompt-based rounds,
  the last pass's own user message), recorded on every continuation
  (`_stepHistory`). The next turn replays it as it is, so it starts with the
  previous turn's last request; that assistant message then gets no
  `<previous_tool_results>` block (only old messages without a transcript
  do).
- **Tool-round replay is frozen per chat** (`PromptState.toolHistory` in the
  snapshot, from `includeToolResultsInHistory` at the chat's first request).
  Off: earlier turns replay text only, never flipping mid-chat. Over
  `ChatHistoryBuilder.transcriptBudgetChars` (200k chars) the oldest turns'
  rounds are dropped in steps of half the budget; each skill they loaded
  leaves `[skill <name> was loaded earlier; call skill again if needed]`.
- **The skills catalog is in the snapshot** (`PromptState.skills`); a change
  is a `[skills updated]` note on the next user message.
- **Images of the turn on later passes** go into the turn's own history
  entry (`ToolLoopStep.withTurnImages`), never with `message` (that put them
  on the tool results). The first pass sends the turn's images all by
  reference or all in full, never mixed: the server puts refs first.
- **Native tool passes send those images as refs** when the server still
  holds all of them (`WebSocketChatService.foldTurnImageRefs`): the entry
  goes up with its text only, plus `image_cache_refs`, and the server's
  `attach_turn_images` puts them back on the same entry, after the text.
  The provider bytes do not change.
- **The turn's entry is named, not guessed.** Every native pass sends
  `turn_history_index` = `ToolLoopStep.turnUserIndex` (the send paths pass
  `next.turnUserIndex` as `turnHistoryIndex`; `WebSocketChatService.turnAnchor`).
  The server uses that entry and, when the caps dropped it, guesses
  nothing. Without the field (old client, other path) both sides use one
  fallback rule (`toolLoopTurnIndex` = `tool_loop_turn_index`): skip the
  trailing loop (`tool_calls` turns, `tool` results, synthetic user
  messages), then take the nearest user message before the first call that
  is not synthetic. Synthetic = starts with `<skill_content`, `[skill `
  (dropped-skill marker), `Tool Results:` (text-protocol results, recovery
  and `[VERIFY]` notes) or `kForcedFinalAnswerNote`. Not synthetic:
  `[memory updated]` / `[connectors updated]` / `[skills updated]`, because
  those notes head the turn's own message (`renderUserTurnForModel`). The
  prefix list is `syntheticUserPrefixes` here and `SYNTHETIC_USER_PREFIXES`
  on the server: keep them identical.
- **Text parts are stripped only at the outer edges** on the server
  (`history_content_blocks`): leading whitespace of the first non-blank
  text part, trailing of the last; inner parts keep every character
  (`"hello "` + `" world"` keeps its space). One text part = the string
  form = `message`. The app builds turn text already trimmed
  (`renderUserTurnForModel`), so both forms are the same bytes; never
  trim single parts in the app either. Not folded, so sent in full: a pass with a
  `message` (prompt-based mode; the server would add a new user turn), an
  image-only entry (the server drops it), text after an image, a missing
  ref. The server resolves image refs only for the current turn, so an
  older turn's images in later history still go up in full each request.
- **`modelContext` is bounded in storage** (`storedContextOf` ->
  `TurnPromptContext.compactForStorage`) without changing the replay: a
  note's state is a `stateDiff` against the state before it (old payloads
  keep a whole `state`); a skill body the transcript carries is stored once
  (decode takes it back from the `<skill_content>` block); a transcript over
  `kTranscriptBudgetChars` is always dropped by the replay budget, so only
  `transcriptChars` (its `jsonEncode` length, for the budget) and
  `transcriptSkills` (for the marker rows) are kept.
