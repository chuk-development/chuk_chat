# Plan: agents = chuk_chat master, self-hosted backend

## Context

agents is a fork of chuk_chat. Over time its chat UI, settings, and model selector
were re-implemented instead of kept in sync with the original. The user's directive
is unambiguous:

> It is EXACTLY the same app as chuk_chat master. Same chat UI, same settings, same
> model dropdown, same MCP connectors, same conference/rooms handling. Only two
> differences: (1) a different LEFT sidebar with cowork-only functions (Agents,
> Control Rooms, Agent Browser), and (2) instead of calling the hosted API for a
> model response it calls the self-hosted agents Python backend.

The backend keeps running when the app is closed. The user gives a task, closes
the app, and comes back to the finished answer, with a push notification when the
agent is done. Full history replays from the server (source of truth).

Recent work went wrong by re-styling a from-scratch chat view to "look like
ChatGPT" and by adapting the model selector, instead of importing chuk_chat's
actual code. This plan fixes the approach: **import from master verbatim, swap only
the transport seam.** Pattern already proven for MCP (54 connectors ported
verbatim) and the composer mode picker.

Rule for every ported file: copy chuk_chat master's file, rewrite
`package:chuk_chat/` → `package:chuk_chat/`, and change ONLY the line(s) that call
the hosted API. Nothing else is redesigned.

## The one integration seam (from the agents exploration)

agents does not talk HTTP. It opens one end-to-end-encrypted WebSocket to the
local Python host (`ws://127.0.0.1:8787`) via `AgentsRelayClient`, behind the
`AgentsRelayController` interface in
`app/lib/services/agents/agents_relay_client.dart`.

Where chuk_chat's `ChatApiService` POSTs to the hosted API and streams the reply,
agents must instead:

- send: `controller.sendTask(prompt, sessionKey: threadKey, modelId:, providerSlug:,
  reasoningEffort:, debug:)` — the frame also carries `mcp_servers` (from
  `McpStore.forwardPayloads()`) and `herenow`, injected in the client constructor.
- receive: fold `controller.inbound` (`Stream<AgentsRelayInbound>`) into the chat's
  message model. The 15 inbound variants and the mapping to message entries are in
  `agents_thread_view.dart` `_onInbound` (lines ~494–577) — this is the reference:

| Relay event | becomes |
|---|---|
| `AgentsRelayDelta` (text, replay) | assistant answer token → accumulate in current assistant message |
| `AgentsRelayReasoning` (text) | reasoning/thinking block (process detail) |
| `AgentsRelayTool` (name, status, arguments, result, exitCode, failed, timedOut, duration, replay) | tool-call line (process detail) |
| `AgentsRelayFile` (name, mimeType, bytes, error) | file/attachment card |
| `AgentsRelaySubagent` (id, title, state, result, error) | subagent row, updated in place |
| `AgentsRelayUser` (text, replay=true) | user turn — only from server replay |
| `AgentsRelayDone` (finalAnswer, reason, iterations, tokensSpent, replay) | end of run; a replay `done` ends history only, not a run |
| `AgentsRelayRunError` (message) | error entry |
| `AgentsRelayApprovalRequest` | "publish to web?" card with decide buttons |
| `AgentsRelayDebugContext` | not rendered; kept for debug copy |
| Room* / Browser* | ignored in the agent thread (Rooms page / Browser page own them) |

- stop: `controller.requestStop(sessionKey)`.
- history: `controller.requestReplay(sessionKey)` once on pair when the local log is
  empty; replayed events carry `replay: true`.

## What must stay stable (cowork-only, lives in `messenger_shell.dart`)

`AgentsThreadView` public constructor is what the shell drives; keep it:
`controllerBuilder`, `sessionSource`, `pairingStore`, `defaultHostUrl`, `threadKey`,
`fileSaver`, `onRunStateChanged`, `onActivity`, `onPaired`, `onController`,
`onOpenModelScreen`. The view owns the controller lifecycle (bootstrap, pairing,
auto-reconnect with backoff + watchdog, replay-on-empty).

cowork-only features that are NOT in chuk_chat and must be preserved as-is:
- Agents roster + left sidebar (`agent_roster_view.dart`, `agent_roster_source.dart`),
  one session per agent (`threadKey` == executor `session_key`).
- Control Rooms (`room_thread_page.dart`, `room_source.dart`, over the shared socket).
- Agent Browser (`browser_view_page.dart`, RFB over `browser_data` frames).
- Pairing / reconnect-anywhere (Supabase-encrypted pairing restore).
- App-bar actions: agent controls, Rooms, Agent's browser, Settings, Sign out.

## Already ported verbatim from chuk_chat (keep, do not redo)

- MCP: `services/mcp/*` + `mcp_connectors_page.dart` — 54-server catalogue verbatim,
  UI verbatim, `McpStore.forwardPayloads()` rides `sendTask` as `mcp_servers`.
- Composer mode picker: `widgets/chat_mode_selector.dart`, `chat_mode_service.dart`
  (Fast/Thinking/Custom) — wired to `sendTask`.

NOTE: the model-selection *dropdown* (`model_selection_dropdown.dart`) and the
`model_selector_page.dart` were NOT ported (adapted instead). The user wants them
from master too. See the design sections below.

## What chuk_chat master actually is (from the chuk_chat explorations)

- **State:** Riverpod (`ProviderScope`) + static singleton services with `ValueNotifier`s.
  agents has NO Riverpod today (plain `ValueNotifier`/`setState`). To import the chat
  runtime verbatim, agents adds `flutter_riverpod` and wraps in `ProviderScope`.
- **Shell layout (no AppBar):** `lib/platform_specific/root_wrapper_desktop.dart`
  (`RootWrapperDesktop`) = `Scaffold > Stack`: chat area (`ChukChatUIDesktop`) + a
  320px left sidebar overlay + optional right panel (Workspaces/Media/Artifacts) +
  **floating positioned icon buttons**. Top-left: hamburger + mini-rail (New chat,
  Workspaces, Media). **Top-right: one button, `Icons.copy_all_rounded` "Copy full
  chat" → `_copyDebugChat()`** (~L799). Mobile: `root_wrapper_mobile.dart`, floating
  top bar (~L472–549): menu chip, title pill, top-right copy-chat + New Chat.
  → This top-right slot is where agents puts its own actions (Agents, Control
  Rooms, Agent Browser, chat debug-copy). Nothing is invented; the slot exists.
- **Left sidebar** = chat history (`sidebar_desktop.dart` `SidebarDesktop`,
  `sidebar_mobile.dart`; chrome in `widgets/sidebar/sidebar_chrome.dart`). In agents
  this becomes the **Agents** sidebar (the one deliberate difference).
- **Settings — two surfaces, same pages:** mobile `lib/pages/settings_page.dart`
  (`SettingsPage(AppShellConfig)`), desktop `lib/pages/desktop_settings_modal.dart`
  (`showDesktopSettingsModal`: 268px nav rail + content pane, search, log-out footer).
  Widget kit to import verbatim: `lib/widgets/expressive_settings.dart`
  (`ExpressiveGroup/Row/Tile/SwitchRow/Card/SectionHeader/…`) + `settings_list_view.dart`.
  Sections: Account (account, pricing), AI & Chat (Model selection →
  `lib/model_selector_page.dart`, AI identity/system prompt, Tool calling,
  Connectors, Skills, Sandboxes), Appearance (Theme, Customization), Data &
  Privacy, System (About, Developer). `AppShellConfig`
  (`lib/models/app_shell_config.dart`) is the prop bag threaded through all of it,
  built from `AppThemeService.instance`.
- **Model selector:** `lib/widgets/model_selection_dropdown.dart` +
  `lib/model_selector_page.dart` (2095 lines) + per-model system prompts
  (`per_model_system_prompt_service.dart` + `_sheet.dart`), backed by
  `user_preferences_service` (encrypted Supabase prefs) and `api_status_service`.
- **MCP OAuth runs ON THE DEVICE:** `lib/services/mcp/mcp_oauth.dart` (`McpOAuth`) +
  `mcp_redirect_io.dart` (one-shot loopback `HttpServer` on `127.0.0.1:<port>` →
  `/mcp/callback`) orchestrated by `McpService._authorize()`: probe 401 → RFC 9728
  resource metadata → RFC 8414 server metadata → RFC 7591 dynamic client
  registration (`client_name: 'Chuk Chat'`) → PKCE auth-code + `resource` → open
  browser (`launchUrl` in-app view) → catch loopback redirect → exchange →
  `McpTokens{accessToken, refreshToken?, expiresAt?}` → **secure storage**
  `mcp_secrets_<id>`. Refresh transparently before each use. Cross-device via
  `mcp_sync_service.dart` (AES-256-GCM blob in Supabase).
  → agents's recent MCP port moved OAuth "host-side" and nothing initiates it, so
  the 50 OAuth connectors show but never authenticate. **Fix: port the device
  OAuth verbatim**, and forward the token to the Python backend.
- **Rooms / conference: does not exist in chuk_chat.** agents's Control Rooms are
  net-new and stay exactly as they are.
- **Entry:** `main.dart` → `ProviderScope(ChukChatApp)` → `MaterialApp` → `AuthGate`
  → `RootWrapper(config)`. Imperative `Navigator.push` everywhere, no router.

## The chat UI and its ONE seam (from the chuk_chat chat exploration)

chuk_chat's whole chat UI is transport-agnostic above a single boundary:
**`Stream<ChatStreamEvent>`** (`lib/models/chat_stream_event.dart`): `ContentEvent(text)`,
`ReasoningEvent(text)`, `ToolCallsEvent(List<NativeToolCall>)`, `UsageEvent`, `MetaEvent`,
`TpsEvent`, `ErrorEvent(message, code)`, `DoneEvent`. The `StreamingManager` singleton
(`lib/services/streaming_manager_io.dart`) reduces that stream into the message being
rendered (coalesced ~33ms flush) and calls back `onUpdate/onComplete/onError`.

What PRODUCES the stream is the transport, and that is the only thing that changes:
- `WebSocketChatService.sendStreamingChat({message, modelId, providerSlug, history,
  systemPrompt, maxTokens, temperature, images, reasoningEffort, chatId, tools})`
  (`lib/services/websocket_chat_service.dart`) → rides `MultiplexConnection`
  (`lib/services/multiplex_connection.dart`: frames `{req_id, type:"chat", payload}` out,
  `{req_id, kind: content|reasoning|usage|meta|tps|tool_calls|error|done, data}` in).
- Callers: `platform_specific/chat/desktop_send_logic.dart` (~L1641),
  `chat/handlers/streaming_message_handler.dart` (~L544), `title_generation_service.dart`,
  `offline_send_executor.dart`. All feed `StreamingManager.startStream`.
- NOTE: `chat_api_service.dart` is NOT the chat transport (file convert + transcribe only).

Screens and renderer to import verbatim:
- `lib/platform_specific/chat/chat_ui_desktop.dart` (`ChukChatUIDesktop`, 3204 lines; plain
  `setState` + `StreamingManager`; `_messages` is `List<Map<String,String>>`; message list
  `ListView.builder` → `MessageBubble`; composer `_buildSearchBar`; model control pill
  `_buildModelControlPill` merges reasoning toggle + `ModelSelectionDropdown`).
- `chat_ui_mobile.dart` (4449 lines), mixins `desktop_send_logic.dart`,
  `chat_ui_helpers.dart`, `chat_scroll_mixin.dart`, `model_provider_resolution_mixin.dart`,
  handlers under `chat/handlers/`, `widgets/fullscreen_composer.dart`,
  `attachment_preview_bar.dart`, `markdown_message.dart`, `anchored_menu.dart`.
- `lib/widgets/message_bubble.dart` + parts in `lib/widgets/message_bubble/` (layout =
  user/ai split, chrome = action bar + variant pager, tools = reasoning block + tool
  section + activity timeline, rich_blocks, cards, images, web_search_sources, models).
  `MessageBubble` takes `toolCalls: List<ToolCall>` (completed calls with results),
  `contentBlocks`, `attachments`, `reasoning`, `status`, `onAskUserAnswer`, …
- Persistence model `lib/models/chat_message.dart`.

### The architectural difference the adapter must respect
chuk_chat runs a **client-side tool loop**: the model returns `tool_calls`, the client
executes them (`ToolCallHandler.processAssistantResponse`) and sends results back.
agents runs the agent **server-side**: the Python agent executes tools autonomously and
streams progress. So `AgentsRelayTool` means "the server ran this tool, here is the
result", never "client, please run this". The adapter must therefore NEVER emit
`ToolCallsEvent` (that would start the client loop). Completed server tool runs,
subagents and files are rendered through `MessageBubble`'s existing tool-section /
activity-timeline / attachments inputs instead. The server also holds the session
history, so chuk_chat's `history[]` is ignored (server-side session) and the local
message list is rebuilt from `requestReplay`.

## Coordination constraints (three sessions share this working tree)

Sessions: this one (Flutter/UI parity), cowork-49 (Python/Agent parity: native
OpenAI tool calls, `<tool_call>` parsing removed), cowork-13 (VNC/browser), and
coordinator cowork-b7. Agreed rules:

- **Ownership.** Mine: everything under `app/lib` and `app/test` EXCEPT
  `app/lib/widgets/browser_view_page.dart`, `app/third_party/**`,
  `app/analysis_options.yaml` (cowork-13). Also mine: `agent/src/chuk_agents_runtime/mcp_client.py`,
  `state.py`, `prompt.py` hunks, executor replay hunks, `docs/PRODUCT_PHILOSOPHY.md`,
  `docs/SUPABASE_SCHEMA.md`. NOT mine: `loop.py`, `model.py`, `backend.py`, `runtime.py`,
  `registry.py` (cowork-49).
- **`app/pubspec.yaml` is shared:** only append lines, never reformat, read fresh
  before every edit.
- **Executor sequencing:** cowork-49 finishes the tool-call migration and commits
  `executor.py` first; Run-Detachment is NOT touched until cowork-b7 explicitly
  releases it. cowork-49 builds on my `prompt.py` (quiet) and `executor.py`
  (`_handle_replay`) hunks; they commit those two files as a snapshot including my
  hunks (reported green). All my other files are committed only by me, only on a
  direct instruction from the user.
- **Subagents:** Opus 5 only (`model: opus`), self-managed. A final Opus-5 review
  pass over the whole Flutter side before calling it done.
- **RAM (~2 GB free, memguard kills the largest process):** build subagents run
  ONE AT A TIME, never in parallel. No `flutter test` while a subagent runs. Tests
  one file at a time (`flutter test <file>`), never the whole suite at once.
  `flutter analyze` scoped to the touched files during a step; one full analyze
  only at a phase gate.
- **MCP-OAuth design approved by the coordinator:** device-side OAuth verbatim
  from chuk_chat + forward access/refresh token, token endpoint, client id to the
  Python backend so it refreshes on its own while the app is closed.

---

# DESIGN

Good news found while planning: agents already holds **byte-identical** copies (modulo
package name) of `chat_mode_service.dart`, `chat_mode_selector.dart`,
`model_cache_service.dart`, `model_capabilities_service.dart`, `api_config_service.dart`,
`network_status_service.dart`, `supabase_service.dart`, `encryption_service.dart`, and
`mcp_connectors_page.dart` differs only by a dialog-lifecycle fix. The port is smaller
than it looks; the work is in the chat UI, the shell, settings and OAuth.

## WS-0 — Foundations (BLOCKING, one owner, runs alone first)

Import verbatim (`package:chuk_chat/` → `package:chuk_chat/`, no other edits):
- `lib/constants.dart` (`kTopInitialSpacing`, `kMenuButtonHeight`, `kButtonVisualHeight`,
  `kFixedLeftPadding`, `kCompactModeBreakpoint`, every `kDefault*`), `lib/utils/color_extensions.dart`,
  `lib/utils/chat_font_resolver.dart`, `lib/theme/theme_presets.dart`.
- `lib/l10n/*` (6 files, const strings; rebrand "Chuk" strings; exclude from lints if noisy).
- `lib/models/app_shell_config.dart`, `lib/models/chat_model.dart`, `lib/core/model_selection_events.dart`.
- Services: `app_theme_service`, `theme_settings_service`, `customization_preferences_service`,
  `settings_sync_service`, `developer_options_service`, `tour_key_registry`, `api_status_service`,
  `user_preferences_service`, `diagnostics_log_service{,_io,_stub}`.
- Widgets: `expressive_settings.dart` (take chuk's over agents's near-copy),
  `settings_list_view.dart`, `accent_icon_button.dart`, `widgets/sidebar/{sidebar_chrome,hover_marquee_text}.dart`
  (**the sidebar chrome**: `SidebarTokens`, `SbBrand`, `SbRailRow`, `SbChatTile`, `SbPinnedBento`,
  `SbSectionLabel`, `SbHairline`).
- Adapt `app/lib/main.dart`: `ThemeController` → `AppThemeService.instance`, wrap in
  `DynamicColorBuilder`, add localization delegates, add `_buildShellConfig()` verbatim
  from chuk `main.dart` (~L420–480), `MediaQuery(textScaler: uiScale)` builder. One-shot
  theme migration (`theme_mode_v1` → `AppThemeService`, resolve `system` via platform
  brightness), then delete `services/settings/theme_controller.dart`.
- `app/pubspec.yaml` (append only, read fresh): `flutter_localizations` (sdk), `intl`,
  `flutter_svg: ^2.2.2`, `dynamic_color`. Everything else is already present.
- Document in `docs/SUPABASE_SCHEMA.md`: `user_preferences` (`user_id` PK,
  `selected_model_id`, `system_prompt`) and `user_model_providers` (`user_id`, `model_id`,
  `provider_slug`) + owner-only RLS. `UserPreferencesService` falls back to device-local on
  error, so the app works before the tables exist.
- Verify: full `flutter analyze` clean; tests green except `settings_page_test` (expected
  until WS-2).

## WS-1 — Shell: chuk layout, Agents sidebar, top-right actions

- Do NOT import `sidebar_desktop.dart`/`sidebar_mobile.dart` verbatim (~90% chat-history
  logic). Write `app/lib/platform_specific/sidebar_desktop.dart` (~350 lines) reproducing
  chuk's `build()` skeleton exactly with the imported chrome, content swapped:
  `SbChatTile` per agent (name, last activity, `streaming:` when working, hover
  Hide/Delete menu); `SbPinnedBento` = "Active now"; buckets Working / Scheduled /
  Waiting / Hidden with chuk's sticky-header mechanic verbatim; search over name+role;
  footer pill verbatim (minus hosted `BalanceBadge`/`UpdateBanner`) — **its gear is the
  Settings entry**, as in chuk; `SbBrand(label: 'Agents')`. Data: `AgentRosterSource`.
  Same for `sidebar_mobile.dart`.
- Callback map: `onChatSelected`→select agent; `onNewChatTapped`→New coworker (onboarding);
  `onSettingsTapped`→settings modal/page; `onChatDeleted`→delete agent;
  `onWorkspacesTapped`→**Control Rooms**; `onMediaTapped`→**Agent's browser** (reusing all
  three mini-rail slots keeps chuk's alignment math untouched).
- Right panel (chuk's Workspaces/Media/Artifacts slot): `rooms` → `RoomListView` embedded
  (room open still pushes `RoomThreadPage`, keeping `rebind`); `browser` →
  `BrowserViewPage` with chuk's draggable divider. Delete the Artifacts branch.
- **Top-right floating slot** = `Positioned` `Row` at chuk's anchor, chuk's `IconButton`
  style, FOUR buttons: Agent controls (`tune`, when an agent is selected), Control Rooms
  (`groups_outlined`), Agent's browser (`desktop_windows_outlined`, when paired), **Copy
  full chat** (`copy_all_rounded`, chuk's own slot). Settings stays in the sidebar footer
  pill and Sign out in the settings modal footer — chuk's homes. The `AppBar` in
  `messenger_shell.dart` disappears (chuk has none). Mobile floating bar verbatim; title
  pill = selected agent name; trailing = Agent controls / New coworker.
- Single socket: new `app/lib/pages/agents_shell_state.dart` mixin `AgentsShellHost`
  holding everything now in `_MessengerShellState` (pairing store, roster, rooms,
  `_controller` notifier, room CRUD, browser, control drawer, `restoreCloudPairing`).
  `MessengerShell` (kept as public entry, all injectable seams kept so
  `messenger_shell_test` compiles) owns the host and builds the chat area ONCE, handing it
  to whichever wrapper (desktop/mobile) is selected; wrappers keep chuk's
  `Positioned.fill(Offstage(chatArea))` so the chat area is never unmounted. This is a
  deliberate divergence from chuk (documented in the file header) because the subtree owns
  the socket.
- Adopt `AppShellConfig` + `AppThemeService` unmodified (every imported page takes them).
- Verify: `messenger_shell_test`, `agent_roster_view_test` (ported onto the new sidebar) +
  a new assertion that `onController` fires once across a compact↔wide resize.

## WS-2 — Settings: chuk's two surfaces, section map

Import `pages/settings_page.dart` (mobile) + `pages/desktop_settings_modal.dart` (desktop rail
+ pane + search + log-out footer) verbatim. Section map:

| id | action |
|---|---|
| account | adapt chuk's `account_settings_page` (strip credits/usage/subscription) |
| pricing | HIDE |
| model | verbatim `model_selector_page.dart` (WS-3) |
| identity (system prompt) | verbatim; follow-up: forward `system_prompt` on the task frame |
| tools | HIDE page; move `showToolCalls` into Customization (tools run server-side) |
| connectors | keep agents's (move to `pages/mcp_connectors_page.dart`, chuk's path) |
| skills | import UI, hidden behind `kFeatureSkills` until a relay verb backs it |
| sandboxes | HIDE (hosted provisioning; agents's sandbox is host-side) |
| theme | verbatim `theme_page.dart` |
| customization | adapt (strip auto-title/download rows) + add the `VerboseService` switch |
| Data & Privacy / export / onboarding | HIDE (server is the truth); stub `OnboardingTourController` |
| about | adapt branding |
| developer | keep agents's page under the same id; port `DeveloperOptionsService` |
| NEW agents dests | `herenow`, `embedding`, `view` (verbose, searchable), `host` (host URL, pairing status, forget/re-pair) |

Deletes: `pages/settings/settings_page.dart`, `theme_settings_page.dart`,
`model_settings_page.dart`, `services/settings/theme_controller.dart`. Moves:
`pages/settings/{account,developer,embedding,herenow,mcp_connectors}_*` → `pages/`.
Verify: rewrite `settings_page_test` (3 tests) + new `desktop_settings_modal_test` opening
every rail id.

## WS-3 — Model dropdown: verbatim

Import `widgets/model_selection_dropdown.dart`, `model_selector_page.dart`,
`widgets/per_model_system_prompt_sheet.dart`, `services/per_model_system_prompt_service.dart`.
All deps land in WS-0; the fetch path (`/v1/models_info` via `ApiConfigService`, already
pointed at the local relay) needs ZERO edits. Hand the chat-UI import:
`ModelSelectionDropdown` (all six params + static `selectedModelNotifier`),
`kAutoCheapestProviderSlug`, `ChatModeSelector`/`ChatModelChoice`, and
`onOpenModelSettings → showDesktopSettingsModal(initialSectionId: 'model')`. Nice-to-have:
serve `/health` on the relay so `ApiStatusService` stops showing "API unreachable".

## WS-4 — MCP OAuth on the device (Dart)

- Import verbatim into `services/mcp/`: `mcp_oauth.dart` (edit: `clientName='Agents'`,
  `clientUri`), `mcp_redirect.dart`, `mcp_redirect_io.dart` (edit page copy),
  `mcp_redirect_stub.dart`; port chuk's `McpService._authorize()` + `_launch`/`_closeBrowser`
  verbatim into agents's `McpService`.
- Trigger in `McpService.connect()` when `auth == McpAuth.oauth` and no secret record:
  `discover(endpoint)` → `McpRedirectListener.start()` (127.0.0.1:<port>/mcp/callback) →
  `register(...)` → `buildAuthorizationRequest(resource: canonicalResource)` → `launchUrl`
  (in-app view, fallback external) → callback (5 min timeout, cancelable) →
  `closeInAppWebView()` → `exchange` → write the full record. Do NOT port `mcp_client.dart`
  (no device-side MCP client by design); decide from the catalogue's declared `McpAuth`.
- `McpStore`: full secret record under the same key `mcp_secrets_<id>` in chuk's exact JSON
  shape (`credentials{client_id,client_secret}`, `tokens{access_token,refresh_token,expires_at,scope}`,
  `issuer`, `authorization_endpoint`, `token_endpoint`, `scope`); `secretsFor/setSecrets`;
  keep `tokenFor/setToken` as wrappers; migrate legacy bare-string on first read.
- `forwardPayloads()` refreshes an expired token before forwarding (chuk's `_clientFor`
  logic) — a live app always hands the host a fresh token.
- **Extended forward payload (cross-language contract, additive):**
  ```json
  {"name":"notion","url":"https://mcp.notion.com/mcp","auth":"oauth","access_token":"…",
   "oauth":{"token_endpoint":"…","client_id":"…","client_secret":"…?","refresh_token":"…",
            "expires_at":"…","resource":"…","scope":"…","issuer":"…"}}
  ```
  `oauth` only for OAuth with a stored record; apiKey entries unchanged (creds in URL, no
  `auth`); appSession unchanged. Freeze as `app/test/fixtures/mcp_forward_payload.json`
  asserted from both Dart and Python tests; Python must accept the OLD payload too.
- `mcp_connector_sync.dart`: mirror the full record (was `{'token': …}`); read legacy
  key on pull. No new table.
- Verify: `mcp_oauth_test` (fake `http.Client`), `mcp_store_test` (record shape + legacy
  migration), `mcp_service_test` with an injected launcher (no browser), page test.

## WS-5 — Python: `mcp_client.py` refresh + executor manager cache (AFTER cowork-49)

`agent/src/chuk_agents_runtime/mcp_client.py`: (1) `configs_from_entries` keeps an OAuth entry
that has `oauth.refresh_token` even without `access_token` (today it becomes
unauthenticated — the reported bug); (2) new `refresh_access_token(oauth) -> (token|None,
oauth)` (RFC 6749 refresh via `httpx`, Basic auth when `client_secret`, never raises);
(3) `MCPConnection._http_headers()` precedence `token_provider → auth_token if not expired →
refresh → auth_token`, write-back, per-connection lock; (4) on connect failure with a
refresh token → refresh + `MCPManager.reconnect(server)`.
`executor.py::_session_mcp_manager`: hash a redacted projection (drop `access_token`,
`oauth.expires_at`, `oauth.refresh_token`) so a rotated token does not rebuild the manager
every task; push the fresh token into the existing manager.
**Gated:** `executor.py` is cowork-49's until their tool-call migration is committed; WS-5's
executor hunk waits for the coordinator's release. The `mcp_client.py` part is mine and
can go first.
Verify: `agent/tests/test_mcp_client.py` (oauth block survives; expired → refresh;
refresh failure → present-but-unauthenticated; apiKey unchanged; old payload unchanged),
`executor/tests/test_mcp_forwarding.py` (token-only change does not rebuild).

## WS-6 — Chat UI import + transport adapter (the core)

**Size reality:** the transitive closure of `chat_ui_desktop.dart` + `chat_ui_mobile.dart` is
228 files / 97k lines. With the stub cut-set it is **125 files copied (~53k lines)** + 19
already byte-identical + ~25 stubs. No Riverpod anywhere in the chat closure (verified by
grep) — do not add it. `desktop_send_logic.dart` is `part of chat_ui_desktop.dart` (one
ownership unit). agents's `models/chat_stream_event.dart` has DELETED `ToolCallsEvent` /
`NativeToolCall` and `multiplex_connection.dart` lost `case 'tool_calls'` — both must be
**restored verbatim** or four imported files do not compile (harmless: the adapter never
emits `ToolCallsEvent`).

**Mechanism:** `scripts/import_chat_ui.sh` + `tools/chat_ui_manifest.txt` (pinned chuk
SHA in the header) — copies each manifest path and rewrites the package prefix. Re-sync
with chuk master = re-run + `git diff`. Documented in `docs/CHAT_UI_IMPORT.md`
(manifest, SHA, stub inventory, allowed divergences, re-sync procedure).

**Copy verbatim (125):** screens/mixins/handlers under `platform_specific/chat/` (18);
renderer `widgets/message_bubble.dart` + `message_bubble/*` + `markdown_message`,
`agent_activity/*`, `ask_user_card`, `sandbox_artifact_block` (14); supporting widgets
(16: `attachment_preview_bar`, `model_selection_dropdown`, chart/table/diff/document/
image/map/weather widgets, `mcp_connect_card` overwrite); models (9 incl.
`chat_message`, `content_block`, `tool_call`, `stream_phase`, `chat_stream_event`
restore); streaming core (7: `streaming_manager{,_io,_stub}`, `chat_runtime*`,
`round_content_block_service`, `message_composition_service`); services (14);
transport `multiplex_connection` + `websocket_connector_io` (restore); utils (20 incl.
`theme_extensions` overwrite — chuk's `MaterialYouTokens` is a superset; keep agents's
`kMenuIconColor` in `utils/agents_theme_extras.dart`); misc (10 incl. `constants`,
`platform_config` overwrite + re-add agents flags, `l10n/*`); assets (fonts, mic icon).
**EXCLUDE `services/mcp/*` from the import** — agents's MCP (already verbatim-ported,
plus WS-4) is the source of truth; any symbol the chat UI needs from it is satisfied by
agents's files or a thin stub, never an overwrite. `mcp_client.dart` (device MCP client)
is stubbed if referenced.

**Stubs (~25, cowork-owned, upstream-signature-compatible, fixed header comment
"AGENTS STUB. Upstream: … @ <sha>. Reason: …"):** `websocket_chat_service.dart` (**THE
ADAPTER**), `tool_call_handler.dart` (**THE FOLD**), `streaming_chat_service` (exception
type only), `chat_storage_service` (real, local JSON per session key — instant-paint cache,
never authoritative), `chat_sync_service` (no-op), `title_generation_service` (local
rename, no model call), `artifact_*` / `workspace_*` (no-op / `SizedBox.shrink`),
`image_storage_service` + `pdf_attachment_service` (real, local blob store
`cowork://blob/<id>` — **where relayed files land**), `file_conversion_service`,
`streaming_transcription_service`, `streaming_foreground_service` (no-op — the server keeps
running, the client needs no foreground service), `offline_*` (no-op),
`notification_service` (no-op DURING THE IMPORT; replaced by the real port in WS-7),
`pricing_page`/`usage_details_page`/`credit_display` (thin). Superseded by other WS:
`user_preferences_service` and `model_selector_page` are imported VERBATIM (WS-0/WS-3),
not stubbed.

**The adapter — `app/lib/services/websocket_chat_service.dart`:** same path, class, static
method and signature as chuk's, so all call sites bind unchanged. Ignores `history`,
`systemPrompt`, `maxTokens`, `temperature`, `tools` (server owns them); `chatId` →
`sessionKey`; sends `controller.sendTask(message, sessionKey:, modelId:, providerSlug:,
reasoningEffort:, debug: VerboseService.instance.enabled)`; `onCancel` →
`requestStop(sessionKey)` (the composer's existing Stop button works untouched).
`images` → v2 (no image channel on `sendTask` yet; log + drop).

| `AgentsRelayInbound` (live) | `ChatStreamEvent` | `AgentsRunLedger` side-effect |
|---|---|---|
| Delta(text) | `ContentEvent(text)` | — |
| Reasoning(text) | `ReasoningEvent(text)` | recorded as model reasoning |
| Tool started | verbose only: `ReasoningEvent("▸ name: args")` | `open()` → `ToolCall(running)` |
| Tool terminal | verbose only: `ReasoningEvent(" ✓ exit 0")` | `close()` → completed/error, result, duration |
| Subagent | — | `ToolCall(name:'subagent')` opened/closed |
| File | — | bytes → blob store FIRST, then `ContentBlock.sandboxArtifact` |
| ApprovalRequest | — | completed `ToolCall(name:'ask_user', options: Publish/Deny)` → renders the real `AskUserCard` |
| RunError(msg) | `ErrorEvent(msg)` then `DoneEvent` | close |
| Done (live) | `MetaEvent({stop_reason, iterations})` → `UsageEvent({total_tokens})` → `DoneEvent` | `finish(finalAnswer)` |
| Delta/User/Done with `replay:true` | — (never into a live run) | routed to `AgentsReplayLoader` |
| DebugContext | — | stashed for the copy button |
| Room*/Browser* | — | owned elsewhere |

**`ToolCallsEvent` is never emitted** — the single invariant that keeps the client tool
loop dead. Guarded by a unit test over every inbound variant.

**The fold — `tool_call_handler.dart` stub:** `processAssistantResponse` (already called
from `onComplete` at all call sites) takes the run's ledger and returns
`ToolLoopResult.finalAnswer(content, reasoning: modelReasoning, toolCalls: ledger.toolCalls,
producedBlocks: ledger.blocks)` with `shouldContinue == false` ALWAYS →
`startStreamPass` runs exactly once per turn; the tool loop, fact-check, retry and
continuation passes are structurally unreachable. `nativeToolDefinitions` → `[]`,
`buildInitialSystemPrompt` → `''`. MessageBubble's tool timeline, activity header,
reasoning card, artifact cards and `AskUserCard` light up from real data with zero edits
to imported files. Live in-run tool narration rides the reasoning channel (already streams
live), gated on the verbose flag = "quiet by default, full log on demand" for free.
Escape hatch if needed: one additive `liveToolCalls` stream on `streaming_manager_io.dart`
(~12 lines, the only allowed widget-layer divergence, recorded in `CHAT_UI_IMPORT.md`).

**Locator — `services/agents/agents_relay_link.dart`:** singleton with
`ValueNotifier<AgentsRelayController?> controller`, `ValueNotifier<String> sessionKey`,
long-lived broadcast `inbound` re-bound on `bind(c)` (survives reconnects). Shell wiring is
two lines: `_onController → link.bind(c)`, `_select → link.sessionKey.value = threadKey`.

**`AgentsThreadView`:** constructor and lifecycle half unchanged (`_bootstrap`,
controller build, pairing/connect bar, auto-reconnect + watchdog, `_decideApproval`,
callbacks). Rendering half (~1,100 lines: `_ThreadEntry` family, `_onInbound` folding,
composer, `_send/_stop`, mode picker) DELETED; `build()` returns the connect bar when
unpaired, else `ChukChatUIDesktop`/`ChukChatUIMobile` with `selectedChatId: threadKey`,
`showToolCalls/showReasoningTokens/showTps: _verbose`, `toolCallingEnabled: false`,
`onOpenModelSettings: onOpenModelScreen`. Run-state callbacks driven off the ledger.

**History — server-authoritative:** `AgentsReplayLoader` (`services/agents/`) folds
`replay:true` events into chuk's `_messages` shape (User → user row; Delta → ai row;
Tool/Subagent → completed `ToolCall`s; File → blob + `sandboxArtifact`), overwrites the
local `ChatStorageService` cache on the history-end marker and fires `changes` → the
imported screen repaints. Replay is idempotent (overwrite). Triggered on `paired`, on
agent switch (`didUpdateWidget`), and after every reconnect, with the cursor from WS-7.

**Pubspec (append-only, lands ALONE first, verified by `flutter build linux --debug`
before any Dart is imported — native plugins only fail at build time):**
`flutter_localizations`, `archive`, `desktop_drop`, `file_picker`, `fl_chart`,
`flutter_map`, `latlong2`, `geolocator`, `flutter_math_fork`, `flutter_svg`, `highlight`,
`image`, `image_picker`, `markdown`, `pasteboard`, `pdfrx`, `pdfx`, `permission_handler`,
`record`, `share_plus`, `web`, plus WS-0's `intl`, `dynamic_color`, and WS-7's
`flutter_local_notifications`, `firebase_core`, `firebase_messaging`. Fonts block copied
from chuk. NOT needed: `flutter_riverpod`, `sqflite`, `flutter_foreground_task`, `timezone`.
Optional later trim (map/chart/weather widgets → drop 4 deps) only after green.

**Tests:** `websocket_chat_service_test` (fake controller: each inbound → expected event
sequence; NO `ToolCallsEvent` for any variant; cancel → `requestStop` once),
`tool_call_handler_stub_test` (`shouldContinue` always false), `agents_run_ledger_test`,
`agents_replay_loader_test` (second replay overwrites, no duplicates),
`agents_thread_view_test` split: keep pairing/connect/reconnect half, rewrite the
transcript half against the imported widgets (approval → `AskUserCard`).

## WS-7 — Run detachment + "answer ready" notification

**Verified today: a run is KILLED when the app disconnects.** `LocalRelay` `EVENT_LEAVE` →
`LocalHost._on_peer_event` → `HostParty.on_controller_left` → `task_server.stop()` →
`Executor.stop()` interrupts every run AND `environment.cleanup()` tears the sandbox down.
Also: the relay buffers undelivered frames unboundedly; the frame codec has a per-socket
monotonic `seq` guard (the executor must re-bind its opener per app session); the app has
no request-id routing (re-attaching a reconnected client to a live run is free).

**Rule:** a run belongs to the host process, not to a socket. The socket is a view.

**Python (gated on the coordinator's release after cowork-49 commits `executor.py`):**
- `host/party.py`: `on_controller_left` no longer stops the TaskServer — only clears the
  codec/token, sets `_controller_present=False`. `_provision` splits into first-provision
  (build TaskServer ONCE) and re-provision (refresh tokens in place on the existing
  `SupabaseSession` + rebind codec — this also fixes bead **cowork-c91**, stale host token).
  `send_result_frame` DROPS while no controller is attached (fixes the unbounded buffer).
- `host/serve.py`: `rebind(opener, sealer)`; TaskServer lives for the process; accepts
  `on_run_finished` / `on_approval_pending`.
- `executor/executor.py`: `rebind_codec` under a `_codec_lock`; never cancel on
  disconnect; `run_id` (uuid4) + `RunStore` writes at accept/finish/fail (BEFORE
  `_terminal`); `_emit_lock` making replay and live emission mutually exclusive;
  `_handle_replay` gains `after_id` cursor, emits a `run_state` header
  (`running|idle`, run_id, started_at, prompt), events carry `mid`, persisted run
  terminals replay as `{"type":"done","replay":true,"reason":"finished","while_away":true}`,
  then the existing `reason:"replay"` history-end marker (old clients unaffected); new
  inbound `run_ack` and `account_authentication` (routed up).
- `executor/protocol.py`: `run_state_payload`, `run_ack_payload`, `done_payload` gains
  `run_id` + `while_away`.
- `agent/state.py`: `replay_events(session_id, *, after_id=0)` + `mid`; new `runs` table
  in the same SQLite file (`run_id` PK, session_id/key, prompt, state running|finished|failed,
  reason, final_answer, iterations, tokens_spent, first/last_mid, started/finished_at,
  `notified_at` = dedup key); `begin/finish/fail/get/latest_for/mark_notified`; startup
  sweep of orphan `running` rows → `failed/host_restarted`.
- `host/host.py`: owns TaskServer for the process, the notifier, `user_id`; sweeps orphans.

**Notification channel (chosen):** host → Supabase row (owner-only RLS) → Edge Function
`notify-run` → FCM, PLUS a host-fired **desktop notification over DBus/notify-send**
(Linux, the running target; no Firebase, no app process needed). Rejected: ntfy alone
(cannot wake a fully closed stock-Android app without a second app), Realtime (not push),
direct FCM from the host (would put the service-account key on every user machine).
**Privacy rule:** the push carries NO answer content — generic title/body; content stays
E2E host↔app. FCM sender identity is bound to the APK: Android push needs a Firebase
project + `google-services.json` (user setup); desktop needs nothing.
- Schema (append to `docs/SUPABASE_SCHEMA.md`): `cowork_device_tokens (user_id, device_id,
  token, platform, updated_at; PK user_id+device_id)` and `cowork_run_notifications (id,
  user_id, run_id, agent_id, agent_name, session_key, kind completed|failed|approval_needed,
  title, body, preview_ciphertext?, created_at, pushed_at, consumed_at; UNIQUE (user_id,
  run_id, kind) = the dedup guarantee)`, both with the four owner-only policies.
- Edge Function `supabase/functions/notify-run/index.ts`: caller-JWT client (RLS is the
  authorization, no service-role key), idempotent on `pushed_at`, FCM v1 send with
  `android.notification.tag = session_key` (collapses per thread), self-heals
  `UNREGISTERED` tokens, sets `pushed_at`.
- `host/notify.py` `SupabaseNotifier` (implements the existing unused
  `chuk_agents_manager.autonomy.Notifier` seam): single-worker thread (never delays the task
  worker), REST insert with `resolution=ignore-duplicates` then function call, 401 →
  one `session.refresh()` + retry, bounded outbox flushed on re-provision,
  `mark_notified` only on success. Optional keyless sinks `AGENTS_NTFY_TOPIC`,
  `AGENTS_WEBHOOK_URL`.
- `host/desktop_notify.py` `DesktopNotifier`: `notify-send --app-name=Agents
  --hint=string:desktop-entry:agents …`, fallback `gdbus … Notify`, macOS `osascript`;
  enabled when `DISPLAY`/`WAYLAND_DISPLAY` set; all exceptions swallowed.
- **Anti-duplicate rule:** no controller attached → Supabase/FCM push + desktop; attached +
  foreground → nothing (user is watching); attached + backgrounded → app-local
  `flutter_local_notifications` on the live `AgentsRelayDone` (the app knows its own
  lifecycle); desktop closed + host on the same machine → desktop notification always.
  Phase 2: delivery-confirmed push via `run_ack` (host arms a 15 s timer at done).
- App: port chuk's `notification_service_io.dart` → `services/notifications/local_notifications.dart`
  (Linux enabled), `push_service.dart` (Firebase init, token upsert keyed by the existing
  Agents device id, `onTokenRefresh`, auth-state hooks, tap → `NotificationRouter`),
  `notification_router.dart`; `main.dart` init + background handler; `messenger_shell`
  listens → select agent, replay with cursor, `PATCH consumed_at`; thread view becomes a
  `WidgetsBindingObserver` for the backgrounded toast; Android manifest/gradle +
  `google-services.json`.
- **Reopen flow:** per-session replay cursor `lastMid` in SharedPreferences; ALWAYS
  `requestReplay(afterId: lastMid)` on `paired` (cheap on an infinite thread; full on a
  fresh install); on `closed` with a stored pairing do NOT reset to idle — show
  `_RunPhase.detached` "Working… (reconnecting)"; handle `run_state`; `AgentsRelayDone`
  gains `runId`, `whileAway`, `isHistoryEnd => reason == 'replay'`; a replayed run
  terminal renders as a real done card with an "Answer ready" affordance when
  `whileAway`; consume the notification and cancel the OS toast after replay.

## Conflicts between the three designs — resolved

1. `notification_service`: stubbed during the chat-UI import (WS-6), replaced by the real
   port in WS-7. Sequencing, not conflict. `streaming_foreground_service` stays a stub.
2. `user_preferences_service`: imported VERBATIM (WS-0, Supabase-backed with local
   fallback), not the local stub Plan A proposed.
3. `model_selector_page.dart`: imported VERBATIM (WS-3), not a thin push to agents's page;
   agents's `model_settings_page.dart` is deleted.
4. MCP: agents's `services/mcp/*` is the source of truth (SC1's verbatim port + WS-4
   OAuth). The chat-UI import EXCLUDES `services/mcp/*`; `mcp_client.dart` is stubbed if
   referenced (no device-side MCP client by design).
5. Riverpod: NOT added (Plan A verified the chat closure has none; Plan B's note was
   tentative). `dynamic_color` IS added (chuk's `main.dart` uses `DynamicColorBuilder`).
6. Replay `done` semantics: `reason == 'replay'` is the history-end marker (renders
   nothing, ends replay); a replayed `done` with `reason: 'finished'` + `while_away` is a
   real completion card. `AgentsReplayLoader` implements exactly this split.
7. Event contract vs. executor gating: the WS-7 wire contract (`run_state`, `mid`,
   `after_id`, `done.run_id/while_away`, `run_ack`) is **frozen by this plan now**; the
   Dart side codes to it immediately (unknown fields are ignored, so order is safe); the
   Python side lands when the coordinator releases the executor.

---

# PHASES (sequential subagents, Opus 5 only, one at a time)

Each phase must be green (scoped analyze + its test files, run one file at a time) before
the next starts. `git switch -c chat-ui-import` for P2–P4 so the tree is never red on
`agents` for long; merge behind a green gate.

| # | Phase | Gate |
|---|---|---|
| P0 | **WS-0 Foundations** (solo): constants/utils/theme/l10n/AppShellConfig/AppThemeService/expressive kit/sidebar chrome; `main.dart` adapt + theme migration; **pubspec lands alone** (all deps for WS-0/6/7) + `flutter pub get` + `flutter build linux --debug`. | full `flutter analyze` clean; tests green except `settings_page_test` |
| P1 | **Contract + relay client**: extend `agents_relay_client.dart` (`AgentsRelayDone.runId/whileAway/isHistoryEnd`, `run_state` inbound, `requestReplay(afterId:)`, `run_ack`), restore `chat_stream_event.dart` + `multiplex_connection.dart` verbatim, `theme_extensions` overwrite + extras. | relay client tests green |
| P2 | **WS-6 Chat-UI import**: import script + manifest → 125 files → stubs until 0 errors (the big gate, budget 2–3× any other step) → `AgentsRunLedger` + `AgentsRelayLink` → adapter → `ToolCallHandler` stub → `AgentsReplayLoader` + local `ChatStorageService` → `AgentsThreadView` rewrite → 2-line shell wiring → `docs/CHAT_UI_IMPORT.md`. | 0 analyze errors; adapter/ledger/loader/stub tests + rewritten `agents_thread_view_test` green; manual `flutter run -d linux`: task streams, tool card, file card, Stop, kill+reopen replays |
| P3 | **WS-1 Shell**: `AgentsShellHost`, root-wrapper layout (desktop+mobile), Agents sidebar on chuk chrome, right panel (rooms/browser), top-right 4 actions incl. Copy full chat, AppBar removed. | `messenger_shell_test` + ported roster tests + single-socket resize assertion |
| P4 | **WS-2 Settings + WS-3 Model dropdown** (one subagent each, sequential): both settings surfaces, section map, cowork-only dests, `model_selection_dropdown`/`model_selector_page` verbatim, deletes/moves. | rewritten `settings_page_test`, new `desktop_settings_modal_test`, dropdown widget test |
| P5 | **WS-4 MCP OAuth (Dart) + WS-5 `mcp_client.py`**: device OAuth verbatim, full secret record, extended forward payload + shared fixture, connector sync, Python refresh path. (`executor.py` manager-cache hunk waits for the release.) | `mcp_oauth_test`, `mcp_store_test`, `mcp_service_test` (injected launcher), page test; `agent/tests/test_mcp_client.py`; manual: connect an OAuth connector on Linux → browser → token in keychain → forward payload carries `oauth` |
| P6 | **WS-7 Run detachment (Python)** — **GATED**: starts only after cowork-b7 releases `executor.py`. `RunStore`, replay cursor/`run_state`, party/serve/host changes, orphan sweep, desktop notifier. | `test_a_run_survives_the_controller_disconnecting`, `test_no_frames_are_buffered_for_an_absent_controller`, `test_rebinding_the_codec_keeps_a_running_task`, `test_replay_and_a_live_run_do_not_interleave`, `test_desktop_notify`; manual: task → close app → desktop toast → reopen → answer |
| P7 | **WS-7 Notifications (cloud + app)**: schema + Edge Function, `SupabaseNotifier`, app local notifications port, FCM registration + tap routing + consume, replay cursor + `detached` phase + Answer-ready card. | `test_notify.py` (happy/401/dup/outbox/attached-no-push + body contains none of the run text), `local_notifications_test`, `push_service_test`, thread-view replay/detached tests; manual D10 acceptance |
| P8 | **Hardening + review**: `run_ack` delivery confirmation, approval push (closes `cowork-kjl.5`), run wall-clock guard, replay paging bead; then an **Opus-5 review pass over the whole Flutter side** (does it really work, problems, tests green) before calling it done. | review report; all listed test files green one-by-one |

**Beads to file at kickoff:** WS-0 foundations (P1), chat-UI import (P0), shell (P1),
settings (P1), model dropdown (P1), MCP OAuth Dart (P1; supersedes `cowork-jqi`), run
detachment (P1, blocks notifications; `cowork-c91` linked), notification channel (P1;
`cowork-kjl.5` as child), replay cursor (P2), run wall-clock guard (P2), replay paging (P3).

# VERIFICATION (end-to-end, the acceptance test)

1. `flutter analyze` clean; every test file listed above green, run one at a time.
2. Live on this Linux box against the real Python host: pick an agent → the chat looks
   like chuk_chat → send a task → deltas stream, a tool card appears (verbose on) or not
   (verbose off) → a file card lands → Stop works mid-run.
3. Send "count to 20 slowly, then tell me the total" → **close the app** → wait →
   **desktop notification arrives** → reopen → that agent's thread shows the full
   transcript + the answer replayed from the server; `runs` row is `finished`.
4. Settings: chuk's modal/page, model selection page verbatim, Fast/Thinking/Custom pill in
   the composer, connectors page; connect an OAuth connector → browser opens → token
   stored → the task frame forwards the `oauth` block → the Python side dials it
   authenticated.
5. Uninstall + reinstall + sign in → pairing restored from Supabase → same history, no
   re-pairing.
6. Android (after the user provisions a Firebase project): force-stop the app mid-run →
   FCM notification → tap → thread opens with the answer.

**Definition of done** (from `docs/PRODUCT_PHILOSOPHY.md`): the user typed one thing and
closed the app. Later, ONE notification: "your answer is ready". Tap → the coworker's
thread with the finished result, replayed from the server. No command, no error, no
excuse (unless the full-log toggle is on). Delete the app, reinstall on another phone,
sign in — everything is still there.

# Decisions taken (no open questions)

- Top-right: four actions (Agent controls, Control Rooms, Agent's browser, Copy full
  chat); Settings stays in the sidebar footer pill, Sign out in the settings footer —
  chuk's homes.
- Tool-calling settings page hidden (tools run server-side); `showToolCalls` lives in
  Customization. Skills page imported but behind `kFeatureSkills` until a relay verb backs it.
- Branding: `McpOAuth.clientName = 'Agents'`, plain-text `SbBrand('Agents')`.
- Android push requires the user's own Firebase project (`google-services.json`); desktop
  works without any cloud setup. Not a blocker for anything else.
- Commit policy: nothing is committed by this session until the user says so directly
  (coordinator is arranging that); cowork-49 snapshots `prompt.py`/`executor.py`.
