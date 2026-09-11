# The design of this app

One language, everywhere. The app is Material 3 Expressive — not "mostly", not
"where it was convenient". Every screen that breaks a rule below is a bug, and
that includes screens that shipped before this file existed.

This is a working rulebook, not a mood board. Read it before adding UI, and
check the list at the end before you call a screen done.

## 1. Why this exists

Screens were built one at a time, each in its own idiom: round buttons here,
stadium buttons there, one glow on the send button, a blur across the top of the
chat, a Save action that was a green text link in the middle of a document. Each
of those was defensible alone. Together they read as an app assembled from parts
of other apps.

## 2. Shape

The shape scale, in the order a reader meets it:

| Element | Shape |
|---|---|
| Icon action (back, files, screen, close, share, save) | `ExpressiveIconButton`, 48 px, squircle |
| Labelled action | `ExpressiveButton` (tonal or filled), same corner family |
| Card, sheet, attachment row, panel | 14–18 px corner radius |
| Dialog | `kRadiusDialog` |
| Chat bubble | the bubble radius helper; never a hand-rolled radius |
| Coworker face | the expressive silhouette family (`lib/ui/expressive/shapes.dart`) |

Rules:

- **Never** place a bare `IconButton`, `IconButton.filledTonal` or a
  `CircleAvatar` in a new surface. They are the old idiom and they do not match
  the buttons next to them. Use `ExpressiveIconButton` / `AgentFace`.
- A row of actions uses one button type, one size, one spacing (8–10 px).
- A pill (`StadiumBorder`) is for status, not for actions.

## 3. Colour

- The app theme owns surfaces and text. A screen never tints a surface.
- The accent is what changes: inside an open thread the accent roles are
  re-seeded from the coworker's colour (`AgentTheme`), so bubbles, the send
  button and the header pill carry that coworker's identity.
- A coworker's colour comes from `agentAccent`: the colour the user picked, else
  a hue from the shared palette (`kAgentAccents`). Never a raw hash-to-hue: it
  puts two coworkers in the same teal.
- Contrast is not negotiable. White monogram on an accent means the accent keeps
  its fixed saturation and lightness.

## 4. Effects

- **No glow.** No coloured `BoxShadow`, ever — not under the send button, not
  under a presence dot, not under a chip. A shadow is neutral and small, or it
  is not there.
- **No gradient on a control.** Buttons are flat fills.
- **Blur only where the content has to survive underneath**: behind the floating
  chat pill and the strip directly under it. Never across the status bar area,
  never as a decorative wash.
- Motion is the expressive spring the app already ships (`ui/expressive/
  motion.dart`). Nothing pulses forever; an animation says something is
  happening and then stops.

## 5. Messages and files

- A file the coworker produced is **its own message**, hung under the text
  bubble — not a block inside it. The coworker may send several messages in a
  turn; the transcript shows them as such.
- A file message is one row: a typed badge, the file name with its extension in
  the quieter colour, the size. The row opens the file. A small download button
  sits at its right. No two large buttons in a bubble.
- Content is never dumped into the bubble. A 20 KB markdown document is opened,
  not pasted.
- A document opens **full screen on a phone** (`ChatDocumentView`), with one
  thin bar: close on the left, share and save on the right, all three the same
  icon button. On a wide window it stays a dialog.
- Files are real files: the coworker writes them in its sandbox and sends them
  (`send_file_to_user`), and the app downloads the bytes. Nothing is faked into
  an "artifact" that has no file behind it.

## 6. Layout

- The reading measure for prose is 720 px; a wide window keeps a column instead
  of running the full width.
- A table that cannot fit stacks into one card per row (`ChukTable`). It never
  scrolls off the right edge unannounced.
- Every screen works at 360 px width and at a 1.3 text scale. The layout test
  suite checks this; it is not optional.

## 7. Before you call a screen done

1. Does every icon action use `ExpressiveIconButton`?
2. Is there any coloured shadow, glow or gradient on a control? Remove it.
3. Does the screen tint a surface that is not its own accent? Remove it.
4. Do the corners match the table in §2?
5. At 360 px and 1.3 text scale: does anything overflow or ellipsise something
   that identifies content (a file name, a coworker name)?
6. Does an open thread still show the coworker's accent?
7. Did you add a test for the layout, not only for the logic?
