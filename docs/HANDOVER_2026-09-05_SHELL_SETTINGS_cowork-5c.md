# Handover — shell and settings (session cowork-5c, 2026-09-05)

Everything below is **uncommitted** in the shared working tree. Nothing in this
session was committed; the user gives that word.

## Where P3 and P4 stand

### P4 — settings: DONE

chuk_chat's two settings surfaces are live in `app/lib/pages/`:
`settings_page.dart` (1155 → 602 lines) and `desktop_settings_modal.dart`
(794 → 662). CoWork's old hub (`pages/settings/settings_page.dart`) and
`pages/settings/theme_settings_page.dart` are gone; `_p4_pending/` is empty and
deleted. The section map, the per-page decisions and why `account_settings_page`
and `system_prompt_page` were dropped rather than adapted are written up in
`HANDOVER_2026-09-04_FLUTTER_ALIGN.md`, section "P4-rest: what the section map
decided".

`MessengerShell._openSettings` opens chuk's hub. It needs an `AppShellConfig`
and takes it from `CoworkApp.shellConfig` — the same static `cowork_thread_view`
already reads — with a new injectable `MessengerShell.shellConfig` seam so a
widget test can open settings without `CoworkApp` around it. A null config makes
the entry a no-op instead of a crash. Bead `cowork-8y2` replaces that static
with a value handed down the tree; do that and both readers get simpler.

Still open in P4's neighbourhood:

- `pages/settings/model_settings_page.dart` is still the pass-through wrapper
  and `MessengerShell._openModelScreen` still pushes it. The plan wants that
  entry re-pointed at `showDesktopSettingsModal(initialSectionId: 'model')` on
  desktop / `ModelSelectorPage` on mobile — same `VoidCallback` — and the
  wrapper plus `services/model_info_service.dart` deleted.
- `services/settings/theme_controller.dart` survives on purpose: `main.dart`,
  `auth_gate.dart` and `MessengerShell` still take it. Do not delete it as part
  of "chuk owns theme now" without checking those three.
- `pages/settings/{developer,embedding,herenow,mcp_connectors}_*` still live
  under `pages/settings/`. The plan moves them to `pages/`; the hubs import them
  where they are, so the move is cosmetic and was left undone. **Do not move
  `mcp_connectors_page.dart` without asking — it is cowork-47's file.**

### P3 — shell: sidebar redesigned, the rest NOT started

Done: `widgets/agent_roster_view.dart` was rebuilt on chuk's own sidebar chrome
(`widgets/sidebar/sidebar_chrome.dart`). Every colour comes from
`SidebarTokens.of(context)` — the file defines none of its own — with `SbBrand`,
`SbRailRow` for "New coworker", `SbSectionLabel` for the Working / Scheduled /
Waiting / Hidden buckets and `SbHairline`. The agent row is the one bespoke
widget (`_AgentTile`): `SbChatTile` is single-line and a coworker needs two
lines, so the tile reproduces its grammar exactly — 12 px radius, an
always-reserved 1.5 px border so selection changes only colour and never the
list's layout, accent @0.18 fill with accent @0.55 edge, iconFg @0.05 hover, the
same 110 ms cross-fade, and chuk's streaming glow on a working agent.
`agent_roster_view_test` 20/20.

c6's mobile diff (`docs/diffs_c6_messenger_shell.md`) is applied, with **one
addition that is not in the diff**: c6's `_buildPhoneBody` mounted only
`MobileAgentList` on the inbox screen, so `CoworkThreadView` — the widget that
builds the relay controller and reports pairing — was not in the tree at all. A
phone would have had no socket until the user opened a chat: no reconnect, no
run adoption, and a roster that never learns about the paired host. The inbox
branch is now `Stack(Positioned.fill(Offstage(buildThread(phone: true))),
Positioned.fill(MobileAgentList(...)))`, which is chuk's own
`Positioned.fill(Offstage(chatArea))` pattern from plan WS-1. It was found by a
test, not by reading: `roster.agents.single` threw "Bad state: No element" after
`controller.pair()`.

NOT started, and the next session's job: bead `cowork-b6h` (the root_wrapper
layout — the `AppBar` in `messenger_shell.dart` disappears, the four top-right
actions move into chuk's floating `Positioned` row, **including the Copy full
chat button that currently lives in that AppBar**), `cowork-8y2` (AppShellConfig
handed down instead of the static), and `pages/cowork_shell_state.dart` with the
`CoworkShellHost` mixin. Plan detail: `PLAN_2026-09-04_COWORK_CHUK_ALIGN.md`,
WS-1.

## File ownership held by this session

`pages/messenger_shell.dart`, `pages/settings_page.dart`,
`pages/desktop_settings_modal.dart`, `pages/account_settings_page.dart`,
`pages/about_page.dart`, `pages/customization_page.dart`,
`pages/skills_settings_page.dart`, `pages/theme_page.dart`,
`pages/settings/model_settings_page.dart`, `pages/login_page.dart`,
`widgets/agent_roster_view.dart`, `model_selector_page.dart`,
`widgets/model_selection_dropdown.dart`, `widgets/chat_mode_selector.dart`,
`services/chat_mode_service.dart`, `services/model_capabilities_service.dart`,
`services/api_config_base.dart`, `platform_specific/chat/chat_scroll_mixin.dart`,
and their tests, plus `test/support/shell_config.dart`.

Off limits (other sessions): `widgets/cowork_thread_view.dart` (cowork-47 for
notification hooks, cowork-9e for one approval guard), `services/mcp/**`
(cowork-47), `services/cowork/**`, `services/supabase_service.dart` and
`widgets/auth_gate.dart` and `main.dart`'s session-recovery lines (cowork-9e),
`platform_specific/mobile/**` (cowork-c6), `third_party/**` and
`widgets/browser_view_page.dart` (cowork-13).

## Traps that cost this session time

**`flutter-hot stop` and `reload` can wedge.** Both write a key into the control
FIFO and that write can block forever: `flutter-hot result` sat at `pending` for
300+ seconds, the app log never printed "Performing hot reload", and the process
was healthy throughout. `flutter-hot send r` hung the same way. `flutter-hot
kill` goes straight for the pid and always worked; a normal `start` follows.

**Screenshots need `gnome-screenshot`, not `flutter-hot shot`.** The session is
Wayland: `xdotool` / `wmctrl` / `import` cannot see the window (`wmctrl -l` is
empty), `grim` fails with "compositor doesn't support wlr-screencopy-unstable-v1"
and the GNOME screenshot D-Bus method answers "Screenshot is not allowed". What
works is `gnome-screenshot -f <file>` plus an ImageMagick crop to the window.
Delete the full-screen capture afterwards — it contains every other session's
terminal, and it must not land in the repo.

**Pending-timer failures in settings tests.** The imported settings pages
schedule a delayed developer-options refresh in `initState`. The binding checks
for pending timers at the END of the test body, BEFORE `addTearDown` callbacks,
so cleaning up in `addTearDown` is too late and the test fails with "A Timer is
still pending even after the widget tree was disposed". Dispose inside the body:
`pumpWidget(const SizedBox.shrink())`, pump a second, settle. See
`closeSettings` in `test/pages/settings_page_test.dart`.

**Do not mount `ModelSelectorPage` in a unit test.** Its `initState` refreshes
the Supabase session and fetches `/v1/models_info`; the test has neither and it
dies with "Call SupabaseService.initialize() before accessing the client",
followed by a `pumpAndSettle` timeout. Build it without mounting (see
`test/pages/settings/model_settings_page_test.dart`) or assert reachability only.

**Widget tests that reach the imported chat UI need the l10n delegates.**
`AppLocalizations.of(context)!` is a hard null check inside chuk's screens. Pump
through `testApp(...)` / `kTestLocalizationsDelegates` from
`test/support/test_app.dart`, or the screen dies on mount with "Null check
operator used on a null value" and the real failure is invisible.

## Waiting for the next session: c6's notification diff

`docs/diffs_c6_notifications_shell.md` is a second, additive diff for
`pages/messenger_shell.dart` (bead `cowork-o3j`, P7): two imports, a listener on
`NotificationRouter.instance.pending` plus `CoworkNotifications.instance
.threadLabel` in `initState`, a post-frame call for the cold start, the matching
`removeListener` in `dispose`, and a new `_onNotificationTap` that does
`take()` → `_select(agentId, sessionKey)` → `onOpenedFromNotification`. The
services live under `lib/services/notifications/` and analyse clean.

It is **not applied**. This session stopped at its context limit rather than
land a shell change it could not fully verify, and c6 was told. Apply it
together with the `cowork-b6h` rework — both touch the same file.

## Running the app instance

The app is the shared instance every session watches. It runs **without**
`PRODUCTION_API_URL`, deliberately: that proves `api_config_base`'s new debug
default (bead `cowork-zrq`) and the model catalogue then comes from the account
backend anyway.

```bash
cd /home/user/git/cowork/app
export FLUTTER_HOT_EXTRA="--dart-define=SUPABASE_URL=https://xooposctxswumvgtyqlg.supabase.co --dart-define=SUPABASE_ANON_KEY=sb_publishable_g4Yz0bTZPB27ig8E1ROGzw_rprl-7U7 --dart-define=FEATURE_VOICE_MODE=false --dart-define=FEATURE_WORKSPACES=true --dart-define=FEATURE_ARTIFACTS=true --dart-define=FEATURE_SERVER_TOOLS=true --dart-define=FEATURE_SKILLS=true --dart-define=FEATURE_SYSTEM_TRAY=true --dart-define=FEATURE_PAYMENTS_DIRECT=true --dart-define=FEATURE_LINUX_KEYRING=false"
flutter-hot kill 2>/dev/null   # `stop` can wedge; kill is the reliable way
flutter-hot start linux
flutter-hot status             # pid
flutter-hot logs | tail -40    # reconnect + "[ModelCapabilities] Initialized with N models"
```

A host restart needs no click: the app reconnects on its own. Confirm it in
`/home/user/.claude/flutter-hot/1572042725/run.log` by counting
`reconnecting to ws` — a new, complete `hello` / `response` / `confirm` sequence
means it is back. Do not trust "looks fine": before Host #2 the old host was
still alive and no second sequence had appeared yet.

## Beads

Closed here: `cowork-ipm` (Copy full chat button), `cowork-ejc` (streaming
scroll jump — fixed in chuk_chat master first, then ported byte-identically;
the fix is UNCOMMITTED in `~/git/chuk_chat`, the user commits it there),
`cowork-tfp` and `cowork-73z` (settings tests were stale, not broken; the hub had
grown and `Theme` fell below the fold).

Open and mine: `cowork-b6h`, `cowork-8y2` (both P3), `cowork-zrq` (the debug API
default is fixed and unit-tested; the later option of carrying the catalogue over
the relay frame is still open), `cowork-hxh` (P4 model dropdown — claimed, the
work is done, close it after the model entry is re-pointed).

Known from other sessions, not mine to fix: cowork-b5 found that
`ChatModeService`'s Thinking default `medium` is invalid for `glm-5.3-flash`
(`low,high,max`) and `deepseek-v4-pro-0813` (`none,low,high,max`), and the app
does not clamp on a cold cache, so the backend returns no reasoning. b5 clamps
host-side in Python; the Dart clamp is a separate bead, to be fixed in chuk_chat
master first and then re-imported.
