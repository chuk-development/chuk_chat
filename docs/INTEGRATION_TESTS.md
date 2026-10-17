# Integration tests with screenshots

The integration tests start the real app, drive it like a user and save one
PNG screenshot for each screen. They run on the Linux desktop target. On a
machine without a display, they run under `xvfb-run`.

Bead: `chuk_chat-ud2b`.

## Files

| Path | Content |
|------|---------|
| `integration_test/app_test.dart` | The walk through the main screens |
| `integration_test/support/shots.dart` | `takeShot()`: writes a PNG of the whole app |
| `lib/main.dart` | `appCaptureBoundaryKey`: the root `RepaintBoundary` |

The root `RepaintBoundary` exists only in debug and profile builds
(`!kReleaseMode`). A release build does not have it.

## What the test does

| Step | Screen | Screenshot |
|------|--------|------------|
| 1 | Sign-in page, with the test user filled in | `01_sign_in.png` |
| 2 | First screen after sign-in: empty chat and chat list | `02_chat_home.png` |
| 3 | The test sends a message. The API emulator answers `Echo: <message>` | `03_chat_answer.png` |
| 4 | New chat. The sent chat is in the chat list | `04_chat_list.png` |
| 5 | The test opens the chat from the chat list | `05_chat_open.png` |
| 6 | Settings | `06_settings.png` |

The app window is 1280x720 (the default size of the Linux runner). The
desktop layout is used. The screenshots are 1280x720 PNG files.

The screenshots go to `build/integration_shots/`. The test finds the
repository root from the path of the app executable.
`--dart-define=INTEGRATION_SHOTS_DIR=<dir>` sets a different directory.

The test refuses to start when `API_BASE_URL` or `SUPABASE_URL` is not a
loopback address. It never talks to production.

## Run the tests

1. Start the local stack, if it does not run. Do not stop a stack that
   another agent uses.

   ```bash
   E2E_EMULATOR_PORT=8797 scripts/e2e_stack.sh up
   ```

   The defines file is `_scratch/e2e.defines.json`. See `docs/E2E_STACK.md`
   and `docs/API_EMULATOR.md`.

2. Run the test. The XDG variables give the app its own data directory.
   Without them, the test app uses `~/.local/share/dev.chuk.chat`. That is
   the data directory of the installed app: the test would replace its
   session and its chat cache.

   ```bash
   H="$PWD/_scratch/it_home"
   rm -rf "$H" && mkdir -p "$H/data" "$H/cache" "$H/state"
   CHUK_MULTI_INSTANCE=1 \
   XDG_DATA_HOME="$H/data" XDG_CACHE_HOME="$H/cache" XDG_STATE_HOME="$H/state" \
   xvfb-run -a -s "-screen 0 1440x900x24" \
     flutter test integration_test/app_test.dart -d linux \
     --dart-define-from-file=_scratch/e2e.defines.json
   ```

   - `rm -rf "$H"` removes the session of the last run. The test expects the
     sign-in page as the first screen.
   - `CHUK_MULTI_INSTANCE=1` lets the test app start when the installed app
     runs. Without it, the Linux runner single-instance lock stops the test
     app.
   - On a desktop with a display, you can remove `xvfb-run` and its options.

3. Look at each PNG in `build/integration_shots/`. A test that passes is not
   proof that the screens are correct. Make sure that each image shows the
   expected screen, not a blank or error screen.

A first run builds the Linux debug app. This takes some minutes. A run with
a warm build takes about 75 s.

## Test data

The test signs in as the E2E test user (`docs/E2E_STACK.md`). At the start,
the test deletes all chats of this user in the local Supabase (the row-level
security policy lets a user delete their own rows). Then it sends
`POST /__emulator/reset` to the API emulator. This clears the script queue,
so the default echo turn gives the answer.

## Byte-stable screenshots

Two runs give the same PNG bytes for all six screenshots. Three things make
this true:

- `EditableText.debugDeterministicCursor = true`: the caret is drawn solid
  and does not blink. `test_driver/main_agent.dart` sets it too.
- The test deletes the old chats of the test user, so the chat list has one
  entry in each run.
- `debugSbChatTimeOfDayOverride = '12:00'`
  (`lib/widgets/sidebar/sidebar_chrome.dart`): the chat list shows a fixed
  time for chats from today. Release builds ignore it.

Give each run new, empty XDG folders (the `rm -rf "$H"` in the command
above). An old local chat cache adds chats to the list.

## Write a new test

- Use `tester.pump()` in a loop with a time limit. Do not use
  `pumpAndSettle()`: the app has animations that do not stop, so it never
  settles. `app_test.dart` has `_pumpUntil()` and `_settle()`.
- Find widgets by Semantics identifier (`find.bySemanticsIdentifier`), by
  tooltip or by localized text from `AppLocalizations`. Do not use fixed
  English strings when a localized string exists.
- Call `takeShot(tester, '<NN>_<name>')` after each screen. Use a two-digit
  prefix, so the files sort in the order of the walk.
- Do not use real network services. Use the local stack only.
