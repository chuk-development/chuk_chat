# Handover — P3-rest shell (session cowork-shell = cowork-f7, 2026-09-05)

Everything below is **uncommitted** in the shared working tree (branch
`cowork`). Nothing in this session was committed; the user gives that word.

## What was done (beads cowork-b6h, cowork-8y2, cowork-acu — all closed)

### The shell is chuk's root wrapper now (`app/lib/pages/messenger_shell.dart`)

The `AppBar` is gone. The layout is `root_wrapper_desktop.dart` from chuk_chat
master (d31526a), slot for slot, with CoWork's content:

- One `Stack`. The chat area (`CoworkThreadView`) sits in a `Positioned.fill`
  inset by the sidebar and the right panel and hidden with `Offstage` in
  compact mode — never unmounted.
- Sidebar (`AgentRosterView`) slides in from the left: `Positioned(left: 0 |
  -width)`, `AnimatedOpacity`, `IgnorePointer` when closed. 320 px, or 85 % of
  the window in compact mode.
- Hamburger at chuk's anchor (`kTopInitialSpacing`, `kFixedLeftPadding`,
  48×40). Mini rail under it when the sidebar is closed, one
  `kButtonVisualHeight` per row: New coworker, Control Rooms, Agent's browser
  (the last once a coworker is selected).
- Right panel at chuk's Workspaces/Media/Artifacts slot: `Control Rooms`
  (embedded `RoomListView`, 400 px cap; a room still opens as its own route so
  `rebind` keeps working) and `Agent's browser` (embedded `BrowserViewPage`
  on the live controller via `ValueListenableBuilder`, chuk's draggable
  divider, default half the content width). Same header as chuk (icon,
  title, Close).
- Floating top-right row at chuk's anchor, FOUR `IconButton`s in chuk's style:
  Agent controls (`tune`, with a selected coworker), Control Rooms
  (`groups_outlined`), Agent's browser (`desktop_windows_outlined`, with a
  selected coworker), Copy full chat (`copy_all_rounded` 20 px, chuk's slot,
  tooltip unchanged — both existing tests find it).
- Settings is where chuk keeps it: the gear in the sidebar footer pill →
  `showDesktopSettingsModal` (desktop) / `SettingsPage` route (phone). Sign
  out lives in the modal's footer and in the phone sheet (`MobileAgentSheet`);
  `widget_test` asserts the modal path.
- Phone path (< 600, cowork-c6) is untouched: `_buildPhoneBody` with
  `MobileChatScreen` / `MobileAgentList`, thread view kept mounted off stage
  behind the inbox. The WS-7 notification listener (c6) is intact and now has
  a test ("a tapped notification selects the thread it names").

**Deliberate divergences from chuk**, all written in the file's library doc:
the sidebar starts OPEN (a messenger's roster is its navigation); the compact
band ends at **720** instead of chuk's 600 (everything under 600 is the phone
layer, so a tablet-width window keeps chuk's compact behaviour: sidebar covers
the chat, picking a coworker folds it, the hamburger brings it back); opening
a panel folds the sidebar when both cannot fit next to a 300 px chat (chuk
drops the panel silently — at 800 px Control Rooms would look broken);
opening settings does not fold the sidebar.

### `CoworkShellHost` (`app/lib/pages/cowork_shell_state.dart`)

A mixin on `State<MessengerShell>`, a `part` of `messenger_shell.dart` (like
chuk's `desktop_send_logic.dart` is a part of `chat_ui_desktop.dart`, so the
private names stay shared). It holds everything the shell OWNS, above the
desktop/phone split: pairing store, roster, rooms, the `_controller`
notifier, pending host deletes, control source, theme controller bridge, the
thread view `GlobalKey` and `_buildThread()`, selection, `_restoreCloudPairing`,
the notification hooks, room CRUD + host sync, onboarding, delete-agent
cascade, Copy full chat, the control drawer. Two abstract members the layout
implements: `_select` and `_openModelScreen`. `_hostInit()` / `_hostDispose()`
are called from the state's `initState` / `dispose`.

Single-socket proof: `messenger_shell_test` "one socket across a wide, tablet
and phone resize" resizes 1200 → 660 → 420 → 1200 and asserts the relay
controller builder ran exactly once.

### Sidebar on chuk's `SidebarDesktop.build` skeleton (`widgets/agent_roster_view.dart`)

Top spacer `kTopInitialSpacing`; brand row exactly `kMenuButtonHeight` tall,
text starting right of the hamburger (`kFixedLeftPadding + kMenuButtonHeight +
4`); rail rows in `IntrinsicWidth` + `Column(stretch)` — New coworker,
Control Rooms (`onOpenRooms`), Agent's browser (`onOpenBrowser`); the list;
chuk's footer pill floating over the list's tail with the fade
(`onOpenSettings`, label `accountLabel ?? 'Account'`, gear with tooltip
`Settings`). Minus chuk's hosted `BalanceBadge` / `UpdateBanner`. The
CoWork-only collapsed avatar rail (`collapsed` / `onToggleCollapsed`) is
deleted — chuk's mini rail replaces it. `agent_roster_view_test` 22/22 (two
new: rail rows + gear fire; absent without callbacks).

### `AppShellConfig` handed down (cowork-8y2)

`main.dart` builds the config in `build()` (as before) and hands it through
`AuthGate(buildShell: (_) => MessengerShell(themeController:, shellConfig:))`
— `auth_gate.dart` (9e's file) is untouched, the seam already existed.
`CoworkApp.shellConfig` (the static) is gone. `MessengerShell.shellConfig` →
`CoworkThreadView.shellConfig` (new optional parameter; `_buildChat` reads
`widget.shellConfig`, import of `main.dart` removed — announced to and GO'd
by cowork-76). A shell without a config (widget tests) has no settings entry
(no footer pill) and the model entry falls back to the page route.

### Model entry (cowork-acu)

`_openModelScreen` → `showDesktopSettingsModal(context, config: …,
initialSectionId: 'model')` on desktop, `ModelSelectorPage()` as a route on
the phone (or without a config). Deleted: `pages/settings/model_settings_page.dart`,
`services/model_info_service.dart` (no other users), `test/pages/settings/
model_settings_page_test.dart` (was untracked). `settings_page_test`'s stale
comment pointing at that test was updated.

## Test results (this session, compiler window granted by cowork-76)

| what | result |
|---|---|
| `dart analyze` scoped (9 files) | 0 issues |
| `flutter analyze` (full) | 0 errors; the 5 pre-existing findings a4 reported at 06:56 (2 warnings `tool_image_result_service`, 3 infos chuk-verbatim / yaml) |
| `test/widgets/messenger_shell_test.dart` | 21/21 |
| `test/widget_test.dart` | 3/3 |
| `test/widgets/agent_roster_view_test.dart` | 22/22 |

Test changes, none weakening a statement: the two Copy full chat tests are
byte-identical and pass against the new slot. The onboarding test now asserts
the selection through the thread view's `threadKey` + the roster row instead
of an `AppBar` title. The tablet test asserts chuk's compact mechanic
(roster hittable + thread `Offstage`, selection folds, hamburger returns)
instead of `Icons.arrow_back`. Rooms tests: tooltip `Rooms` → `Control
Rooms`; because the room list is an inline panel now (not a route that put
the shell off stage and muted its tickers), three finders are scoped to the
`RoomCreateSheet` and the offline-delete test uses the file's bounded
`settle()` while the transport is pending.

## Traps found this session

- **`find.byType(X)` skips `Offstage` subtrees by default.** chuk's compact
  mode and the phone inbox keep the thread view mounted but off stage; use
  `find.byType(CoworkThreadView, skipOffstage: false)` (the test file has a
  `threadView` finder and a `threadOffstage()` helper).
- **A `ListTile` inside a coloured `Container` trips a debug assertion**
  ("ListTile background color or ink splashes may be invisible"). chuk's panel
  is a coloured `Container`; ours is `Material(color:) > DecoratedBox(border)`
  so `RoomListView`'s tiles have a Material to paint on.
- **Routes mute the tickers underneath; inline panels do not.** A test that
  passed with the rooms screen as a route can time out in `pumpAndSettle`
  once the same content is a panel next to an animating thread view.
- **Folded sidebar is off screen, not off stage.** `find.text('amber')` still
  finds the roster row after the fold; scope to the sheet or use
  `.hitTestable()`.

## Open

- **Live proof** after an app rebuild (c6 holds the instance, pid 288147 at
  08:33) and the user's "Bildschirm frei": hamburger fold/unfold, Control
  Rooms panel, browser panel + divider, Copy full chat top right, settings via
  the footer gear, phone layout at < 600. Screenshots →
  `docs/screenshots/shell/` (gnome-screenshot + convert crop, see 5c's
  handover), then `SendUserFile`.
- **cowork-eji (P3, cowork-13):** `BrowserViewPage` embedded mode without its
  own `Scaffold`/`AppBar` — the browser panel shows two headers today.
- Footer pill label: `accountLabel` is `null` from the shell (shows
  "Account"). chuk shows the profile display name; the shell could pass the
  signed-in e-mail once a session source exposes it.
- `pages/settings/{developer,embedding,herenow,mcp_connectors}_*` still under
  `pages/settings/` (cosmetic move from the plan, `mcp_connectors_page.dart`
  is cowork-47's — ask first).
- `services/settings/theme_controller.dart` still alive on purpose
  (`main.dart`, `auth_gate.dart`, `MessengerShell` take it).
- No commit. Files this session touched: `app/lib/pages/messenger_shell.dart`,
  `app/lib/pages/cowork_shell_state.dart` (new), `app/lib/widgets/
  agent_roster_view.dart`, `app/lib/main.dart`, `app/lib/widgets/
  cowork_thread_view.dart` (3 hunks, announced), `app/test/widgets/
  messenger_shell_test.dart`, `app/test/widget_test.dart`, `app/test/widgets/
  agent_roster_view_test.dart`, `app/test/pages/settings_page_test.dart`
  (comment), deletions listed above.

---

# Part 2 — P8 review + fix pass (bead cowork-4wd, same session)

`docs/REVIEW_2026-09-05_FLUTTER_P8.md` holds the Opus-5 review (review-only
subagent, scope `app/lib` minus `third_party/**`, `browser_view_page.dart` and
the chuk-verbatim manifest files) and, per finding, a **Status** line written
after the fix pass. 15 findings: 3 HIGH, 6 MEDIUM, 6 LOW. Fixed with a test
each: F1–F9, F13, F14, F15. Open: F10 and F12 (`services/mcp/**`, cowork-47's,
LOW), F11 (ledger, cowork-84).

Files this pass edited (all announced to and GO'd by cowork-76, owners
informed): `services/cowork/cowork_replay_loader.dart` (F1 request ordering by
`run_state` header / request order, queued same-thread request, F2 cache-miss
guard + `takeReplayWanted`, F13, `answerReadyRunFor`),
`services/websocket_chat_service.dart` (F3 replay guard for subagent / file /
approval, F14 no `run_ack` from the adapter), `services/cowork/
cowork_relay_client.dart` (F4 `_onSocketDone` releases the socket + `_reattach`
dial guard, F5 no ack with an empty `user_id`, F9 `sessionKey` on
`CoworkRelayApprovalRequest`, F15 comment), `widgets/cowork_thread_view.dart`
(F6 mounted check, F8 clear-then-act, F9 prompt only for the own thread, F2
re-request hook), `services/notifications/run_notifications.dart` (F7 dedup per
session/run), `services/notifications/cowork_notifications.dart` (additive
`runId` on `onAnswerReplayed`).

Results: full `flutter analyze` 0 errors (same 5 pre-existing findings);
replay_loader 25, websocket_chat_service 18, relay_client 51, thread_view 25,
thread_view_notifications 3, cowork_notifications 7, tool_card_parity 5,
run_ledger 17, messenger_shell 21 — all green.

Found on the side: `services/cowork/cowork_run_ledger.dart` carries four
literal NUL bytes in a doc comment (`"<sessionKey>\0<subagentId>"`); the
analyzer accepts it, `grep` calls the file binary. cowork-84 was told.

Beads: cowork-4wd closed (review pass done, 12/15 fixed). Its hardening items
are split out: cowork-sq3 (run_ack delivery confirmation, host arms a 15 s
timer at done), cowork-qxa (wall-clock guard for detached runs), cowork-axx
(replay paging for long threads); approval push is the existing cowork-kjl.5.

Open after this pass: live proof of the shell (Part 1) and of the F9 flow
(host #4 sends `session_key` on `approval_request`) after "Bildschirm frei".
Nothing committed.

---

# Part 3 — entry notes for the next session (beads cowork-4ih, cowork-817)

Both beads are the user's, P1, and were NOT started here (context budget).
Read `HANDOVER_2026-09-05_SHELL_SETTINGS_cowork-5c.md` first: 5c looked at
chuk's account page and dropped it for want of the services below.

**cowork-4ih — credits in the footer, Account settings 1:1 chuk.**
- Footer pill today: `widgets/agent_roster_view.dart`, `_footerRow` — chuk's
  pill minus the `BalanceBadge`; label `accountLabel ?? 'Account'` (the shell
  passes null). chuk's original: `~/git/chuk_chat/lib/platform_specific/
  sidebar_desktop.dart` `_buildFooterRow` (display name + `BalanceBadge` in an
  accent-tinted pill + gear). Put the badge back exactly there, so the pill
  reads as chuk's.
- chuk's Account page: `~/git/chuk_chat/lib/pages/account_settings_page.dart`
  (780 lines). Its imports that CoWork lacks: `services/profile_service.dart`,
  `services/password_change_service.dart`, `services/password_reset_service.dart`,
  `services/key_version_service.dart`, `pages/recover_chats_page.dart`,
  `widgets/settings_list_view.dart` (check `tools/chat_ui_manifest.txt` for
  what is already imported). `expressive_settings`, `theme_extensions`,
  `api_config_service`, `auth_service`, `supabase_service` exist. Port the
  services verbatim (add them to the manifest via `scripts/import_chat_ui.sh`),
  then the page verbatim; CoWork's own `pages/account_settings_page.dart` goes.
- Credits come from chuk's hosted account API (`ApiConfigService` → api.chuk.chat,
  bead cowork-zrq set the default); the badge's own service is the source —
  find it with `grep -rn "class BalanceBadge" ~/git/chuk_chat/lib`.

**cowork-817 — rename a coworker, create one with a name, chuk-style input.**
- Today: create = `widgets/agent_onboarding_sheet.dart` (the "kindergarten"
  form the user rejected), no rename at all. Data: `services/cowork/
  agent_roster_source.dart` (`addAgent(name:, role:, brief:, …)`; add a
  `renameAgent(id, name)` there and persist it like `hideAgent`).
- chuk's template for the dialog: `sidebar_desktop.dart` `_renameChatDialog`
  (line ~1222, `showDialog<String>` + `AlertDialog` with one `TextField`) and
  the row menu (`_showChatContextMenu`, ~1168). Reuse that dialog shape for
  Rename (row menu in `_AgentTile`, next to Hide/Delete) and for New coworker
  (name first; role/brief can stay optional behind the same dialog or the
  Agent controls drawer).
- Tests to extend: `agent_roster_view_test` (menu → Rename → source updated),
  `messenger_shell_test` "onboarding adds a coworker" (now a dialog, not a
  sheet).
