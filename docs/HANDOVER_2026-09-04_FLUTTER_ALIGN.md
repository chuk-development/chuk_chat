# Handover 2026-09-04 — cowork = chuk_chat master, self-hosted backend

This file lets a fresh session continue with no context. Read it top to bottom.

## Read first

1. `docs/PRODUCT_PHILOSOPHY.md` — what the product is. The chat box. Result, not process.
2. `docs/PLAN_2026-09-04_COWORK_CHUK_ALIGN.md` — the approved plan (P0–P8), the
   design of every workstream, the file ownership, the conflicts and how they were
   resolved. The user approved it. Do not re-plan.
3. `docs/WIRE_CONTRACT.md` — the frames between the app and the Python executor
   (`run_state`, `mid`, `after_id`, `done.run_id/while_away`, `run_ack`).
4. `docs/CHAT_UI_IMPORT.md` — how the chuk_chat chat UI was imported (manifest,
   script, stubs, allowed divergences, the P2b handoff signatures).

## The directive (from the user, verbatim in spirit)

cowork IS chuk_chat master (`~/git/chuk_chat`, branch `master`). Same chat UI, same
settings, same model dropdown, same MCP connectors. Two differences only: a
different LEFT sidebar (agents, Control Rooms, Agent Browser) and the self-hosted
Python backend instead of the hosted API. The agent keeps running when the app is
closed; the user comes back and gets notified when the answer is ready. Import from
master verbatim; swap only the transport. Do not redesign anything.

User feedback after the first run of the imported UI: "it opens, it is perfect, it
looks exactly the same, we can work with this." Two follow-ups from that: (a) the
streaming must work live (P2b covers it: relay delta → `ContentEvent` → verbatim
`StreamingManager`); (b) scroll jumping while a bubble grows — fixed upstream in
chuk_chat by the coordinator's session, then re-imported here with
`scripts/import_chat_ui.sh`. Do not fix (b) in cowork directly.

## Phase status

| Phase | State | Evidence |
|---|---|---|
| P0 Foundations (constants, l10n, AppShellConfig, AppThemeService, Expressive kit, sidebar chrome, main.dart, pubspec deps) | DONE, green | full `flutter analyze` clean; roster 20, shell 13, thread_view 26, mcp_page 2, widget 3; `flutter build linux --debug` OK |
| P1 Relay client on the wire contract; `chat_stream_event.dart` + `multiplex_connection.dart` restored verbatim | DONE, green | relay_client test 33; the four widget test files green |
| P2a Chat-UI import: 100 files / 45,179 lines verbatim + 25 stubs, nothing mounted | DONE, green | full analyze 0 errors; the five test files green; build unverified (another session ran the app) |
| P2b Relay adapter, tool fold, run ledger, relay link, replay loader + cursor, local chat cache, `CoworkThreadView` body → `ChukChatUIDesktop/Mobile` | DONE, green (2026-09-05 ~01:40). Lib: full `flutter analyze` 0 errors; new unit tests green (websocket_chat_service 16, tool_call_handler_stub 7, cowork_run_ledger 14, cowork_replay_loader 12); widget harness fixed by cowork-5c (messenger_shell 15, cowork_thread_view 22, widget_test 3; no assertion weakened). Live streaming proof against the host: pending the app restart | bead `cowork-4y5` closed |
| P3 Shell: chuk root-wrapper layout, Agents sidebar on chuk chrome, right panel (rooms/browser), top-right 4 actions incl. Copy full chat, AppBar removed, `CoworkShellHost` hoisted above the desktop/mobile switch | NOT STARTED | bead `cowork-b6h` |
| P4 Settings (chuk `settings_page` + `desktop_settings_modal`, section map) and Model dropdown / `model_selector_page` verbatim | NOT STARTED | beads `cowork-jao`, `cowork-hxh` |
| P5 MCP OAuth on the device (Dart) + `mcp_client.py` refresh | NOT STARTED | beads `cowork-865`, `cowork-e8u` |
| P6 Run detachment (Python) | DONE, green, COMMITTED (e825fdb and later) | host 112, executor 69 (non-Docker), state 11, replay 5 |
| P7 Notifications — host side (Supabase row + Edge Function + `SupabaseNotifier` + desktop toast) | DONE, green, COMMITTED (50f114c) | test_notify 7, test_desktop_notify 7 |
| P7 Notifications — app side (local notifications port, FCM registration, tap → thread, `consumed_at`, replay cursor UI, detached phase, Answer-ready card) | NOT STARTED (cursor + replayed-done card are inside P2b's replay loader) | bead `cowork-o3j` |
| P8 Hardening + Opus-5 review pass over the whole Flutter side | NOT STARTED | bead `cowork-4wd` |

## What is where

Python (all committed on branch `cowork`):
- `agent/src/cowork_agent/state.py` — `runs` table, `replay_events(after_id)` + `mid`,
  `begin_run/finish_run/fail_run/run_terminals/mark_run_notified/mark_run_seen/sweep_orphan_runs`.
- `executor/src/cowork_executor/executor.py` — `rebind_codec`, `_codec_lock`,
  `_emit_lock`, `run_id`, `_accept_task` → `begin_run`, `_handle_replay` (cursor,
  `run_state` header, run terminals merged by `mid`), `run_ack`,
  `account_authentication` routed up, `_record_run`, hooks
  `on_run_finished/on_approval_pending/on_account_frame/on_run_ack`.
- `executor/src/cowork_executor/protocol.py` — `run_state_payload`, `run_ack_payload`,
  `replay_payload(after_id)`, `done_payload(run_id, while_away)`.
- `host/src/cowork_host/party.py` — a controller leaving does NOT stop the task
  server and does NOT clear the codec (that was a real race: a task sent right
  before the close was dropped); `send_result_frame` drops while no controller is
  attached; re-provision rebinds the codec and refreshes tokens in place.
- `host/src/cowork_host/serve.py` — `rebind`, hook pass-through.
- `host/src/cowork_host/host.py` — orphan-run sweep at start, `_on_reprovision`,
  `_on_run_finished` → `SupabaseNotifier`, `_user_id` from the token frame.
- `host/src/cowork_host/desktop_notify.py` — `notify-send`/`gdbus`/`osascript`, on a
  daemon thread (it must never block the task worker — that was the second real
  bug). Tests set `COWORK_DESKTOP_NOTIFY=0`.
- `host/src/cowork_host/notify.py` — `SupabaseNotifier`: row with the user's own
  token (`Prefer: resolution=ignore-duplicates`), then `functions/v1/notify-run`,
  401 → refresh once, bounded outbox flushed on re-provision, one per run, no
  answer content ever.
- `supabase/functions/notify-run/index.ts` — Edge Function (caller JWT, RLS, FCM v1,
  self-healing device tokens). Secrets `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT`.
- `docs/SUPABASE_SCHEMA.md` — every table with owner-only RLS, incl.
  `cowork_device_tokens`, `cowork_run_notifications`, `user_preferences`,
  `user_model_providers`, `cowork_pairings`, `cowork_mcp_connectors`.

Flutter (`app/`, ALL UNCOMMITTED — see below):
- `lib/main.dart` — chuk bootstrap: `AppThemeService`, `DynamicColorBuilder`, l10n
  delegates, `_buildShellConfig()`, `CoworkApp.shellConfig` static (TODO P3: thread
  it through `AuthGate` into the shell; bead `cowork-8y2`), legacy theme migration,
  `ThemeController` kept as a bridge until P4 deletes the old settings pages.
- `lib/services/cowork/cowork_relay_client.dart` — the ONE seam to the backend.
  `CoworkRelayController`: `sendTask/requestStop/requestReplay(afterId)/sendRunAck/...`;
  inbound sealed variants incl. `CoworkRelayRunState`, `CoworkRelayDone.runId/whileAway/isHistoryEnd`,
  `mid`. Another session (cowork-13) also edits it (VNC password, FIFO send chain).
  Read fresh before every edit.
- `lib/services/websocket_chat_service.dart` — THE ADAPTER (P2b): same signature as
  chuk's; maps relay events → `ChatStreamEvent`; never emits `ToolCallsEvent`.
- `lib/services/tool_call_handler.dart` — THE FOLD (P2b): `shouldContinue` always
  false; fills `toolCalls`/`producedBlocks` from the run ledger.
- `lib/services/cowork/cowork_relay_link.dart`, `cowork_run_ledger.dart`,
  `cowork_replay_loader.dart` — P2b.
- `lib/services/chat_storage_service.dart` — local instant-paint cache only (never
  authoritative; the server replays history).
- `lib/widgets/cowork_thread_view.dart` — keeps its public constructor and the
  pairing/reconnect lifecycle; body becomes `ChukChatUIDesktop`/`ChukChatUIMobile` (P2b).
- `lib/platform_specific/chat/**`, `lib/widgets/message_bubble*`, `streaming_manager*`,
  … — verbatim chuk files (see `tools/chat_ui_manifest.txt`). Never hand-edit; re-sync
  with `scripts/import_chat_ui.sh`.
- `lib/services/mcp/**` — cowork's MCP (54-server catalogue verbatim, `McpStore` with
  `forwardPayloads()`), the source of truth; P5 adds the device OAuth.
- `lib/pages/messenger_shell.dart`, `widgets/agent_roster_view.dart` — the shell,
  rewritten in P3.
- Kept on purpose, not overwritten: `services/websocket_connector_io.dart` (13's 20 s
  ping interval), `widgets/mcp_connect_card.dart` (cowork's port).

## Uncommitted state (this session's footprint)

Run `git status`. Everything under `app/**` (about 180 files: P0, P1, P2a, P2b work),
`app/linux/flutter/generated_plugin_registrant.cc` + `generated_plugins.cmake`
(regenerated by the pubspec change — commit them TOGETHER with `app/pubspec.yaml`),
`tools/chat_ui_manifest.txt`, `tools/platform_config_cowork_extras.dart.part`,
`scripts/import_chat_ui.sh`, `docs/PRODUCT_PHILOSOPHY.md`, `docs/CHAT_UI_IMPORT.md`,
`docs/PLAN_2026-09-04_COWORK_CHUK_ALIGN.md`, this file.

Commit policy: this session commits NOTHING until the user says so directly. The
coordinator session (cowork-b7) arranges the user's commit release. When it comes:
commit as `chukfinley <77645077+chukfinley@users.noreply.github.com>`, no
`Claude-Session:` links, no `Co-Authored-By` trailers, message describes the change
only. No branch switch, no worktree: three sessions share this working tree.

## P2b — what the test hang really is (diagnosed 2026-09-05)

`messenger_shell_test` mounts the thread view on a narrow window → the imported
`ChukChatUIMobile`. Two separate problems were found:

1. `AppLocalizations.of(context)!` was null because the test `MaterialApp` had no
   localization delegates. Fixed in `test/support/test_app.dart` (delegates +
   `supportedLocales`); every widget test pumps through that helper.
2. The remaining hang ("did not complete" after ~6:49 in 'an agent has one permanent
   thread and no way to open a second', MARKs reach "listen in the second turn") is
   an unresolved `await`, NOT an animation: the fake controller never emits a
   `CoworkRelayDone` after `sendTask`, so the adapter's stream
   (`websocket_chat_service.dart`) never closes and the imported send logic waits
   forever. Fix in the tests: after every simulated send, emit a `CoworkRelayDone`
   (`reason: 'finished'`, a `runId`), optionally a delta before it, then pump; make
   the fake's `requestReplay` complete at once (it is called on pair). Iterate with
   `flutter test <file> --timeout 60s --plain-name "<test>"` — a hang then fails in
   60 s instead of 7.5 min. Never edit the verbatim UI files for this.

## How P2b continues (if the subagent did not finish)

Check what exists: `cowork_relay_link.dart`, `cowork_run_ledger.dart`, the real
`websocket_chat_service.dart` and `tool_call_handler.dart`, `chat_storage_service.dart`
as a local cache were already written; `cowork_replay_loader.dart`, the
`cowork_thread_view.dart` rewrite, the two-line shell wiring and the new test files
(`test/services/websocket_chat_service_test.dart`,
`test/services/tool_call_handler_stub_test.dart`,
`test/services/cowork/cowork_run_ledger_test.dart`,
`test/services/cowork/cowork_replay_loader_test.dart`, rewritten
`test/widgets/cowork_thread_view_test.dart`) may be missing. The full P2b brief is
the "WS-6" section of the plan plus the "Handoff to P2b" section of
`docs/CHAT_UI_IMPORT.md`. Gate: full `flutter analyze` 0 errors; those test files
green one at a time; then a live run against the host (task streams, tool card,
file card, Stop, close app + reopen → replay with the finished run's card).

Live check: the running app belongs to another session (cowork-13, started with
flutter-hot). Do not hot-reload it yourself; ask the coordinator to restart it on
the new tree state.

## How P3 continues

Plan section "WS-1". Owner files: `lib/platform_specific/{root_wrapper*,sidebar_*}.dart`
(new, modelled on chuk's), `lib/pages/cowork_shell_state.dart` (new mixin
`CoworkShellHost`), `lib/pages/messenger_shell.dart`, `lib/widgets/agent_roster_view.dart`,
`lib/widgets/auth_gate.dart`. Do NOT edit `browser_view_page.dart` (cowork-13's) —
only embed it in the right panel. Top-right: Agent controls, Control Rooms, Agent's
browser, Copy full chat (chuk's own slot). Settings in the sidebar footer pill, Sign
out in the settings footer. Keep the single socket: the chat area is built once above
the desktop/mobile wrapper switch and kept in the tree (`Offstage`).

## STATE AT HANDOFF (2026-09-05 ~02:30) — read this first

**This session is finished.** It hands everything below to cowork-5c and cowork-47
(see "Final redistribution"). Its last verified state:

- **The imported chuk_chat UI runs live** in the app (pid 3150413 at the time):
  history, composer "Ask me anything!", Fast pill, mic, sidebar `cowork-host`, six
  top-right actions incl. Copy full chat. The send path works end to end
  (task → relay adapter → host); the last task came back as
  "Error: loop failed: SupabaseAuthError" — the stale host token, bead
  `cowork-c91`. Token-wise streaming is therefore NOT yet proven live; it is
  proven by the adapter unit tests and blocked only by c91's host side.
- **c91 app side is DONE and green** (`cowork_relay_client_test` 44/44):
  `AuthChangeEvent.tokenRefreshed` → immediate `account_authentication` (dedup on
  unchanged token; also while a task runs); host `reprovision_request` → answered
  with a (refreshed) session, always; host `account_session_rotated` → adopted via
  injectable adopter (default `supabase.auth.setSession(refresh_token)`), idempotent
  (a newer app session wins), always acked. `account_authentication` now carries
  `expires_at`. Files: `lib/services/cowork/cowork_relay_client.dart`,
  `lib/services/account_session.dart`, `lib/services/executor_provisioning.dart`,
  `test/services/cowork/cowork_relay_client_test.dart`, `docs/WIRE_CONTRACT.md`
  ("Token freshness"). Host side: cowork-49. Live repro (rotate the token, the task
  keeps running): cowork-47 + cowork-5c with 49.
- **THE TREE DOES NOT COMPILE RIGHT NOW (≈65 analyze errors)** — caused by the
  P4-rest subagent that died with HTTP 429 mid-way. It had copied these chuk pages
  VERBATIM into `app/lib/pages/` and had NOT adapted them yet (all UNTRACKED new
  files): `about_page.dart`, `account_settings_page.dart`, `customization_page.dart`,
  `desktop_settings_modal.dart`, `settings_page.dart`, `skills_settings_page.dart`,
  `system_prompt_page.dart`, `theme_page.dart`. Every error is inside them and comes
  from hosted-only chuk dependencies cowork does not have:
  `services/{user_status,profile,password_reset,password_change,key_version}_service.dart`,
  `services/onboarding_tour_controller.dart`, `pages/{tool_calling_settings,sandbox_management,
  diagnostics_settings,download_settings,recover_chats}_page.dart`, chuk's
  `pages/mcp_connectors_page.dart` path (cowork's is `pages/settings/mcp_connectors_page.dart`),
  `DeveloperOptionsPage` (cowork's is `pages/settings/developer_settings_page.dart`),
  plus methods the cowork stubs lack (`TitleGenerationService.isEnabled/getSystemPrompt/
  setSystemPrompt/setEnabled/resetSystemPrompt/hasCustomSystemPrompt/defaultSystemPrompt`,
  the `_SystemPromptPageState` soul/memory/user-info store calls).
  Two clean ways out, 5c decides: (a) finish the adaptation exactly per plan WS-2
  (hide pricing/sandboxes/tools/data&privacy/onboarding, point connectors at
  cowork's page, developer at cowork's page, strip credits/profile/password rows
  from account, strip title-generation rows from customization, make the
  system-prompt page use a small cowork store or drop it) — the eight files are the
  right starting point; or (b) to get green NOW, delete those eight untracked files
  (`git clean`-style; they were never committed, chuk still has them) and re-import
  later. Nothing else in the tree is red: before these files landed the full
  analyze was 0 errors, and cowork's old settings hub
  (`pages/settings/settings_page.dart`) is still intact and wired.
  `app/test/pages/settings/` is an untracked test dir from an earlier session
  (developer settings); harmless.
- `cowork-6v5`: "Encryption key is not available for the current user" at startup —
  chuk derives the EncryptionService key from the password at login; cowork restores
  the Supabase session without that step. Caught, not a crash. Decide in P4: key
  bootstrap like chuk or no-op system-prompt persistence (the host owns the prompt).
  Also affects `supabase_pairing_sync` / `mcp_connector_sync` (same key).

## Final redistribution (2026-09-05, coordinator cowork-b7)

- **cowork-5c**: P3 Shell (WS-1: root-wrapper layout, Agents sidebar on chuk
  chrome, right panel rooms/browser, top-right 4 actions — KEEP the Copy-full-chat
  button 5c already put in `messenger_shell.dart`, `CoworkShellHost` hoisted above
  the desktop/mobile switch, AppBar removed, bead `cowork-b6h`, `cowork-8y2`) and
  P4-rest Settings (WS-2 minus model selection; the eight half-imported pages above;
  bead `cowork-jao`, `cowork-tfp`, `cowork-6v5`). Plus the scroll fix `cowork-ejc`
  and the model selection (`cowork-hxh`) it already owns.
- **cowork-47**: P7 app side (WS-7 app: local notifications port from chuk's
  `notification_service_io.dart`, FCM registration prepared so only
  `google-services.json`/keys are missing, tap → thread, `consumed_at`, the
  "Answer ready" affordance is already in the replay loader; bead `cowork-o3j`,
  `cowork-kjl.5`) and P8 (hardening + the mandatory Opus-5 review pass over the
  whole Flutter side; bead `cowork-4wd`). Plus MCP OAuth (`cowork-865`,
  `cowork-e8u`, `cowork-dbw`) it already owns.
- **cowork-49**: c91 host side (`reprovision_request`, `account_session_rotated`
  pending/re-send until ack, in-place token swap) and everything Python.

## Redistribution (2026-09-04, late) — who owns what now

The user started two fresh sessions. The coordinator reassigned:

- **cowork-5c owns P4 Model Selection**: `lib/model_selector_page.dart`,
  `lib/widgets/model_selection_dropdown.dart`, `lib/widgets/chat_mode_selector.dart`,
  `lib/services/chat_mode_service.dart`, `lib/services/model_capabilities_service.dart`,
  `lib/services/model_cache_service.dart`, `lib/services/model_info_service.dart`,
  `lib/services/model_prefetch_service.dart`, `lib/services/per_model_system_prompt_service.dart`,
  `lib/widgets/per_model_system_prompt_sheet.dart`, `lib/pages/settings/model_settings_page.dart`
  (to be deleted), bead `cowork-hxh`.
- **cowork-47 owns P5 MCP OAuth**: `lib/services/mcp/**`, `lib/pages/settings/mcp_connectors_page.dart`,
  `lib/widgets/mcp_connect_card.dart`, `agent/src/cowork_agent/mcp_client.py`,
  beads `cowork-865`, `cowork-e8u`, `cowork-dbw`.
- **cowork-5c also, right now**: the top-right "Copy full chat" button in
  `lib/pages/messenger_shell.dart` (chuk's `root_wrapper_desktop` slot) wired to the
  debug export — P2b moves that export into
  `lib/services/cowork/chat_debug_export.dart` (public static API) so the button can
  call it; and the streaming scroll-jump fix (bead `cowork-ejc`, fixed in the
  imported chat files — re-sync policy applies). While 5c works there,
  `messenger_shell.dart` is off-limits for this session; P3 later moves the button
  into the root-wrapper layout, never removes it.
- **This session keeps**: P2b (thread view, `websocket_chat_service.dart`,
  `tool_call_handler.dart`, `cowork_run_ledger/relay_link/replay_loader.dart`,
  `chat_storage_service.dart`), P3 shell (`messenger_shell.dart`, root wrappers,
  sidebar, `cowork_shell_state.dart`, `auth_gate.dart`), P4-rest (settings page +
  desktop settings modal + section map WITHOUT the model page), P7 app side
  (notifications Dart), P8 review.

### Model-selection files — state for cowork-5c

| file | state |
|---|---|
| `lib/model_selector_page.dart` | VERBATIM chuk (imported in P2a); not yet reachable from a settings entry (P4-rest wires `showDesktopSettingsModal(initialSectionId: 'model')`) |
| `lib/widgets/model_selection_dropdown.dart` | VERBATIM chuk (P2a); the desktop composer's `_buildModelControlPill` in `chat_ui_desktop.dart` uses it |
| `lib/widgets/chat_mode_selector.dart`, `lib/services/chat_mode_service.dart`, `model_cache_service.dart`, `model_capabilities_service.dart`, `api_config_service*.dart` | byte-identical to chuk already (pre-existing) |
| `lib/services/model_info_service.dart` | cowork's own; loads `/v1/models_info` through the local relay (`ApiConfigService` already points there). Zero edits needed for the fetch path |
| `lib/services/model_prefetch_service.dart`, `per_model_system_prompt_service.dart`, `widgets/per_model_system_prompt_sheet.dart` | VERBATIM chuk (P2a) |
| `lib/services/user_preferences_service.dart`, `api_status_service.dart`, `core/model_selection_events.dart`, `models/chat_model.dart`, `tour_key_registry.dart` | VERBATIM chuk (P0). `UserPreferencesService` falls back to device-local when the Supabase tables (`user_preferences`, `user_model_providers`, DDL in `docs/SUPABASE_SCHEMA.md`) do not exist |
| `lib/pages/settings/model_settings_page.dart` | cowork-adapted, to be DELETED and replaced by `model_selector_page.dart`; `CoworkThreadView.onOpenModelScreen` re-points to the modal (desktop) / `ModelSelectorPage` (mobile) — same `VoidCallback` |
| Nice-to-have | serve `/health` on the relay so `ApiStatusService` stops showing "API unreachable" |

Coupling to keep stable (the thread view / adapter read them): `ChatModelChoice`,
`ChatModeService.{fallbackMode,defaultConfig,load,loadConfig,save,setModelForMode,setReasoningForMode,reasoningLevelsFor}`,
`ModeConfig`, `ModelInfoService.loadModels(accessToken:)`, `ModelCacheService.loadAvailableModels`,
`ModelSelectionDropdown` constructor + static `selectedModelNotifier`, `kAutoCheapestProviderSlug`.
The task frame fields are `model`, `provider`, `reasoning_effort` (no `fast_mode`).

### MCP files — state for cowork-47

| file | state |
|---|---|
| `lib/services/mcp/mcp_catalogue.dart` | VERBATIM chuk (54 built-in servers), ported earlier today |
| `lib/services/mcp/mcp_connection.dart`, `mcp_availability.dart`, `mcp_icon_cache.dart`, `mcp_support_dir*.dart` | ported from chuk, cowork-adapted where noted in the file headers |
| `lib/services/mcp/mcp_service.dart` | cowork-NATIVE facade with chuk's static surface (`connections`, `load`, `connect`, `connectByUrl`, `connectWithCredentials`, `disconnect`, `connectionFor`); does NO network and NO OAuth today — this is where chuk's `_authorize()` + `_launch/_closeBrowser` go |
| `lib/services/mcp/mcp_store.dart` | cowork's: SharedPreferences config + secure-storage secrets; `forwardPayloads()` → `[{name,url,auth,access_token?}]` rides `sendTask` as `mcp_servers`. P5 turns the secret into chuk's full record (`mcp_secrets_<id>`) and adds the `oauth` forward block (contract in the plan, WS-4) |
| `lib/services/mcp/mcp_connector_sync.dart` | cowork's encrypted Supabase mirror (one blob per user, like `supabase_pairing_sync.dart`); P5 mirrors the full record |
| `lib/services/mcp/mcp_oauth.dart`, `mcp_redirect.dart`, `mcp_redirect_io.dart`, `mcp_redirect_stub.dart` | MISSING — port VERBATIM from chuk (edit only `clientName='CoWork'`, `clientUri`, the redirect page copy) |
| `lib/services/mcp/mcp_client.dart`, `mcp_sync_service.dart` | NOT imported, NOT referenced by the imported chat UI; do not port (no device-side MCP client by design) |
| `lib/pages/settings/mcp_connectors_page.dart` | chuk's page verbatim + a dialog-lifecycle fix (`_AddByUrlDialog`); the connectors UI is done |
| `lib/widgets/mcp_connect_card.dart` | cowork's verbatim port (points at cowork's connectors page); mounting it into the thread view is bead `cowork-dbw` |
| `agent/src/cowork_agent/mcp_client.py` | Python: `configs_from_entries` must keep an OAuth entry that has `oauth.refresh_token`; add `refresh_access_token`; `_http_headers` precedence; reconnect on 401. `executor.py::_session_mcp_manager` must hash a redacted projection (drop `access_token`, `oauth.expires_at`, `oauth.refresh_token`) — that hunk is in executor.py, coordinate with cowork-49 |

Known bug this fixes: the ~50 OAuth catalogue connectors show in the UI but never
authenticate, because nothing initiates the OAuth flow today.

## The one file that runs ahead of the pin (cowork-ejc, 2026-09-05)

`tools/chat_ui_manifest.txt` pins the import to chuk_chat `d31526a`. One file in
`app/lib` is now **newer than that pin**:
`platform_specific/chat/chat_scroll_mixin.dart`.

The streaming scroll jumped: a reader who scrolled up during a streaming answer
was dragged back to the bottom by the next token. The cause was in the mixin,
not in the screens — sticky-bottom was decided by distance alone (unstick above
100px, re-stick below 8px), and a growing message fires `onScrollChanged` on
every frame, so a 50px scroll-up stayed inside the "sticky" band and
`pinToBottomDuringStream` jumped back. The fix reads intent instead of distance:
`position.userScrollDirection == ScrollDirection.forward` unsticks immediately at
any distance, `distanceToBottom < 8` is checked first so a fling all the way down
re-arms, and `pinToBottomDuringStream` bails on `forward` as a second guard for
the cases `isScrollingNotifier` misses (between a drag ending and its ballistic,
and a mouse-wheel tick, which never opens a scroll activity). `chat_ui_desktop`
and `chat_ui_mobile` are untouched.

The fix was made **in chuk_chat master first** (the origin of the verbatim UI)
and is **uncommitted there** — the user commits it in that repo. There is
therefore no new upstream SHA yet, so:

- the manifest's `# upstream:` header stays at `d31526a`,
- the manifest carries a comment line at that path saying it runs ahead,
- a full `scripts/import_chat_ui.sh` run is safe **as long as chuk_chat still
  holds the fix in its working tree**: the CoWork copy is byte-identical to
  chuk's modulo the package prefix, so the script rewrites it with the same
  bytes. If chuk_chat is ever reset without committing the fix, a re-sync WOULD
  drop it. Lift the pin (and delete the comment) once the user commits upstream.

The test came along, deliberately, so CoWork guards the behaviour itself:
`app/test/platform_specific/chat/chat_scroll_mixin_test.dart` (4 cases: pinned
at the end during streaming; a 60px pull towards history survives five more
tokens; a single mouse-wheel tick does too; scrolling back to the end re-arms).
Verified causal — on the pre-fix mixin the two regression cases fail and the two
"still works" cases pass.

### `scripts/import_chat_ui.sh` needed a fix to run at all

With `CDPATH` set in the environment (it is, on this machine), `cd` echoes the
directory it lands in, so `REPO_ROOT="$(cd … && pwd)"` captured two lines and
every path was malformed ("manifest not found"). It now uses
`CDPATH= cd -- …`. Nothing else about the script changed.

## P4-rest: what the section map decided (cowork-5c, 2026-09-05)

The eight chuk settings pages the dead subagent left behind were parked in
`_p4_pending/` at the REPO ROOT (not under `app/`: inside the Dart package
`flutter analyze` walks them regardless of `.gitignore`, and their ~65
unresolved references would keep the tree red). Only eight of the thirteen
untracked files in `app/lib/pages/` belonged there — `coming_soon_page`,
`fullscreen_map_page`, `pricing_page`, `usage_details_page` and
`workspace_management_page` are P2a import artifacts that the imported chat UI
actually references (`chat_ui_helpers`, `map_block_renderer`, `chat_ui_desktop`,
`mobile_workspace_handler`), so moving them would have broken the build instead
of fixing it.

Outcome per page:

| page | decision |
|---|---|
| `theme_page.dart` | verbatim, **zero** changes needed (analyze clean as imported) |
| `about_page.dart` | verbatim, zero changes needed |
| `skills_settings_page.dart` | verbatim, zero changes needed |
| `customization_page.dart` | adapted: Downloads section and the whole auto-chat-title block (`TitleGenerationService` state, loaders, save/reset, prompt editor) removed; a CoWork "Detail" section with the `VerboseService` full-log switch takes their place |
| `account_settings_page.dart` | **chuk's version discarded, not adapted.** It is 780 lines over `ProfileService`, `PasswordChangeService`, `PasswordResetService`, `KeyVersionService` and `RecoverChatsPage`, none of which exist here. CoWork's own 67-line page already does the right thing (who is signed in, and the way out) and was moved to `pages/account_settings_page.dart` per the plan |
| `system_prompt_page.dart` | **dropped.** It needs `loadSoulText` / `saveSoulText` / `isIdentityEnabled` from chuk's `tool_handlers/notes_tools.dart`. The host owns the system prompt (docs/PRODUCT_PHILOSOPHY.md), so a CoWork-side store would be a second source of truth. Coordinator decision, 2026-09-05 |
| `settings_page.dart` | adapted (1155 → 602 lines): hidden are pricing, identity, tool calling, sandboxes, Data & Privacy/export and the onboarding replay; connectors and developer point at CoWork's own pages; a new "CoWork" section carries here.now and Embedding; footer wordmark is CoWork |
| `desktop_settings_modal.dart` | adapted (794 → 662): same section map in the rail's destination table, same ids (`model` is still the id `showDesktopSettingsModal(initialSectionId: 'model')` targets), the two hosted-only `onAction` destinations (export, onboarding) removed |

The two hubs are written but still in `_p4_pending/` — they land in `app/lib/pages/`
together with the deletion of CoWork's old `pages/settings/settings_page.dart`,
which is a single change that needs a compiler window to verify.

### `cowork-6v5`: the key is derived at sign-in

`login_page.dart` now calls `EncryptionService.initializeForPassword(password)`
right after a successful `signInWithPassword`, exactly as chuk_chat does at its
own sign-in. A failure there is surfaced, not swallowed — being signed in with no
key is the bug this fixes. **Limitation to know:** the derived key is stored
locally, so a restored session on the SAME device works, but a fresh install that
restores a Supabase session without the user typing their password again has no
key until they sign in once. Everything that needs it (`UserPreferencesService`
system prompt, `supabase_pairing_sync`, `mcp_connector_sync`) already falls back
to `EncryptionService.tryLoadKey()` and degrades quietly.

### `flutter-hot` can wedge: use `kill`, not `stop`

`flutter-hot reload` and `flutter-hot stop` both write a key into the control
FIFO. That write can block forever — seen on 2026-09-05: `flutter-hot result`
sat at `pending` for 300+ seconds, the app log never printed "Performing hot
reload", and the process was healthy the whole time. `flutter-hot send r` hung
the same way. The way out is `flutter-hot kill`, which goes straight for the pid;
after that a normal `start` works. Screenshots on this machine also need
`gnome-screenshot` plus an ImageMagick crop, never `flutter-hot shot`: the
session is Wayland, so `xdotool`/`wmctrl`/`import` cannot see the window at all
(`grim` fails with "compositor doesn't support wlr-screencopy-unstable-v1" and
the GNOME screenshot D-Bus method answers "Screenshot is not allowed"). Delete
the full-screen capture after cropping — it contains every other session's
terminal.

## Open beads (bd ready / bd show <id>)

`cowork-4y5` P2 (in progress) · `cowork-b6h` P3 · `cowork-jao` P4 settings ·
`cowork-hxh` P4 dropdown · `cowork-865` P5 OAuth Dart · `cowork-e8u` P5 Python ·
`cowork-o3j` P7 app side · `cowork-4wd` P8 review · `cowork-8y2` thread shellConfig
through AuthGate (P3) · `cowork-tfp` settings_page_test red (pre-existing, P4) ·
`cowork-dbw` mount mcp_connect_card (P3/P4) · `cowork-c91` stale host token (server
side done in P6; app must re-send the token on `AuthChangeEvent.tokenRefreshed`, P7) ·
`cowork-kjl.5` approval push (P7, child of `cowork-o3j`) · `cowork-15s`, `cowork-hp2`
handed to cowork-49.

## Rules (all sessions)

- Subagents: Opus 5 only (`model: opus`), one at a time, self-managed. On HTTP 429
  wait 60 s and retry; report the exact message to the coordinator.
- RAM ~2 GB free, memguard kills > 6 GB: no `flutter test` while a subagent or a
  build runs; tests one file at a time; scoped analyze while iterating, one full
  analyze at a gate; never the whole suite at once.
- File ownership (this session): `app/lib` + `app/test` EXCEPT
  `app/lib/widgets/browser_view_page.dart`, `app/third_party/**`,
  `app/analysis_options.yaml` (cowork-13); `app/pubspec.yaml` shared — append only,
  read fresh; Python: `agent/.../mcp_client.py`, `state.py`, my hunks in
  `executor.py`/`protocol.py`, `host/*` run-ownership + notify. NOT mine: `loop.py`,
  `model.py`, `backend.py`, `runtime.py`, `registry.py`, the executor tool-call path,
  `_VncBridge`/`_RfbClientFramer`/`_vnc_*`.
- Coordinator: session `cowork-b7` (address the `uds:` socket it writes from).
  Report after every phase: phase done, tests green, next phase. Answer status polls
  in 3–5 lines. Never report green what you did not see.
- The user's global rules: answer in German, terse; code comments in ASD-STE100
  English; no memories, no artifacts, no scratchpad — everything in the repo; no
  screenshots unless asked; do not hot-reload an app you did not start.

## Definition of done (from the philosophy)

The user typed one thing and closed the app. Later, ONE notification: "your answer
is ready". Tap → the coworker's thread with the finished result, replayed from the
server. No command, no error, no excuse (unless the full-log toggle is on). Delete
the app, reinstall on another phone, sign in — everything is still there.
