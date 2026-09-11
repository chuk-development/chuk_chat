# The design of this app

One language, everywhere. The app is Material 3 Expressive with its own icon set
and its own screen frame. Every screen that breaks a rule below is a bug, and
that includes screens that shipped before this file existed.

This is a working rulebook, not a mood board. Read it before adding UI, and run
the checklist at the end before calling a screen done.

## 1. Why this exists

Screens were built one at a time, each in its own idiom: round buttons here,
stadium buttons there, a glow on the send button, a blur across the top of the
chat, a Save action that was a green text link in the middle of a document, four
different back arrows. Each was defensible alone. Together they read as an app
assembled from parts of other apps.

## 2. The frame: `ExpressiveScreen`

Every full-screen page uses `lib/ui/expressive/expressive_screen.dart`. Never a
bare `Scaffold` with a Material `AppBar`.

```dart
ExpressiveScreen(
  title: 'Connectors',
  actions: <Widget>[ExpressiveIconButton(hugeIcon: HugeIcons.plusSign, onTap: …)],
  builder: (BuildContext context) => ListView(
    padding: EdgeInsets.fromLTRB(
      16,
      MediaQuery.paddingOf(context).top + 8,   // already includes the bar
      16,
      MediaQuery.paddingOf(context).bottom + 24,
    ),
    children: …,
  ),
)
```

- **`builder`, not `child`.** The frame grows the media query by the height of
  its bars; a page built outside that builder would read the window's inset and
  its first row would sit under the title.
- **Back**: left, always the same square `ExpressiveIconButton` with
  `HugeIcons.arrowLeft02`. There is no second back button in a body, and no page
  draws its own arrow. `showBack: false` only where there is nowhere to go back
  to (a tab inside the home).
- **Title**: left aligned, `headlineSmall`, weight 800, letter spacing −0.5. One
  line, ellipsised in the MIDDLE when it is a file name, so the extension
  survives (`_MiddleEllipsis` in `chat_document_view.dart`).
- **Actions**: right, `ExpressiveIconButton`s, 8 px apart, same size as back.
- Content scrolls UP BEHIND the bar. That is the whole point of the veil.

## 3. The veil, top and bottom

`lib/ui/expressive/top_veil.dart`. Never a solid band: a band has an edge and the
edge draws a line across the content.

- Top: `surface` at alpha 0.78 → 0.58 → 0.26 → 0, stops 0 / 0.36 / 0.74 / 1.
  Heaviest behind the status bar, gone below the row.
- Bottom (`BottomVeil`): the mirror, for the floating navigation.
- Use `topVeilDecoration(scheme)` directly when a surface places its own bar (a
  pinned `SliverAppBar`, for example).
- The only other translucency in the chrome is the coworker pill in the chat
  header: `surface` at 0.72 with an `outlineVariant` border.

## 4. Navigation

`lib/platform_specific/mobile/mobile_nav_bar.dart`: one pill, centred, only as
wide as its targets, floating on the bottom veil. Four destinations — Chats,
Media, Files, Settings. The selected one is a filled capsule in `primary` with
`onPrimary`; the rest are bare icons in `onSurfaceVariant`. The unread count
rides on the Chats icon.

The same shape is the filter control above the roster (`ConnectedGroup`): one
pill, the selected segment a filled capsule. A control that offers a choice
looks like the navigation, because it is the same idea.

## 5. Icons

**One set: HugeIcons (free, MIT).** The SVGs live in
`app/assets/icons/hugeicons/`, are registered in `pubspec.yaml` and ship inside
the build. Nothing is fetched at run time and no icon package is a dependency.
The licence sits next to the assets.

Adding an icon:

1. Put its name in `WANTED` in `app/tool/generate_hugeicons.py`.
2. Run `python3 tool/generate_hugeicons.py <unpacked @hugeicons/core-free-icons>`.
3. The name list in `lib/ui/expressive/huge_icon.dart` follows the file stems.

Using one:

- `HugeIcon(HugeIcons.sheet, size: 20, color: …)` — behaves like `Icon`.
- `ExpressiveIconButton(hugeIcon: HugeIcons.share01, …)` for a target.
- `AppIcon(Icons.download)` where a call site already holds an `IconData`: it
  looks the glyph up in `lib/ui/expressive/icon_map.dart` and draws the app icon,
  falling back to Material when the table has no entry. **New code should not add
  Material glyphs** — extend the table or name the HugeIcon directly.

The table deliberately collapses synonyms: every "close" is one icon, every
"edit" is one icon, `chevron_right` and `arrow_forward` are the same arrow. Two
screens must not pick different glyphs for the same idea.

File kinds get their own glyph, read from the extension first and the mime type
second (`sandbox_artifact_block.dart`): sheet for tables, text for markdown,
braces for JSON, source-code for markup and code, terminal for shell, pdf,
presentation, zip, database, image, video, book.

## 6. Shape and radius

| Element | Shape |
|---|---|
| Icon action (back, close, share, save, screen, files) | `ExpressiveIconButton`, 48 px, corner ≈ size × 0.34 |
| Labelled action | `ExpressiveButton`, same corner family |
| Navigation pill / filter pill | `PillGeometry` — outer 30, segment capsule 22, inset 8, segment height 44, whole pill 60. Both controls read those numbers from `lib/ui/expressive/pill_geometry.dart`; the outer radius is half the outer height, so the curves are concentric and the end segments follow the shell. A segment takes 4 of the ring above and below as tap slop, so what a finger hits is 52 even though the capsule paints 44. A pill segment SELECTS ON POINTER DOWN (`MorphTap(instant: true)`) — a recognised tap is lost to the list the pill sits over — so a press springs and fills at once and never draws an outline for a selection that has not happened. |
| Card, sheet, attachment row, panel | 14–18 |
| File message row | 18, full lane width |
| Dialog | `kRadiusDialog` |
| Chat bubble | the bubble radius helper, never a hand-rolled radius |
| Coworker face | the expressive silhouette family (`ui/expressive/shapes.dart`) |

Never a bare `IconButton`, `IconButton.filledTonal` or `CircleAvatar` in a new
surface: they are the old idiom and they do not match what sits next to them.

## 7. Colour

- The app theme owns surfaces and text. A screen never tints a surface.
- The accent is what changes: inside an open thread, the accent roles are
  re-seeded from the coworker's colour (`AgentTheme`), so bubbles, the send
  button and the header pill carry that coworker's identity.
- A coworker's colour comes from `agentAccent`: the one the user picked, else a
  hue from `kAgentAccents`. Never a raw hash-to-hue — that put two coworkers in
  the same teal.
- Fixed saturation and lightness, so a white monogram always has contrast.

## 8. Effects

- **No glow.** No coloured `BoxShadow`, ever — not under the send button, not
  under a presence dot, not under a chip. A shadow is neutral and small, or it is
  not there.
- **No gradient on a control.** Buttons are flat fills.
- Translucency only where content has to stay readable underneath: the veils and
  the coworker pill. Nothing decorative.
- Motion is the expressive spring the app ships (`ui/expressive/motion.dart`),
  200–350 ms. Nothing pulses forever: an animation says something is happening
  and then stops.

## 9. Messages and files

- A file the coworker produced is **its own message**, hung under the text
  bubble — not a block inside it. A coworker may send several messages in a turn.
- A file message spans the bubble lane and carries the bubble's fill: a typed
  badge, the name with its extension in the quieter colour, the size, a small
  download target. The row itself opens the file.
- Content is never dumped into a bubble. A 20 KB markdown document is opened, not
  pasted.
- A document opens **full screen on a phone** (`ChatDocumentView`): the shared
  bar with close, share and save, the document scrolling under it. A wide window
  keeps the dialog.
- Files are real files: the coworker writes one in its sandbox and sends it
  (`send_file_to_user`). There is no "artifact" tier with nothing behind it.

## 10. Lists

- A roster row is 64 px: face 48, name, the last line that was actually said,
  time, and a count badge when something is unread. Never a placeholder line like
  "No activity yet" — an empty line says it better.
- The preview text is plain: markdown markers are stripped
  (`ThreadPreviewStore`), and the user's own line is prefixed "You: ".
- Media is a grid for pictures and the chat's own file row for files.

## 11. Layout

- Reading measure for prose: 720 px. A wide window keeps a column.
- A table that cannot fit stacks into one card per row (`ChukTable`); it never
  scrolls off the right edge unannounced.
- Every screen works at 360 px width and 1.3 text scale — the layout suite checks
  it, and it is not optional.

## 12. Tests

- Find an icon with `findIcon(...)` from `test/support/icon_finder.dart`, never
  `find.byIcon`: the app draws through `AppIcon`, and `byIcon` only knows
  Material. `iconColor(...)` and `findWidgetWithIcon<T>(...)` are there too.
- A layout test that measures overflow must skip `FittedBox` subtrees: what is
  inside one is scaled, so its box says nothing about what is painted.

## 13. Before you call a screen done

1. Does the page use `ExpressiveScreen` with its `builder`?
2. Is every icon action an `ExpressiveIconButton`, and every icon from the app's
   set (or in the map)?
3. Any coloured shadow, glow or gradient on a control? Remove it.
4. Do the corners match the table in §6?
5. At 360 px and 1.3 text scale: does anything overflow, or ellipsise something
   that identifies content (a file name, a coworker name)?
6. Does content scroll behind the bars, or stop under them?
7. Does an open thread still show the coworker's accent?
8. Tests for the layout, not only for the logic?
