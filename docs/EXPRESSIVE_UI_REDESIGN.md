# The expressive UI redesign (2026-09-09)

The app's UI was rebuilt in the Material 3 Expressive language of the reference
messenger in `~/git/messenager`. This note says what was taken over, what was
deliberately dropped, and where each piece lives, so the next session does not
have to re-derive it from the diff.

## The layer

`app/lib/ui/expressive/` is the design system. Nothing in it knows about the
relay, the roster or a chat; every screen builds on it.

| File | What it is |
| --- | --- |
| `shapes.dart` | `CookieShape` + `expressiveShapeFor(key)` — the scalloped blob silhouettes, picked from an identity key (the agent id), so a coworker keeps one shape on every screen. |
| `motion.dart` | `MorphTap` (spring + shape morph on press), `ExpressiveButton`, `ExpressiveIconButton` (with `parked` for a feature that does not exist yet), `ExpressiveLoader`. |
| `staggered.dart` | `StaggeredItem` — the cascading list entrance. One controller with an `Interval`, never a `Future.delayed` (a pending timer fails a widget test). |
| `connected_group.dart` | The connected filter group (All / Unread) with the pill/square morph. |
| `feedback.dart` | `pillToast`, `expressiveSheet`, `SheetAction`. |
| `bubble_shape.dart` | `BubblePosition`, `bubbleRadius` — one connected group per run of same-sender messages. |
| `receipt.dart` | `ReceiptState`, `receiptStateFor`, `MessageReceipt`, the tick styles. |
| `bubble_kind.dart` | The coworker bubble's colour by what the turn IS: answer / work / delivery / problem. |
| `agent_face.dart` | `AgentFace` — the blob face with the picture, the accent and the presence dot; `agentAccent`, `kAgentAccents`. |
| `working_dots.dart` | The "working ●●●" indicator (the messenger's typing indicator, said honestly). |
| `waveform.dart` | `WaveformPainter` + `LiveWaveform` — rounded voice bars, used for the live microphone level. |

Two stores carry the facts the redesign needed:

* `services/cowork/agent_profile_store.dart` — a coworker's picture, colour,
  role and brief. The wire carries ids and NAMES only (`agent_create`,
  `agent_rename`, `agent_list`), so these live in `SharedPreferences` on this
  device, and the profile editor says so.
* `services/cowork/agent_read_marks.dart` — the last time the reader had a
  thread on screen. `unread == lastActivity > lastRead`. A dot, never a count:
  the app cannot know how many messages arrived while the reader was away.

## The screens

* **Phone inbox** (`platform_specific/mobile/mobile_agent_list.dart`): title
  bar with the account face and an inline search, the All / Unread group with
  the real unread count, expressive rows (face, name, role tag, time, preview,
  unread dot), staggered entrance, long-press row menu.
* **Phone chat chrome** (`.../mobile_chat_chrome.dart`): back target, coworker
  pill with the live state, PARKED voice call, browser target (only while a
  browser is really open), more.
* **Coworker profile** (`pages/agent_profile_page.dart` + `_edit_page.dart`):
  face, state, brief, schedule, session, manage block; the editor sets picture,
  colour, name (→ host), role and brief.
* **Bubbles** (`widgets/message_bubble/layout.dart`): connected corner
  geometry, the user's receipt inside the bubble corner, a coworker bubble with
  a colour per kind and the time but no ticks.
* **Desktop** (`widgets/agent_roster_view.dart`, `widgets/cowork_thread_header.dart`):
  the same faces and unread dots in the rail, and the same contact header —
  face, name, live state, parked call — above the thread.
* **Theme** (`constants.dart`): the expressive emphasis (heavier display /
  headline / title / label weights) and the expressive FAB corner, layered on
  top of the existing colour and component themes.

## What was deliberately NOT taken over

The reference is a messenger between people. These have no meaning here and
were left out rather than faked: calls and the whole call UI (only the parked
button remains, and it says why), contacts and groups, saved messages, starred
and archived buckets, polls, wallpapers, message-body search across chats, and
"typing" (a coworker "works", which the app can observe).

## Rules that fell out of it

* A tick is only shown where the app knows the answer: the user's own messages.
  A coworker's bubble carries the time and nothing else.
* A parked feature keeps its place, looks disabled, and explains itself on tap.
  It is never wired to something fake.
* Profile fields that cannot reach the host are stored locally and labelled as
  such in the editor.
* No repeating animation may be inside a `pumpAndSettle` in a test — the
  preview goldens pump a fixed duration (see
  `test/platform_specific/mobile/mobile_preview_test.dart`).
