# Tablet: emulator and layout

## The tablet AVD

```bash
scripts/emulator.sh start --tablet     # create + boot cowork_tablet_x64
scripts/build_apk.sh --emulator        # build, install, launch on it
scripts/emulator.sh shot _scratch/tablet/shot.png
scripts/emulator.sh stop
```

- AVD `cowork_tablet_x64`: Pixel Tablet profile, 2560x1600 px at 320 dpi
  (1280x800 dp), x86_64, the same `android-36;google_apis;x86_64` image as
  the phone AVD (no new download), 6 GB data partition. Headless
  (`-no-window`).
- Only one emulator runs at a time. `start --tablet` stops a running phone
  AVD first, and `start` stops a running tablet AVD. Thus
  `scripts/build_apk.sh --emulator` always installs on the AVD that was
  started last.
- Rotate the screen:

  ```bash
  adb -s emulator-5554 shell settings put system accelerometer_rotation 0
  adb -s emulator-5554 shell settings put system user_rotation 0   # landscape
  adb -s emulator-5554 shell settings put system user_rotation 1   # portrait
  ```

## Which layout a window gets

One rule, `MobileLayout.isPhoneSize` (`lib/platform_specific/mobile/mobile_layout.dart`):

| Where | Rule |
|---|---|
| `PLATFORM_MOBILE=true` build | always the phone layout |
| Android, iOS | the window's **shortest side**: below 600 dp = phone layout, 600 dp and more = wide (desktop-like) layout |
| Linux, Windows, macOS, web | the window's **width**: below 600 dp = phone layout |

- A rotation never changes the answer. A phone in landscape keeps the phone
  layout; a tablet in portrait keeps the wide layout. Thus a rotation keeps
  the open chat, its scroll position and its draft.
- Only a split-screen or freeform window that crosses 600 dp changes the
  layout. Then the chat screen changes from `ChukChatUIDesktop` to
  `ChukChatUIMobile` (or back). `ComposerDraftCarry` moves the draft to the
  new screen. The Agents thread view has a `GlobalKey`; its socket stays.
- Inside the wide layout, the width folds the side panes: chuk's sidebar is
  folded by default (the mini rail); the Agents roster folds to the rail of
  faces when roster, thread and right pane do not fit. A tablet in portrait
  (800 dp) is in this "medium" class.

## What a tablet changes in the wide layout

`MobileLayout.isTouchPlatform` (Android or iOS) switches these on. A desktop
OS does not change.

- No hover-only controls: beside an Agents bubble, only "more" shows, at
  all times, as a 48 dp target (its menu also has react and reply). A long
  press on the bubble selects text in the wide layout. A sidebar row (chats,
  agents) opens its context menu on a long press, as a right click does with
  a mouse.
- Screenshots without a device: `CHUK_TABLET_SHOT=<dir> flutter test
  test/platform_specific/tablet_layout_test.dart` (Chats) and the same
  variable with `test/widgets/messenger_shell_test.dart --name CHAT-150`
  (Agents) write PNGs at tablet sizes.
- System back: in Chats it closes the artifact panel, then the sidebar. In
  Agents it closes the right pane, then a room, then goes to Home. Then the
  app closes.
- The desktop wrapper reads `MediaQuery.sizeOf`, so the keyboard animation
  does not rebuild the whole window.

Tests: `test/platform_specific/tablet_layout_test.dart`.
