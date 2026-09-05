# Handover — mobile layer (session cowork-c6, 2026-09-05)

Where it landed in git: the mobile layer, its tests, the previews and the two
mobile docs are in commit `6d7f75e` — under another session's subject
("feat(settings): …"), because two sessions committed from the shared index
at the same moment and that commit swallowed the staged files. The content is
complete there; `git show --stat 6d7f75e -- app/lib/platform_specific/mobile`
lists it. The notifications work is commit `2790c89` (its own message).

Task from the user: make the CoWork app feel like a messenger on a phone,
modelled on the **Grok Bot** app (xAI). Design source: Mobbin only (user's
instruction); website images only for desktop inspiration.

## What exists

- `docs/MOBILE_GROKBOT_STRUCTURE.md` — the observed Grok Bot structure
  (home = inbox of bots, chat with floating chrome, composer, profile,
  onboarding), the mapping to CoWork, the rules (touch targets, safe areas,
  keyboard, back, breakpoint), the file plan and the diff proposals.
- `app/lib/platform_specific/mobile/` — the mobile layer, all new files, no
  verbatim chuk file edited:
  - `mobile_layout.dart` — breakpoint (600 dp on every platform, plus real
    phones), chip size 48, bar height 62, `isPhone`, `isPhoneWidth`,
    `chromeInset`.
  - `mobile_chips.dart` — round surface chip, accent chip, chip shadow, the
    bar fade.
  - `mobile_presence_avatar.dart` — `AgentAvatar` + presence dot (green
    working, amber scheduled).
  - `mobile_chat_chrome.dart` — floating top bar: back chip, bot pill,
    browser chip, more chip.
  - `mobile_chat_screen.dart` — chrome over the body, `topInset` to the
    body builder, `PopScope`, left-edge swipe back.
  - `mobile_agent_list.dart` — inbox list with floating home bar (account,
    search with inline filter, add), rows with role tag, time, preview.
  - `mobile_agent_sheet.dart` — the "more" bottom sheet (controls, rooms,
    copy full chat, settings, sign out).
- `app/test/platform_specific/mobile/` — `mobile_support.dart` (phone-sized
  localised harness, `findId`, real-font loader), chrome 5, screen 4, list 9,
  sheet 1 tests, and `mobile_preview_test.dart` (goldens → PNGs).
- `app/lib/widgets/cowork_thread_view.dart` — two new optional parameters,
  `topInset` (→ `ChukChatUIMobile.topInset`) and `phoneLayout` (forces
  chuk's phone screen). Defaults keep every existing caller unchanged.
- `docs/diffs_c6_messenger_shell.md` — the exact diff for cowork-5c's
  `messenger_shell.dart` (phone branch: no AppBar, `MobileAgentList` /
  `MobileChatScreen`).
- `docs/screenshots/c6/preview_*.png` — rendered previews at 390×844 (from
  the golden test, real Roboto + Material Icons).

## Harness notes (so the next session does not re-learn them)

- The imported chuk screens need `AppLocalizations`; `testApp()` from
  `test/support/test_app.dart` installs the delegates. They load
  asynchronously, so the first frame after `pumpWidget` is EMPTY — pump once
  more before any finder.
- `find.bySemanticsIdentifier` needs a live semantics handle, and a handle
  left open fails the test at teardown. `findId()` in `mobile_support.dart`
  matches the `Semantics(identifier:)` widget directly instead.
- A swipe in tests: `tester.flingFrom(...)`. Hand-built `moveBy` with 50 ms
  gaps trips the velocity tracker's 40 ms "pointer stopped" rule → velocity 0.
- `PopScope(canPop: false)` under `Navigator.maybePop()` returns TRUE
  ("handled") and calls `onPopInvokedWithResult(didPop: false)`.
- Previews: `flutter test test/platform_specific/mobile/mobile_preview_test.dart --update-goldens`
  rewrites the PNGs; a plain run compares. Shadows are enabled in that test.

## Verbatim files

None edited. `chat_ui_mobile.dart` keeps its `topInset` parameter from
upstream; the mobile chrome uses it exactly like chuk's own
`root_wrapper_mobile.dart` does (62 dp bar + status-bar inset).

## Rule learned (2026-09-05, found by cowork-5c)

**The thread view stays in the tree on every phone screen.** My first shell
diff mounted only `MobileAgentList` on the inbox screen. Wrong: the
`CoworkThreadView` owns the relay controller — reconnect from the stored
pairing, `onPaired` (host agent into the roster), adoption of a run in
flight. Without it the phone gets its socket only when a chat is opened. 5c
fixed it: inbox = `Stack[Positioned.fill(Offstage(thread)),
Positioned.fill(MobileAgentList)]`, chuk's pattern. Tests: phone 420 px
inbox → chat → back, tablet 660 px. Shell diff is applied; bead
`cowork-6x2.3` closed.

## Open

- Shell diff applied by cowork-5c; next the Linux app at a narrow window
  (< 600 dp) shows list → chat → back. Proof by screenshot
  (`gnome-screenshot -f …` + `convert` crop → `docs/screenshots/c6/`).
- Bubbles stay chuk's (assistant full-width, user bubble). Grok Bot bubbles
  both; that would be an upstream change in chuk_chat, not here.
- Bot profile opens the existing end drawer (`AgentControlPanel`); a bottom
  sheet in Grok Bot's shape is a follow-up.
- Beads: `cowork-6x2` (epic), `.1` chrome/screen, `.2` list, `.3` shell +
  thread-view diffs.

---

# Part 2 — P7 app-side notifications (bead cowork-o3j, same session)

Spec: `docs/PLAN_2026-09-04_COWORK_CHUK_ALIGN.md` WS-7 ("App:", reopen flow,
anti-duplicate rule). Host side was already done (`host/notify.py`,
`host/desktop_notify.py`, `supabase/functions/notify-run`, schema in
`docs/SUPABASE_SCHEMA.md`).

## Files

- `app/lib/services/notifications/notification_router.dart` — a tap names
  ONE thread (`session_key`, optional `run_id`); the shell takes it.
- `app/lib/services/notifications/local_notifications.dart` — chuk's
  `notification_service_io.dart` ported: Linux ON, no answer content, one
  toast per thread (id = hash of the session key, Android tag = session key,
  the same tag the FCM push uses so one cancel clears both). Plugin behind
  `LocalNotificationsBackend` (tests use a fake).
- `app/lib/services/notifications/push_service.dart` — FCM token ↔
  `cowork_device_tokens` keyed by the CoWork device id; sign-in upsert,
  `onTokenRefresh`, sign-out delete, tapped/cold-start push → router.
  `FirebasePushTransport.initialize()` is guarded: no keys / Linux → push
  off, nothing else changes. Background handler is a registered no-op (the
  push is a `notification` message with no content to process).
- `app/lib/services/notifications/run_notifications.dart` — PATCH
  `consumed_at` on `cowork_run_notifications` (by session key, by run id);
  idempotent per launch; Supabase-less in tests via `configure()`.
- `app/lib/services/notifications/cowork_notifications.dart` — the facade:
  `initialize()`, `onLiveDone(sessionKey)` (toast only when
  `WidgetsBinding.lifecycleState != resumed`; null = foreground),
  `onAnswerReplayed(sessionKey)` (consume + cancel), `onOpenedFromNotification`,
  `threadLabel` resolver the shell sets to the coworker's name.
- `app/lib/services/notification_service.dart` — the chuk-compatible static
  API the verbatim `streaming_manager_io.dart` calls; delegates, drops the
  content preview. (chuk's `_isAppInBackground` flag is never set in CoWork,
  so that path is dormant; the live path is the thread view hook.)
- `app/lib/main.dart` — one additive line:
  `unawaited(CoworkNotifications.instance.initialize())`.
- `app/lib/widgets/cowork_thread_view.dart` — two hooks: `onLiveDone` after
  the `run_ack` in `case CoworkRelayDone`, `onAnswerReplayed` in
  `_onLoaderChanged` when `answerReadyFor(threadKey)`. No
  `WidgetsBindingObserver` needed — the facade reads the binding's
  `lifecycleState` (deviation from the coordinator's wording, same effect,
  one fewer contested edit).
- Android: `AndroidManifest.xml` (INTERNET, POST_NOTIFICATIONS, VIBRATE; FCM
  meta icon/colour/channel `cowork_answer_ready`), `res/drawable/ic_notification.xml`,
  `res/values/colors.xml`, `app/build.gradle.kts` applies
  `com.google.gms.google-services` ONLY when `android/app/google-services.json`
  exists (declared in `settings.gradle.kts` 4.4.2). So the build never needs
  the file; dropping it in turns push on.
- `app/lib/pages/messenger_shell.dart` — APPLIED by c6 (76's decision, 5c
  had closed): `dart:async` + 2 imports, router listener in `initState`,
  `threadLabel` resolver (coworker name), post-frame cold-start pick-up,
  `removeListener` in `dispose`, `_threadLabel`, `_onNotificationTap`
  (take → `_select` → `onOpenedFromNotification`). Record:
  `docs/diffs_c6_notifications_shell.md`.
- Tests: `test/services/notifications/{local_notifications,push_service,cowork_notifications}_test.dart`,
  `test/widgets/cowork_thread_view_notifications_test.dart`.

## Test results (2026-09-05)

local_notifications 8/8, push_service 6/6, cowork_notifications 6/6,
cowork_thread_view_notifications 3/3, messenger_shell 16/16; `dart analyze`
0 on every touched file.

## Still open

- Live proof after "Bildschirm frei": close the app, let a run finish, see
  the host's desktop toast (host side); background the app during a run,
  see the app's own toast (this work); tap → thread opens, row consumed.
- Android push needs `google-services.json` from the user (Firebase project
  with the APK's package `dev.chuk.cowork`) plus the Edge Function secrets
  `FCM_PROJECT_ID` / `FCM_SERVICE_ACCOUNT`.

## Review fixes by cowork-f7 (P8, 2026-09-05) — F7/F8

- F8: the thread view clears `answerReady` (`_loader.clearAnswerReady`)
  right before `onAnswerReplayed`, so a re-entry of `_onLoaderChanged` sees
  false and nothing double-fires.
- F7: the loader remembers the `run_id` of the `while_away` done
  (`answerReadyRunFor`); the thread view passes it to
  `CoworkNotifications.onAnswerReplayed(sessionKey, {runId})` (additive
  signature); `RunNotifications.consumeForSession` dedups per
  (session, run_id), and per session when no run id is known — the
  per-launch set is no longer the only guard.
- Tests after the fix: cowork_notifications 7/7, thread_view_notifications
  3/3 (third case extended: a `run_state` afterwards → no second
  consume/cancel).
