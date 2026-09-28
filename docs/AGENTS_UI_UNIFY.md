# Agents UI = chuk_chat UI (unification map)

Status: 2026-09-28. Beads: `chuk_chat-szg` (audit + unification), `chuk_chat-18v`
(Chat | Agents switch, after this).

## The rule

The Agents build (`FEATURE_AGENTS=true`) looks exactly like chuk_chat. It
imports the same files for composer, chat view, bubbles, sidebar chrome and
settings. There is no second copy and no "Agents look".

* **COSMETIC gate (C)**: delete the Agents branch. The chuk value wins.
* **FUNCTIONAL gate (F)**: relay transport, host tools, pairing, rooms, agent
  browser. Keep it.
* **UX gate**: a messenger behaviour (reply, reactions, queued follow-ups,
  anchored transcript, long-press menu). Keep the behaviour, but draw it with
  chuk's components.

Phone home (inbox + floating nav pill: Chats, Media, Settings) stays. The
owner likes it.

## Divergence map (read-only audit, 2026-09-28)

The Agents app already uses chuk's chat State (`ChukChatUIMobile`,
`ChukChatUIDesktop`) and chuk's `MessageBubble`. The look drifts through:

* 165 flag gates inside those shared files,
* a second composer on desktop,
* a parallel kit for chrome, sidebar and settings (`ui/expressive/*`,
  `agents_desktop/*`, `platform_specific/mobile/*`, Agents settings pages).

Flags: `agentsChatCore` (= `kFeatureAgents`, true everywhere in the Agents
build), `messengerMode` (phone thread `agents_thread_view.dart:1755`, rooms
`room_thread_view.dart:172,213`), `agentsThread` (desktop thread
`agents_thread_view.dart:1748`), `agentsMenus`, `_agentsLook`, local aliases
`agentsLook` / `agents`.

### 1. Gates

165 code lines: 25 plumbing, 36 F, 24 UX, 80 C; plus about 30 alias gates, all C.

F (keep): `main.dart:133,179,547`; `supabase_service.dart:67,73`;
`multiplex_session.dart:457`; `websocket_chat_service.dart:31,37,70`;
`tool_call_handler.dart:431`; `chat_sync_service.dart:138,200`;
`chat_preload_service.dart:69`; `streaming_manager_io.dart:51`;
`storage/chat_origin.dart:36`; `content_block.dart:118`;
`user_preferences_service.dart:69,797`; `chat_ui_helpers.dart:125-126`;
`chat_ui_mobile.dart:315,400,488,516,518,988,3501`;
`chat_ui_desktop.dart:613,1770`; `room_thread_view.dart:172,213`;
`message_bubble/layout.dart:336` (automation-wake line);
`customization_page.dart:627-628` (Detail / Full log);
`settings_page.dart:136`, `desktop_settings_modal.dart:320` (Agents
destinations only; the frame is C).

UX (keep behaviour, chuk look): `chat_ui_mobile.dart:319,357,3417,2266,2337,
3896,3390,3396,3399,3403,3850`; `chat_ui_desktop.dart:314,1741,423`;
`message_bubble.dart:416`; `layout.dart:29,439,444,744,478,773,635,976,1450`.

C (delete): `constants.dart:107-111,216,308,362,568`;
`app_theme_service.dart:30`; `chat_ui_mobile.dart:1699-1700,2431,3359,
3388-3389,3602,3688,3809,3886,3984,3997,4065`; `chat_ui_desktop.dart:1699,
1707,1708,1797,1808,1835,2073,2078,2089,2571,2912`;
`chat_mode_selector.dart:414,446,524,525` + `flat`;
`chat_message_list_item.dart:132,183` + `agentsRuns`/`hoverActions`;
`message_bubble.dart:372`; `layout.dart` (31 lines, `agentsLook` 358-708);
`markdown_message.dart:523-889`; `expressive_settings.dart:50,240,470,507`;
`theme_page.dart:699,905,991,1158`; `customization_page.dart:264,425`;
`desktop_settings_modal.dart:782,855`; `settings_list_view.dart:110`;
`message_bubble/tools.dart:311`; `message_bubble/rich_blocks.dart:544`;
`brand_wordmark.dart:30`; `anchored_menu.dart:121`;
`mobile_chat_widgets.dart:82`; `account_settings_page.dart:388`;
`MenuDensity.isDense` (deleted);
`MobileChatPreferences.messengerTypography` (`layout.dart:60-73`).

### 2. Composer

Phone: `ChukChatUIMobile(messengerMode: true)._buildSearchBar`
(`chat_ui_mobile.dart:3838`), chuk's own composer with a flag. C differences:
edit notice (3886), expand glyph in the field (3983-3999) instead of chuk's
button (4065-4083), disclaimer (3688/3738), `agentsMenus` menus (3809,
1699-1700), send glyph colour (`mobile_chat_widgets.dart:82`), and
`AgentTheme` (`mobile_chat_screen.dart:159`) which reseeds the accent per
coworker. UX: no stop button (3849), reply preview (3896), queue count (3903).

Desktop: a second composer `_buildAgentsComposer`
(`chat_ui_desktop.dart:2608-2855`, picked at 2089-2112) instead of chuk's
`_buildSearchBar` (2155). 28 px `DeskIconButton`s, radius 12, inline send,
"Message <agent>" hint, keyboard hint line, `_agentsDock`, 720 px measure.

### 3. Chat view and bubbles

List: day divider, runs, user width 0.72 (C); anchored transcript (UX);
typing bubble (F). Bubble (`layout.dart`, `_agentsLook = agentsChatCore ||
messengerMode`): filled accent user bubble with 22/7 run corners, filled AI
bubble (chuk draws none), `MessageStamp`, Arimo 15, reasoning/model/TPS
hidden, no status header, card gap, entrance animation (all C).
`markdown_message.dart`: `ChukTable` vs `ChukTableClassic`, link style, list
markers, code tracking (C).

Phone top bar `mobile_chat_chrome.dart:71-150` vs chuk
`root_wrapper_mobile.dart:448-574` (C, except the files and screen buttons).
Desktop `AgentsThreadHeader` 48 px bar vs chuk's floating chips (C);
`MessageHoverActions` vs chuk's action bars (C); compact theme override
`agents_desktop_layout.dart:454-459` (C).

### 4. Sidebar

chuk: `SidebarMobile` / `SidebarDesktop` on `widgets/sidebar/sidebar_chrome.dart`
(`SbFloatingBar`, `SbRoundAction`, `SbBlock`, `SbNavCard`, `SbSearchField`,
`SbChatTile`, `SbCard`, `SbGroupHeader`, `SbAccountLine`, `SbRailRow`,
`SbHairline`).

Agents desktop: `AgentRosterView` re-implements all of it (`_header` 602,
`_searchField` 647, `_SectionHeader` 963, `_HoverTile` 1027, `_AgentRow`
1135, `_RoomRow` 1272, `_RailFace` 1423, `_accountRow` 792, `DeskHairline`,
`showAgentsConfirmDialog`). Right pane `DeskPaneHeader` / `PaneResizeHandle`
vs chuk's `ArtifactPanel` header and divider.

### 5. Settings

`settings_page.dart:136` → `_buildAgentsHub` (566-835): `ExpressiveScreen`
frame instead of `Scaffold` + `FloatingAppBar`; missing chuk rows; a copied
`pages/settings/mcp_connectors_page.dart`; `DeveloperSettingsPage` instead of
`DeveloperOptionsPage`; duplicated sign-out block. `desktop_settings_modal.dart`
`_agentsGroups` (192-317) the same. `mobile_agents_settings_page.dart` has a
private kit (`_section`, `_row`, `_switch`, `_icon`) instead of chuk's
`Expressive*` rows. Three header styles inside Agents (`ExpressiveScreen`,
`FloatingAppBar`, plain `AppBar` in `messenger_shell.dart:405-409,471-477`).

### 6. Parallel kits

`ui/expressive/*`: `MorphTap`, `ExpressiveButton`, `ExpressiveIconButton`,
`ExpressiveLoader`, `ExpressiveScreen`, `TopVeil`/`BottomVeil`,
`connected_group`, `working_dots`, `bubble_shape`/`bubble_kind`.
`widgets/agents_desktop/*`: `DeskIconButton`, `DeskHairline`,
`PaneResizeHandle`, `DeskPaneHeader`, `AgentsDesktopDialog`, `kDesk*`
metrics, `MessageHoverActions`. Dead: `widgets/settings_kit.dart`,
`AgentAvatar`, `MobileBarFade`, `mobileChipShadow`, `expressiveSheet`.

### 7. Theme with `agentsChatCore` on

Radii 28/20/20/20/32 vs 20/16/16/14/28; navy/white `onPrimary`; Material
SnackBar; expressive FAB; heavier headline typography; menu radius 26 vs 18;
look settings not synced; wordmark as text instead of SVG.

## Work split (2026-09-28)

| Stream | Files |
|---|---|
| A composer + chat screens | `chat_ui_mobile.dart`, `chat_ui_desktop.dart`, `chat_mode_selector.dart`, `chat_message_list_item.dart`, `mobile_chat_widgets.dart`, `anchored_menu.dart`, `mobile_chat_screen.dart`, `ui/expressive/agent_theme.dart`, `chat_reply_preview.dart`, `ui/expressive/day_divider.dart` |
| B bubbles + markdown + theme | `message_bubble.dart`, `message_bubble/*`, `markdown_message.dart`, `constants.dart`, `brand_wordmark.dart`, `app_theme_service.dart`, `ui/expressive/bubble_*.dart`, `ui/expressive/message_stamp.dart` |
| C settings | `settings_page.dart`, `desktop_settings_modal.dart`, `expressive_settings.dart`, `settings_list_view.dart`, `theme_page.dart`, `customization_page.dart`, `account_settings_page.dart`, `pages/settings/*`, `mobile_agents_settings_page.dart`, Agents-only settings pages, `ui/expressive/expressive_screen.dart` |
| D sidebar + desktop chrome + phone chat top bar | `agent_roster_view.dart`, `widgets/agents_desktop/*`, `agents_desktop_layout.dart`, `messenger_shell.dart`, `agents_shell_state.dart`, `agents_thread_view.dart`, `agents_thread_header.dart`, `mobile_chat_chrome.dart`, `widgets/sidebar/sidebar_chrome.dart` (additive only) |

## Result (2026-09-28)

All four streams landed; the Agents build now draws chuk's components.

* A: one composer (`_buildSearchBar`) on phone and desktop; no per-coworker
  accent (`AgentTheme` deleted); chuk menus; day divider, runs, stamp and
  `MessageHoverActions` gone. The dense menu path and `MenuDensity` are
  deleted.
* B: chuk bubbles (no AI bubble, user bubble with tail), chuk markdown,
  `constants.dart` identical to upstream, look settings sync, SVG wordmark.
  Kept: automation-wake line, long-press menu, reactions, reply quote,
  `SandboxArtifactBlock` (the only renderer for host files).
* C: one settings page (chuk's) plus an "Agents" section; chuk's connectors
  page (Agents probe behind `agentsChatCore`); `DeveloperOptionsPage` with an
  Agents group. Left out in Agents: AI identity, Tool calling, Assistant,
  onboarding replay (the host owns them, or they drive screens the Agents
  shell does not show).
* D: desktop roster on `sidebar_chrome` (`SbFloatingBar`, `SbNavCard`,
  `SbSearchField`, `SbGroupHeader`, `SbChatTile`, `SbAccountLine`, mini
  rail); floating thread chips (`kAgentsThreadHeaderInset` keeps the first
  message clear); phone chat top bar on chuk's chips and title pill; one
  `PaneHeader` shared with `ArtifactPanel`.
* Phone home: three tabs (Chats, Media, Settings).

Follow-ups: `chuk_chat-vm03` (DESIGN.md), `chuk_chat-yufx` (phone chat
inset), `chuk_chat-2cp2` (leftover Agents kit), `chuk_chat-ejx`,
`chuk_chat-kub3`, `chuk_chat-m1vl`, `chuk_chat-p2t3`, `chuk_chat-ac7z`,
then `chuk_chat-18v` (Chat | Agents switch).

## Per-chat routing (2026-09-28, `chuk_chat-w9n5`)

`agentsChatCore` means "this is the Agents build", nothing more. Inside that
build each chat takes its side by its id (`ChatOrigin.isAgentsThread`: a
host session key, or a key the Agents code claimed; a UUID is chuk_chat's):

| | chuk_chat chat | Agents thread |
|---|---|---|
| send | `_sendHosted` (multiplex `/v2/ws`) | `AgentsChatTransport` (relay) |
| tool loop | `ToolCallHandler` (client) | `AgentsToolCallHandler` (fold) |
| silence | 60 s idle timeout | log-only watch |
| cloud / queue | `encrypted_chats` / `OfflineQueueService` | `cowork_chats` / `AgentsTaskOutbox` |
| lists | chuk sidebar, chat search | Agents roster (host) |

Entry points: `WebSocketChatService.usesAgentsTransport(chatId)`,
`ToolCallHandler.forChat(chatId)` (resolved per send),
`StreamingManager.idleTimeoutEnabledFor(chatId)`. A send with no chat id
(titles, offline executor, assistant overlay) is hosted. An Agents thread
gets no auto-title.

The chat screen follows its surface, not the build: `messengerMode` (phone
thread) and `agentsThread` (desktop thread) turn on the shared render cache,
the cached system prompt, the "save the model only when it changed" rule and
skip the tool-loop warm-up. chuk's `RootWrapper` passes neither.

Storage start: `SessionManagerService` / `AppInitializationService` run in
both builds and own chuk_chat's sidebar load, sync and preload.
`AgentsChatStorageBootstrap` repeats the sidebar load and sync start (both
idempotent) and owns only the Agents part (outbox flush and pull, repairs).
Token refresh stays build-level: in the Agents build every rotation goes
through `SessionRefreshScheduler`, and the hosted socket gets each new token
through `MultiplexSession`'s auth bridge.

## Settings for both halves (2026-09-29, `chuk_chat-osd1`)

The "Chat" half of the Agents build is chuk_chat, so its settings are back.
This replaces the "Left out in Agents" line under Result, C.

* Phone `SettingsPage` and desktop modal, Agents build, in chuk's order:
  Model Selection, AI Identity & Memory, Tool Calling, Connectors, Skills
  (chuk's `SkillsSettingsPage`), Assistant (Android only), GitHub. Then the
  Agents section: here.now, Embedding, API Keys, Automations, Host skills
  (`AgentsSkillsSettingsPage`, page title "Host skills").
* The onboarding replay stays hidden in the Agents build: that build wires
  no tour (`TourKeyRegistry.anchorFor` is null there). The phone page takes
  its tour keys through `anchorFor` too, so two mounted settings pages never
  share a `GlobalKey`.
* Customization "Full log" and Developer options "Verbose view": only an
  Agents thread reads `VerboseService`, so both stay Agents-build rows; the
  subtitles now say "in an Agents thread". "API base" stays build-level.
* Connectors show both views in the Agents build: the badge is the host's
  (`McpService.probe`, for an Agents thread), the line under the name and the
  detail page's device check are this device's (`verifyReachable`, for a
  chuk_chat chat, which calls the server through `McpService.call`). The
  detail page offers Reconnect when either side fails.
