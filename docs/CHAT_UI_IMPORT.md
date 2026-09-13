# Chat UI import (chuk_chat → Agents)

Agents does not have its own chat renderer. It imports chuk_chat's, verbatim, and
replaces the parts that only make sense against a hosted API with Agents-owned
stubs. This file records what was imported, what was stubbed and why, and how to
re-sync.

**Upstream:** `chuk_chat` `d31526a229fdde27c82adf3661d5d3a149db8340` (branch `master`).

**Imported:** 100 files, 45,179 lines, into `app/lib/`.
**Stubbed:** 25 Agents-owned files (plus one pre-existing stub extended).
**Excluded:** `lib/services/mcp/*` and everything that binds to it — Agents's MCP
is the source of truth.

Nothing imported is mounted yet. The running app's behaviour is unchanged; the
imported screens (`ChukChatUIDesktop` / `ChukChatUIMobile`) are compiled but
unreachable until P2b/P3 wires them into `AgentsThreadView`.

## Re-syncing with chuk_chat master

```bash
scripts/import_chat_ui.sh                # or: scripts/import_chat_ui.sh /path/to/chuk_chat
cd app && flutter analyze
git diff                                 # review every hunk
```

The script copies each path in `tools/chat_ui_manifest.txt` from
`<chuk_chat>/lib/<p>` to `app/lib/<p>` and rewrites `package:chuk_chat/` to
`package:chuk_chat/`. It is idempotent and exits non-zero if a manifest path no
longer exists upstream, so a file that moved is reported instead of silently
dropped. It warns when the manifest's pinned SHA and upstream HEAD differ —
update the `# upstream:` header after reviewing the diff.

Because every imported file is a byte-for-byte copy modulo the package prefix,
`git diff` after a re-sync is exactly upstream's change set. **Never hand-edit an
imported file.** If the chat UI needs to behave differently in Agents, change a
stub, not an import.

`platform_config.dart` is the one imported file with an append: after the copy
the script appends `tools/platform_config_agents_extras.dart.part`, which holds
the Agents-only feature flags (guarded by a `AGENTS-ONLY FEATURE FLAGS` marker so
a re-run does not duplicate them).

## Deliberate exclusions

These upstream files are in the transitive closure but are **not** imported. The
Agents file already in the tree wins.

| Upstream file | Decision | Reason |
|---|---|---|
| `lib/services/mcp/*` | keep Agents's | Agents's MCP is the source of truth (verbatim port + the OAuth work). The chat UI reaches `McpService`, `McpConnection`, `McpCatalogueEntry`, `mcp_availability` and `McpIconCache`; all five resolve against Agents's files unchanged. No member had to be added. `mcp_client.dart` is not referenced at all. `mcp_sync_service.dart` IS referenced by the verbatim `chat_sync_service.dart` (bead cowork-sha) and is a Agents stub (`pullAndReconcile` → no-op; owner cowork-47). |
| `lib/widgets/mcp_connect_card.dart` | keep Agents's | Agents's copy is already a verbatim port of the same widget with the identical public API (`McpConnectCard({required entry, required onConnected})`). It differs from upstream only in the page it pushes (`pages/settings/mcp_connectors_page.dart`, Agents's actively developed one) and one product-name string. Overwriting it would have dragged chuk's whole 896-line `pages/mcp_connectors_page.dart` in as a second, duplicate connectors page. |
| `lib/pages/mcp_connectors_page.dart` | not imported | Only reachable from `mcp_connect_card.dart`; falls out of the closure with the row above. |
| `lib/services/websocket_connector_io.dart` | keep Agents's | Agents's copy carries a deliberate local change: a 20 s protocol ping interval so a dead/half-open host surfaces as a normal close and drives auto-reconnect. That is a Agents-specific fix, not a lost upstream hunk, so it is kept. Full diff vs. upstream is exactly the `_kWsPingInterval` constant plus its two use sites. |

## Stub inventory

Every stub carries the fixed three-line header (`AGENTS STUB. Upstream: … @ <sha>.`
/ `Reason: …` / `Keep the public API signature-compatible …`) and mirrors the
upstream path. Stubs are derived from the upstream declarations with the bodies
emptied.

### Placeholders for P2b — the real work lands there

| File | Reason |
|---|---|
| `services/websocket_chat_service.dart` | replaced by relay — **the transport adapter**. Same class and static signature; body currently returns `Stream.error(UnimplementedError('P2b'))`. |
| `services/tool_call_handler.dart` | replaced by relay — **the fold**. `processAssistantResponse` always returns a final answer (`shouldContinue == false`), `nativeToolDefinitions` → `[]`, `buildInitialSystemPrompt` → `''`. The client tool loop is structurally unreachable. |
| `services/chat_storage_service.dart` | **no longer a stub** (bead cowork-sha): upstream's facade with recorded divergences — `saveChat`/`updateChat` → `AgentsChatStore.replaceThread`, `loadFullChat` memory-first, the three list loaders no-op with no Supabase client. Everything behind it (`chat_storage_crud/sync/mutations/sidebar`, `chat_preload_service`, `local_chat_cache_*`) is verbatim. See "Chat storage" below. |

### Replaced by relay (the host owns this)

| File | Reason |
|---|---|
| `services/streaming_chat_service.dart` | replaced by relay — SSE to the hosted API does not exist. Only `StreamingChatException` survives; three imported files type-test it. |
| `services/chat_sync_service.dart` | **no longer a stub** (bead cowork-sha): verbatim, polls `cowork_chats` every 30 s. Its `McpSyncService` import resolves to the stub above. |
| `services/streaming_foreground_service.dart` | replaced by relay — the run lives on the host and keeps going with no client attached, so the client needs no Android foreground service. Permanent no-op. |
| `services/offline_retry_manager.dart` | replaced by relay — no offline send queue. `instance` is inert. |
| `services/offline_send_coordinator.dart` | replaced by relay — `enqueue` is inert. `OfflineSendPayload` is kept verbatim (a plain value object the send logic builds). |
| `services/offline_queue_service.dart` | replaced by relay — not referenced by the closure; kept as a landing place so a re-sync never pulls the original in (sqflite is in the tree since cowork-sha, but the offline send queue is still relay-less). |

### Replaced by a Agents service

| File | Reason |
|---|---|
| `services/image_storage_service.dart` | **real, local.** Files under the app-support directory, addressed `cowork://blob/<id>`. Upstream used a Supabase bucket. This is where relayed files land. |
| `services/pdf_attachment_service.dart` | **real, local.** Delegates to the same blob store; upstream method names (`upload`, `download`, `delete`, `getCached`, …) unchanged. |
| `services/notification_service.dart` | no-op **during the import only**. WS-7/P7 replaces it with the real port (`flutter_local_notifications` + the host's desktop notifier), because a Agents run finishes while the app is closed. Do not build on this file. |
| `services/title_generation_service.dart` | pre-existing Agents stub, extended here with `generateAndApplyTitle(chatId, firstMessage)` → no-op. The sidebar row is the agent; its name is the user's. |

### Hosted-only (no Agents equivalent by design)

| File | Reason |
|---|---|
| `services/artifact_storage_service.dart` | hosted-only — encrypted artifact documents + version history live in Supabase upstream. Reads return empty, writes throw. |
| `services/artifact_context_service.dart` | hosted-only — the host builds the system prompt. Returns null. |
| `services/workspace_storage_service.dart` | hosted-only — workspaces (projects) are a chuk_chat feature. Permanently empty. |
| `services/workspace_message_service.dart` | hosted-only — ditto; returns empty context. |
| `services/file_conversion_service.dart` | hosted-only — the host reads files itself. Both entry points return upstream's failure shape. |
| `services/streaming_transcription_service.dart` | hosted-only — no transcription socket; voice mode is off. |
| `widgets/workspace_panel.dart` | hosted-only — `SizedBox.shrink()`. |
| `widgets/workspace_selection_dropdown.dart` | hosted-only — `SizedBox.shrink()`. |
| `widgets/workspace_file_viewer.dart` | hosted-only — `SizedBox.shrink()`; not referenced, kept as a landing place. |
| `widgets/credit_display.dart` | hosted-only — no credits; not referenced, kept as a landing place. |
| `pages/workspace_management_page.dart` | hosted-only — `ComingSoonPage`. |
| `pages/pricing_page.dart` | hosted-only — no subscription: the agent runs on the user's own machine. `ComingSoonPage`. |
| `pages/usage_details_page.dart` | hosted-only — `ComingSoonPage`; not referenced, kept as a landing place. |

## Overwrite decisions

- **`platform_config.dart` — overwritten, Agents flags re-added.** chuk's version
  adds `kFeatureMcp` and `kFeatureArtifactHosting`, which Agents lacked. The five
  Agents-only flags — `kFeatureAgents`, `kFeatureAgentsDemo`, `kFeatureSkills`,
  `kFeatureSpotify`, `kFeatureWhoop` — are re-added by the script from
  `tools/platform_config_agents_extras.dart.part`. All 16 `kFeature*` flags plus
  `kPlatformMobile`/`kPlatformDesktop`/`kAutoDetectPlatform` are present after the
  import; no flag was lost and no default value changed.
- **`utils/io_helper_stub.dart` — overwritten.** The only difference was a missing
  `File.delete({recursive})` on the web stub. Additive, no behaviour change on
  native.
- **`widgets/mcp_connect_card.dart` — NOT overwritten.** See "Deliberate
  exclusions".
- **`services/websocket_connector_io.dart` — NOT overwritten.** See "Deliberate
  exclusions".

## Allowed divergences

**Widget layer: NO LONGER NONE. Read this before you run the importer.**

This section used to say every file under `platform_specific/chat/`,
`widgets/`, `models/` and `utils/` was byte-identical to upstream modulo the
package prefix. That stopped being true. 41 imported files have diverged, and
eight of them are rendering widgets carrying roughly two thousand lines of
Agents work — none of it upstreamed, all of it visible to the user:

* `widgets/markdown_message.dart` — inline code keeps its monospace and its chip
  inside headings and quotes (upstream loses both, because a theme style with
  `inherit: false` swallows the merge); heading sizes are monotonic and follow
  the chat font size (upstream renders `####` SMALLER than `#####`); list
  markers take the bubble's colour; links are underlined in the accent and keep
  the surrounding size and weight.
* `widgets/chuk_table.dart` — a link in a cell is underlined and opens; a table
  wider than 560 px stacks into one card per row with every field labelled.
  Upstream has neither, and the coworker puts its sources in tables.
* `widgets/message_bubble/*` — the bubble is decided by its rendered body, so a
  turn that is only internal work does not leave a blank bar; `rich_blocks.dart`
  fixes a trailing-comma parser that upstream leaves writing a literal `$1` into
  the JSON and rendering an error card.
* `widgets/chart_widget.dart` — a tolerant parser with a provenance footer;
  upstream throws the whole message away on a colour it cannot read.
* Touch targets raised to 48 dp across the imported widgets, and the whole
  `ui/expressive/` motion vocabulary, which upstream does not have at all.

**Consequence:** `scripts/import_chat_ui.sh` would overwrite all of it in
silence. Before any re-sync, diff the manifest's widget entries against
upstream, decide file by file, and move anything worth keeping out of the
manifest first. Bead cowork-r6jy tracks pruning the manifest so the importer is
safe to run again.

Service layer, deliberate and recorded:

1. `ToolLoopSession` in the `tool_call_handler.dart` stub **drops the `enforcer`
   field**. Upstream's `ToolEnforcer` is part of the client tool loop and is not
   imported; no imported file reads `session.enforcer`.
2. `platform_config.dart` carries the appended Agents-only flag block described
   above.
3. `services/streaming_manager_io.dart` — carries a `FinalContentEvent` branch
   upstream does not have. An earlier version of this document claimed the file
   was untouched; it is not.
4. `services/chat_storage_service.dart` (bead cowork-sha): `saveChat` and
   `updateChat` delegate to `AgentsChatStore.replaceThread` (memory → SQLite →
   encrypted upsert on `cowork_chats`, best-effort) instead of upstream's
   INSERT/UPDATE, which refuse to run without a signed-in user and an unlocked
   key and refuse a row that exists (or does not) on the server. `loadFullChat`
   returns a fully loaded chat from memory before touching Supabase;
   `loadFromCache`, `loadChats`, `loadSavedChatsForSidebar` return at once when
   there is no Supabase client (a widget test). Every other member is upstream's.
4. The verbatim storage modules carry one mechanical rewrite made by
   `scripts/import_chat_ui.sh`: the table name `'encrypted_chats'` →
   `'cowork_chats'` (docs/SUPABASE_SCHEMA.md explains why).

If the escape hatch from the plan is ever needed (an additive `liveToolCalls`
stream on `streaming_manager_io.dart`, ~12 lines), it is the **only** widget-layer
divergence that is allowed, and it must be recorded here.

**P2b did NOT use the escape hatch.** `streaming_manager_io.dart` is untouched.
Live in-run tool narration rides the reasoning channel instead (see below), and
the finished tool timeline comes back through `ToolLoopResult`.

## P2b: how the adapter maps events

`services/websocket_chat_service.dart` is the transport adapter. Its static
signature is upstream's, so every imported call site binds unchanged; the body
is Agents's.

**One id everywhere.** `chatId` (the imported screen's `selectedChatId`) IS the
executor's `session_key` IS the local cache row id IS `AgentsThreadView.threadKey`.
A caller that passes no `chatId` falls back to `AgentsRelayLink.instance.sessionKey`.

**Ignored, by design:** `history`, `systemPrompt`, `maxTokens`, `temperature`,
`tools`. The host owns the session, the prompt and the tools. `images` are logged
and dropped — `sendTask` has no image channel yet.

| `AgentsRelayInbound` (live only) | `ChatStreamEvent` | `AgentsRunLedger` |
|---|---|---|
| `Delta` | `ContentEvent(text)` | — |
| `Reasoning` | `ReasoningEvent(text)` | `reasoning()` |
| `Tool` | verbose only: `ReasoningEvent("▸ name: args\n")` then `ReasoningEvent(" ✓ exit N\n"` / `" ✗ …\n")` | `openTool()` + `closeTool()` (the relay emits one event per completed command, so it is open+close in one step) |
| `Subagent` | — | `subagent()` → a `ToolCall(name:'subagent')` |
| `File` | — | `file()` → blob store FIRST, then a `sandboxArtifact` block |
| `ApprovalRequest` | — | `approval()` → a completed `ToolCall(name:'ask_user')` |
| `RunError` | `ErrorEvent(msg, code: streamFailure)` then `DoneEvent` | `finish(reason:'error')` |
| `Done` (live) | `MetaEvent{stop_reason, iterations}` → `UsageEvent{total_tokens}` → `DoneEvent` | `finish()`, then `sendRunAck(runId)` best-effort |
| `RunState` | — | `adoptRunning()` (via the replay loader) |
| `DebugContext` | — | `debugContext()`, for the copy button |
| `Room*`, `Browser*` | — | owned elsewhere |
| anything `replay == true`, and every `User` | — | the replay loader only |

**Invariants, each covered by a test in
`test/services/websocket_chat_service_test.dart`:**

- `ToolCallsEvent` is **never** emitted, for any inbound variant. That is the one
  thing keeping the client tool loop dead.
- A replayed frame never enters a live run's stream.
- File bytes are written to the blob store before the `sandboxArtifact` block
  exists.
- Cancelling the stream calls `requestStop(sessionKey)` exactly **once** — and
  never for a run that already reached its own terminal (Dart fires `onCancel`
  after a normal close too, so the adapter tracks that).

## P2b: the fold

`services/tool_call_handler.dart` `processAssistantResponse` takes the run from
`AgentsRunLedger.take(session.discoveryContextKey ?? link.sessionKey)` and returns
`ToolLoopResult.finalAnswer(...)` with `shouldContinue == false`, always. It fills
`session.toolCalls` and `session.producedBlocks` from the ledger, calls
`onToolCallsUpdated`, and finalises anything left running. The host's own
`final_answer` wins over the streamed deltas when it is non-empty; the streamed
reasoning buffer wins over the ledger's copy when it is longer (it is a superset:
the tool narration rides the same channel).

`nativeToolDefinitions` → `[]`, `buildInitialSystemPrompt` → `''`.

## P2b: history, the replay loader and the cache

`services/agents/agents_replay_loader.dart` is the ONLY consumer of replayed
frames. It folds them into the imported screen's own row shape and writes them
through `ChatStorageService.saveChat`, which since bead cowork-sha is chuk_chat's
storage (see "Chat storage" below): memory at once, the SQLite cache, then the
encrypted `cowork_chats` row. (P2b's interim JSON-file cache is gone.)

- Cursor: the highest `mid` per session, persisted under
  `cowork.replay_cursor.<sessionKey>`, sent back as `after_id`.
- A host that honours the cursor sends a delta, which is **appended**; a host that
  ignores it sends everything, which **replaces**. The two are told apart by the
  lowest `mid` in the answer, not by hope — so the same code is right against the
  old executor and the new one.
- `done` with `reason == 'replay'` is the history-end marker: it commits the
  cache and bumps a per-session **revision**.
- `done` with `replay == true` and a real reason closes the answer it belongs to;
  `while_away` raises an "Answer ready" flag (`answerReadyFor`).

**Repainting without touching an imported file.** The imported screen reads its
rows once, in `initState`, and does not listen to `ChatStorageService.changes`
(only the sidebar does). So `AgentsThreadView` keys the screen on
`'cowork-chat-<threadKey>-<revision>'`: a committed replay bumps the revision,
which remounts the screen off the fresh rows. The remount is deliberately
**deferred while a run is in flight** (`AgentsRunLedger.isRunning`), because
remounting mid-run would throw away the answer streaming into the screen.

## Chat storage (bead cowork-sha): SQLite + Supabase, like chuk_chat

The user's directive: Agents threads are stored exactly like chuk_chat chats —
in the local SQL database and in Supabase — and load instantly; the Python host
stays the source of truth on top.

**Imported verbatim** (manifest block "Chat storage"): `chat_storage_crud.dart`,
`chat_storage_sync.dart`, `chat_storage_mutations.dart`,
`chat_storage_sidebar.dart`, `chat_preload_service.dart`,
`chat_sync_service.dart`, `local_chat_cache_service.dart`,
`local_chat_cache_native.dart` (sqflite, gzip plaintext rows, does its own
`sqfliteFfiInit()` on Linux/Windows), `local_chat_cache_web.dart`. pubspec adds
`sqflite`, `sqflite_common_ffi`, `path`, `sqlite3_flutter_libs` at chuk_chat's
versions.

**Agents-owned** (`lib/services/storage/`):

- `agents_chat_store.dart` — the write path. `replaceThread(sessionKey, rows)`:
  memory synchronously (the caller may paint before awaiting), then the SQLite
  row through `LocalChatCacheService.upsert`, then `EncryptionService.encrypt`
  + `upsert` on `cowork_chats (user_id, id)`; writes per session are chained in
  order; the cloud step is skipped silently with no user or no key and its
  failure never surfaces. The server's `created_at`/`updated_at` are adopted
  so `ChatSyncService`'s "cloud newer?" check compares like with like. If the
  sync removes a thread locally (row gone on the server), the thread's replay
  cursor (`cowork.replay_cursor.<key>`) is dropped so the next open asks the
  host for the full thread. `loadThread` is memory-first, then upstream's
  cache-first `loadFullChat`.
- `agents_chat_storage_bootstrap.dart` — one auth-stream listener started
  from `main.dart`: on a session → `loadSavedChatsForSidebar()` (titles from
  the local cache, instant) then `ChatSyncService.start()` (30 s poll) and the
  cache migration; on sign-out → `stop()` + `reset()`. This is what
  `AppInitializationService` does in chuk_chat; Agents has no such service.

**What opens a thread now.** The imported screen calls `loadFullChat(threadKey)`
→ memory → SQLite → cloud. In parallel `AgentsThreadView` asks the host for a
replay from the persisted cursor; the host's delta is appended and stored
through the same path. The host stays the truth: a full replay (cursor 0, or a
host that ignores the cursor) replaces the local copy.

**Supabase.** Table `cowork_chats`, DDL in
`supabase/migrations/20260905000000_cowork_chats.sql`, contract in
`docs/SUPABASE_SCHEMA.md`. Not `encrypted_chats`: a session key is not a UUID,
and the two apps share one project.

**Tests.** `test/services/storage/agents_chat_store_test.dart` (10),
`agents_chat_storage_bootstrap_test.dart` (5); the P2b loader test still passes
against the new facade, with no Supabase client in the test.

## P2b: what `AgentsThreadView` is now

Constructor unchanged. The transport half is unchanged (bootstrap, controller
build/rebuild, pairing + connect bar, auto-reconnect with the watchdog,
provisioning, `run_ack`). The whole rendering half is gone; `build()` is the
connect bar when unpaired, else the imported screen:

```dart
ChukChatUIDesktop(          // or ChukChatUIMobile on a phone-sized mobile screen
  key: ValueKey('agents-chat-$threadKey-$revision'),
  onToggleSidebar: <no-op — the sidebar is the shell's Agents roster>,
  selectedChatId: threadKey,
  onChatIdChanged: <pins ChatStorageService.selectedChatId>,
  isSidebarExpanded: false,
  isCompactMode: false,                 // desktop only
  showReasoningTokens: _verbose,
  showModelInfo: shellConfig?.showModelInfo ?? _verbose,
  showTps: _verbose,
  showToolCalls: _verbose,
  toolCallingEnabled: false,
  toolDiscoveryMode: false,
  autoSendVoiceTranscription: shellConfig?.autoSendVoiceTranscription ?? false,
  onOpenModelSettings: onOpenModelScreen,   // desktop only
)
```

One deliberate deviation from "one socket, no disconnect on screen": a here.now
approval blocks the run on the executor, and the imported `ask_user` card is only
tappable once the turn is idle — which it never is while the run waits. So the
thread view keeps a standing approval bar above the chat that reuses the imported
`AskUserCard` with `['Publish', 'Deny']` and answers with `sendApprovalDecision`.
The ledger records the same request as a completed `ask_user` tool call, so the
transcript shows it after the run ends.

## P2b: notes for P3 (the shell)

- **The full-chat debug export moved** out of the view into
  `services/agents/chat_debug_export.dart`:
  `ChatDebugExport.build({required String threadKey}) → Future<Map<String, dynamic>>`,
  `ChatDebugExport.buildJson({required String threadKey}) → Future<String>` and
  `ChatDebugExport.copyToClipboard({required String threadKey}) → Future<String>`
  (returns the note to show: `'full chat copied'`, or `'copied the transcript'`
  for the plain-text fallback). It reads the transcript from the
  `ChatStorageService` cache and the raw model context from the ledger.
  `AgentsThreadViewState.copyFullChat()` is the thin delegate that keeps the
  action working from the view.
- `AgentsThreadView`'s state class is public (`AgentsThreadViewState`), so a
  `GlobalKey` can reach `copyFullChat()`.
- The view binds `AgentsRelayLink` itself (on controller build and on `paired`)
  and sets `link.sessionKey` on `paired` and on a `threadKey` change, so the shell
  needs no link wiring at all.
- `fileSaver` is now unused: a relayed file lands in the blob store and renders as
  the imported `sandboxArtifact` card, which has its own download action.

## P2b: test-harness notes

- The imported screens call `AppLocalizations.of(context)!`, so any widget test
  that can reach the chat UI must pump a `MaterialApp` with the app's
  localisation delegates. `test/support/test_app.dart` holds
  `kTestLocalizationsDelegates` / `testApp()` for that.
- A real send through the imported composer needs an initialised Supabase client
  and a signed-in session (`MessageCompositionService.prepareMessage` →
  `SupabaseService.refreshSession`). That is unreachable in a widget test, so the
  send path is asserted against `WebSocketChatService.sendStreamingChat` directly
  — the same call the composer makes.
- The imported screen schedules a 60 s multiplex idle-close timer when it is
  disposed. A test that remounts it mid-test must call
  `MultiplexSession.shutdown()` before the test ends.

## Handoff to P2b — upstream signatures the screens bind to

```dart
// services/websocket_chat_service.dart
static Stream<ChatStreamEvent> WebSocketChatService.sendStreamingChat({
  required String accessToken,
  required String message,
  required String modelId,
  required String providerSlug,
  List<Map<String, dynamic>>? history,   // IGNORED: the host owns history
  String? systemPrompt,                  // IGNORED: the host owns the prompt
  int maxTokens = 512,                   // IGNORED
  double temperature = 0.7,              // IGNORED
  List<String>? images,                  // v2: log + drop
  String? reasoningEffort,
  String? chatId,                        // == Agents sessionKey
  List<Map<String, dynamic>>? tools,     // IGNORED: the host owns tools
});

// services/tool_call_handler.dart
Future<ToolLoopResult> ToolCallHandler.processAssistantResponse({
  required ToolLoopSession session,
  required String content,
  required String reasoning,
  ToolTurnSignals? turnSignals,
  void Function(List<ToolCall>)? onToolCallsUpdated,
  List<NativeToolCall> nativeToolCalls = const <NativeToolCall>[],
});
// MUST keep returning ToolLoopResult.finalAnswer(...) — shouldContinue == false.
ToolLoopSession ToolCallHandler.createSession({
  required String initialUserMessage,
  required List<Map<String, dynamic>> history,
  required String accessToken,
  String? discoveryContextKey,           // == chatId, i.e. the sessionKey
  String? baseSystemPrompt,
  String? modelId,
  bool toolCallingEnabled = true,
  bool discoveryMode = true,
  bool skipIdentity = false,
  bool nativeToolCalling = false,
});
```

`ChatStorageService` members the imported screens actually call:
`selectedChatId` (+ `selectedChatIdNotifier`), `isMessageOperationInProgress`,
`activeMessageChatId`, `isLoadingChat`, `savedChats`, `getChatById`, `changes`,
`getChatTimestamps`, `initialSyncComplete`, `loadFullChat`, `loadFromCache`,
`loadChats`, `saveChat`, `updateChat`, `deleteChat`,
`loadSavedChatsForSidebar`, `syncTitlesFromNetwork`, `setChatStarred`,
`renameChat`, `reencryptChats`, `exportChats`, `exportChatsAsJson`,
`mergeSyncedChat`, `mergeSyncedChatsBatch`, `removeChatLocally`, `reset`.
The file also **re-exports** `models/chat_message.dart` (for `ChatMessage` and
`ChatMessageStatus`), `models/stored_chat.dart` (for `StoredChat`) and
`initChatStorageCache` — several imported files rely on that re-export instead of
importing the models directly. Do not drop it.

`ToolLoopSession.toolCalls` and `ToolLoopSession.producedBlocks` are the seams the
run ledger fills: fill them and MessageBubble's tool timeline, activity header and
artifact cards light up with no edit to any imported file.

## State at the end of P2a

`cd app && flutter analyze`: **0 errors**, 2 warnings, 2 infos — all four inside
verbatim-imported upstream files (`tool_image_result_service.dart`
`unawaited_return_in_try_block` ×2; `cacheExtent` deprecation in
`chat_ui_desktop.dart` / `chat_ui_mobile.dart` ×2). They are upstream's to fix,
not Agents's.
