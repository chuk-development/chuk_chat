# Handover: phone UI of the Agents build (2026-11-05)

> **Changed on 2026-11-13 (CHAT-109).** The owner wants the sidebar back:
> without a list he could not see which Sidekick had news. Now: one top row
> (menu chip, title pill, "..." chip, add button). The menu chip opens a
> full-page sidebar: `SidebarMobile` in the Chats half, `MobileAgentList` in
> the Sidekicks half, the switch Home | Chats | Sidekicks as the head of
> both. One open state for both halves (`_phoneSidebarOpen` in
> `messenger_shell.dart`). The swipe between chats stays. A pull up at the
> end of a chat makes a new one (`pull_up_to_create.dart`). The text below
> is the state before that.

Read this first, then `CLAUDE.md`. Bead: `chuk_chat-2gku` (still open).

## What the owner wants (his words, condensed)

- On top: **Home | Chats | Agenten** (a switch). Home is the dashboard the
  agents edit. It is a segment of its own, not a page you swipe to.
- No sidebar, no bottom nav bar, **no dropdown, no list, no overview**.
- Under the switch a wide strip with the name of the chat in view.
- Swipe left or right (on the strip, and on the chat) for the next or
  previous chat. You always stay in the same chat UI.
- Input box always at the bottom.
- **Latest instruction (15:05):** the chat body must NOT slide. Only the chat
  name in the strip animates. The next or previous chat name must NOT show
  (no peeking neighbours).
- He also said it still looks bad ("immer noch hingeschissen"). The old
  sidebar looked good; the new chrome must be as good. Take care with the
  design and check it on a real image, not only on the code.

## State

Pushed: nothing yet. Committed locally on `master`:

- `e27e1e97` feat(agents): dashboard store, tool and frames on the host.
- `686f9e4b` feat(phone): the swipe UI, Home as a switch segment, a carousel
  strip with peeking neighbours, rename and delete in the menu.

Uncommitted (made after `686f9e4b`, from the 15:05 instruction):

- `lib/platform_specific/mobile/swipe_chat_pager.dart`: new
  `moveChild` flag (default true). False keeps the child still; the swipe
  only switches.
- `lib/pages/messenger_shell.dart` and
  `lib/platform_specific/root_wrapper_mobile.dart`: they pass `moveChild: false`.
- `lib/platform_specific/mobile/chat_title_strip.dart`:
  - It draws only the current entry.
  - It follows `controller.progress`, which runs out to ±1, jumps, and comes
    back from ∓1. The name rides the finger out, fades, and the new name
    slides in from the other side.
  - No neighbours, no edge-tap zones. The dots are static at the index.
- `flutter analyze` is clean. **The tests are not updated yet.** These tests
  expect peeks, edge taps and a moving child, and will fail:
  - `test/platform_specific/mobile/chat_title_strip_test.dart` (peeks, edge
    taps, the carousel moving neighbours)
  - `swipe_chat_pager_test.dart` (child offset checks; they still pass with
    the default `moveChild: true`, so add one test for `false`)
  - `test/widgets/messenger_shell_test.dart` and
    `test/platform_specific/root_wrapper_mobile_swipe_test.dart`, where they
    check the peek keys `chat_title_strip_<id>` or the body offset.
- The x86 APK with these changes was built for the emulator
  (`scripts/build_apk.sh --emulator`). The phone still has the build from
  `686f9e4b` (the one with peeks).

## Next steps

1. Update the tests to the 15:05 behaviour. Run `flutter test` (full; the
   last full run was green at `686f9e4b`, 5773 tests).
2. Make the strip look good:
   - Ideas: a calm title slide with a cross-fade; a subtitle line (last
     message or date); the dot row. Maybe no dots if he finds them noisy;
     ask.
   - Check it on the emulator: `scripts/emulator.sh shot _scratch/x.png`,
     then look at the image.
   - Compare with the old sidebar (`lib/widgets/sidebar/`) for the look.
3. CodeRabbit is not logged in. The owner must run `coderabbit auth login`
   once (interactive). Then run
   `coderabbit review --uncommitted --include-untracked` in the background,
   fix the findings, commit and push `master`.
4. Build arm64 (`scripts/build_apk.sh`) and install it on his Pixel when he
   plugs it in. Close `chuk_chat-2gku` when he is happy.

## Known follow-ups (beads)

- `chuk_chat-j2vp`: the keyboard opens after a swipe to another chat.
- `chuk_chat-9hav`: the tour anchor is missing on the swipe-mode menu chip.
- `chuk_chat-uews`: `SwipeChatPagerController.drag*` ignore `enabled`.

## Where things are

- Top bar: `lib/platform_specific/mobile/mobile_top_bar.dart`
  (`MobileTopBar`, `strip` is null on Home, `kMobileTopBarRowOnlyHeight`).
- The switch: `lib/widgets/app_mode_switch.dart`. `onHome` gives the third
  segment. Phone only; on desktop it has two segments.
- Agents phone body: `messenger_shell.dart`:
  - `_buildPhoneBody`, `_phoneEntries` (agents and rooms, no Home),
    `_buildModeSwitch`
  - Home = `_agentsHomeShown` in `agents_shell_state.dart`.
- Chats phone body: `root_wrapper_mobile.dart` (`_buildSwipeLayout`,
  `_openSwipeMenu`; rename and delete of the current chat are there).
- Swipe: `swipe_chat_pager.dart`. Its recognizer wins against SelectionArea
  with Android's touch slop; see the class doc of `_ChatSwipeRecognizer`.

## Emulator (for remote work)

- `scripts/emulator.sh start|status|shot <png>|stop`. Headless
  (`-no-window`), x86_64 AVD `cowork_x64`, about 5 GB RAM.
- `.env.maestro` test credentials are invalid ("Invalid login credentials").
  The emulator app needs a manual login.
- T3 Code has a Device panel: the agent tools `device_list`,
  `device_open`, `device_screenshot` and `device_close` show an Android
  emulator in the T3 UI, also remote. They need "Agent device access" on
  (T3 Settings > Integrations > Devices) and then a new thread. On
  2026-11-05 this switch was off. When you use the panel, do not start the
  AVD with `scripts/emulator.sh start` first: `device_open` boots
  `cowork_x64` itself, and an AVD can run only once.
- To see the emulator from another device: `scrcpy` over adb, or the
  `android-emulator.service` in CT 100 `t3code` on pve. That one is a
  different emulator, on another host.
