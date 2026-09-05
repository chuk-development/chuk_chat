# Mobile structure — CoWork as a messenger, modelled on Grok Bot

Session cowork-c6, 2026-09-05. Source of truth for the design: **Mobbin** (the
user's instruction: Mobbin for mobile, nothing else). Screens and flows read
from the Mobbin app entry "Grok Bot" (xAI, iOS). Website images are allowed for
desktop inspiration only.

Mobbin flows used:
- Chatting with Grok Bot — https://mobbin.com/flows/22073a81-38e2-452b-a0d6-7cfb587b8c0c
- Chatting with Grok Bot (mentioning a bot) — https://mobbin.com/flows/4fb28b2d-90f8-43cf-a2c7-053afe440731
- Chatting with Grok Bot (image) — https://mobbin.com/flows/bde592ea-9eb9-49ea-97f6-c5f30d6a6e73
- Chatting with Grok Bot (dictation) — https://mobbin.com/flows/a7313ca5-5a0b-409f-be25-2884c0733c4c
- Adding a bot — https://mobbin.com/flows/f1a5b515-7abb-4cd8-a993-499bb61e9c0f
- Bot profile — https://mobbin.com/flows/6415ca5c-7ec6-49a7-b9da-2e97af7f5476
- Editing bot profile — https://mobbin.com/flows/de710871-0f9f-4098-a99a-5213a621d99d
- Logging out — https://mobbin.com/flows/5c6c6eb6-20ee-4b94-9f7d-81f9c236d440
- Meet Grok Bot (onboarding) — https://mobbin.com/screens/93b94f55-5fb2-4d2a-8a18-6264cb455548

## 1. What Grok Bot looks like on a phone (observed)

### Home = the list of bots (root screen, no tab bar, no drawer)
- Top row, floating on the page: left a round **account** chip with the user's
  initials; right a round **search** chip and a round **+** (add bot) chip. No
  title text. Chips are white circles with a soft shadow, 44 pt.
- Below: a plain list, one row per bot (no cards, no dividers):
  `[avatar 44pt + green presence dot] [name (bold) + optional grey chip] … [time]`
  and a second line with the last message, grey, one line, ellipsis. Row height
  about 66 pt. A running/online bot has the green dot; a tag chip carries the
  routine or task ("Meal prepping").
- Tap a row → push the chat. There is no hamburger drawer anywhere.
- The account chip opens a bottom sheet (name, e-mail, usage, sign out).

### Chat screen
- Chrome floats over the messages: left a round **back** chip, then a **bot
  pill** (avatar + presence dot + name; tap → bot profile), right a round
  **computer** chip (opens the bot's computer/browser). Everything sits on a
  frosted, translucent band; the messages scroll under it.
- Messages: centred grey timestamp ("Today 4:29 PM"); bot messages as
  left-aligned light-grey bubbles (radius ≈ 18, max ≈ 85 % width), user
  messages as right-aligned black bubbles with white text. The bot's small
  avatar mark appears once, under the last bubble of its turn.
- System lines centred, small, grey, with an icon: "New routine 'Weekly meal
  prep'", "Messaged 🔥 Chief of Staff".
- Rich blocks inside a bot bubble: file card (icon, name, size), option list
  with letter badges A/B/C (the picked one turns "This works ✓", the rest fade
  to "dismissed"), a connector card with a black **Authorize** button, images
  as their own bubble.
- A round **scroll-to-bottom** chip above the composer on the right.
- Composer: round **+** chip on the left (attachments), then one pill
  "Ask <bot>" with a mic inside on the right; with text the mic becomes a
  black round **↑** send button. While a run is in flight the pill shows a red
  dot with the elapsed time. Attachment previews sit above the pill. The whole
  composer rises with the keyboard; nothing else moves.
- Swipe from the left edge or tap back → home list.

### Bot profile (from the pill)
- Round back chip, round "…" chip; big avatar; name + optional title fields;
  Character: colour row + shape row; Instructions row; Routines list with
  "Add routine"; Notifications toggle ("Get notified when this agent finishes
  or needs input").

### Onboarding
- "Meet Grok Bot" with the mascot and a composer "Give any task to your team of
  agents"; "Meet Your New Bot" sheet with avatar, name, one-line role, black
  **Start Chat** button, "Create My Own" link.

## 2. Mapping to CoWork

| Grok Bot | CoWork today | CoWork mobile (this work) |
|---|---|---|
| Home list of bots | `AgentRosterView` (sidebar buckets working/scheduled/waiting) inside an `IndexedStack` on narrow windows, under a Material `AppBar` | `MobileAgentList`: messenger rows (avatar + presence dot, name, role chip, time, last thread) with the floating home bar (account, search, add). Same `AgentRosterSource`, same `onSelect`. |
| Chat chrome (back, bot pill, computer chip) | `AppBar` with title + 6 icon actions | `MobileChatChrome` floating over the chat; actions folded into the trailing chips: computer (agent's browser), "…" sheet (controls, rooms, copy full chat, settings, sign out) |
| Messages + composer | `ChukChatUIMobile` (chuk_chat verbatim) | unchanged — it already does keyboard-safe composer, safe areas, scroll-to-bottom, attachments, mic. The chrome hands it `topInset` so the first row scrolls under the bar. |
| Computer chip | `browser_view_page.dart` (cowork-13) | the chip calls the shell's existing `_openBrowserView` |
| Bot profile | `AgentControlPanel` (end drawer) | opened from the bot pill as a full-height bottom sheet on phones |
| Approve / Authorize card | `AskUserCard`, approval bar in the thread view | unchanged (already inline) |

Bubbles: chuk_chat renders the assistant full-width (no bubble) and the user in
a bubble. Grok Bot bubbles both. The chat renderer is verbatim chuk_chat and
must not be hand-edited (re-sync overwrites it), and the directive "CoWork is
chuk_chat master" outranks the look of one bubble. So the messenger feel comes
from navigation, chrome, list, touch targets and keyboard behaviour — not from
restyling the bubbles. Noted as a possible upstream change in chuk_chat.

## 3. Rules the mobile layer follows

- **Touch targets ≥ 48 dp** for every chip/row (Grok Bot uses 44 pt; Material
  minimum is 48 dp — the larger wins).
- **Safe areas**: the chrome pads `MediaQuery.padding.top`; the composer keeps
  chuk's own bottom `SafeArea`. Nothing draws behind the notch or gesture bar.
- **Keyboard**: the hosting `Scaffold` resizes; chuk's mobile screen uses
  `resizeToAvoidBottomInset: false` on its inner scaffold and measures the
  composer itself. The chrome must never depend on `viewInsets` (it would
  rebuild every keyboard frame) — it reads `paddingOf`/`sizeOf` only.
- **Back**: Android back / predictive back and an edge swipe pop the chat to
  the home list. `PopScope` handles it in the chat screen so the shell only
  flips its flag.
- **No drawer** on phones: Grok Bot's navigation is list → chat → back. The
  agent controls open as a sheet from the bot pill.
- **Breakpoint**: phone layout below 600 dp width on any platform (so a
  narrow Linux window shows it), and always on Android/iOS phones.
- **The thread view stays in the tree — always.** `CoworkThreadView` owns
  the relay controller: it reconnects from the stored pairing at bootstrap,
  reports `onPaired` (which puts the host agent into the roster) and adopts a
  run that is already in flight. If the inbox screen mounted only the list,
  a phone would get its socket only when a chat is opened — no reconnect, no
  run adoption, a roster without the host. So the inbox branch is a `Stack`:
  `Positioned.fill(Offstage(child: thread))` under
  `Positioned.fill(MobileAgentList(...))` — chuk's own pattern. Found by
  cowork-5c while applying the shell diff (a red test caught it).

## 4. Files

Owned by this session (new):
- `app/lib/platform_specific/mobile/mobile_layout.dart` — breakpoint, chrome
  height, touch-target constants, `MobileLayout.isPhone(context)`.
- `app/lib/platform_specific/mobile/mobile_chips.dart` — the round frosted
  chip and the accent (black) chip, ported from chuk's `root_wrapper_mobile`
  `_floatIconChip` so the two apps read the same.
- `app/lib/platform_specific/mobile/mobile_presence_avatar.dart` — `AgentAvatar`
  plus the presence dot (green = working, amber = scheduled, none = waiting).
- `app/lib/platform_specific/mobile/mobile_chat_chrome.dart` — the floating
  top bar of a chat: back chip, bot pill, trailing chips.
- `app/lib/platform_specific/mobile/mobile_chat_screen.dart` — the chat page:
  chrome over the body, `topInset` handed to the body builder, `PopScope`,
  edge-swipe back, tap-to-unfocus.
- `app/lib/platform_specific/mobile/mobile_agent_list.dart` — the home list
  with its floating home bar.
- `app/lib/platform_specific/mobile/mobile_agent_sheet.dart` — the "…" actions
  sheet (controls, rooms, copy full chat, settings, sign out).
- Tests under `app/test/platform_specific/mobile/`.

Not mine — diff proposals go to the coordinator (cowork-b7):
- `lib/pages/messenger_shell.dart` (cowork-5c): narrow branch mounts
  `MobileAgentList` / `MobileChatScreen`, no `AppBar` on phones.
- `lib/widgets/cowork_thread_view.dart`: accept `topInset` and a
  `forcePhoneLayout` so a narrow Linux window renders `ChukChatUIMobile`.
- `lib/platform_specific/chat/chat_ui_mobile.dart` (verbatim): no edit needed.

## 5. Diff proposals (exact)

Status 2026-09-05: the `cowork_thread_view.dart` hunks below are APPLIED (by
c6, announced to 47/84/b5). The shell diff (`docs/diffs_c6_messenger_shell.md`)
is APPLIED by cowork-5c with one correction: the inbox branch keeps the thread
view mounted off-stage (see the rule in section 3). 5c's tests: "a phone window
shows the inbox, then the chat, and back again" (420 px) and a tablet test
(660 px), both green.

### cowork_thread_view.dart
```dart
// constructor
this.topInset = 0,
this.phoneLayout = false,
...
/// Extra top padding for the chat list, so the first row scrolls under a
/// floating top bar (mobile chrome) instead of starting behind it.
final double topInset;
/// Force chuk's phone screen. The mobile shell sets it below the phone
/// breakpoint on every platform, so a narrow desktop window shows the phone
/// layout too.
final bool phoneLayout;

// _useDesktopChat
bool _useDesktopChat(BuildContext context) {
  if (widget.phoneLayout) return false;
  ...unchanged
}

// _buildChat, mobile branch
return ChukChatUIMobile(
  key: key,
  topInset: widget.topInset,
  ...unchanged
```

### messenger_shell.dart (narrow branch)
```dart
final phone = !wide && MobileLayout.isPhone(context);
...
return Scaffold(
  key: _scaffoldKey,
  appBar: phone ? null : _buildAppBar(context, wide),
  endDrawer: _buildControlDrawer(context),
  body: wide
      ? Row(...)                                 // unchanged
      : phone
          ? (_showThreadOnNarrow && agent != null
              ? MobileChatScreen(
                  agent: agent,
                  onBack: () => setState(() => _showThreadOnNarrow = false),
                  onOpenBrowser: _openBrowserView,
                  onOpenProfile: () => _scaffoldKey.currentState?.openEndDrawer(),
                  onMore: () => showMobileAgentSheet(context, ...),
                  bodyBuilder: (context, topInset) => thread(topInset),
                )
              : MobileAgentList(
                  source: _roster,
                  selectedAgentId: _selectedAgentId,
                  onSelect: _select,
                  onAddAgent: _openOnboarding,
                  onOpenAccount: _openSettings,
                ))
          : IndexedStack(...)                     // unchanged tablet path
```
where `thread(topInset)` builds the existing `CoworkThreadView` with
`topInset: topInset, phoneLayout: true` — the `GlobalKey` keeps the socket
alive across the flip exactly as today.

## 6. Verification plan

- `flutter analyze` on the new files, then one full analyze at the gate.
- Widget tests, one file at a time (RAM rule): chrome touch targets ≥ 48,
  back pops via `PopScope`, `topInset` reaches the body builder, list rows
  render presence and select the first thread, sheet actions call back.
- Rendered previews at 390×844 from the widget tests (golden PNGs with the
  real Roboto + Material Icons fonts loaded) into `docs/screenshots/c6/` —
  these show the layout without touching the running app.
- After the shell diff is applied by cowork-5c: the Linux app at a narrow
  window shows list → chat → back; `flutter-hot shot docs/screenshots/c6/…`.
