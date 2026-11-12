# Grok Bot desktop app, looked at live (2026-11-12, CHAT-55)

The owner had Grok Bot 1.0.1 (Electron 43, `/opt/Grok Bot/grok-bot`) open
and allowed one short look at that window only. Plus two screenshots he
sent of a thread. We take ideas, never their look (`docs/DESIGN.md`).

## How the look was taken (and the trap)

- Grok Bot runs as a native Wayland client (`--ozone-platform=wayland`).
  `xdotool` does not see it, so there is no xdotool navigation.
- The compositor is niri. `niri msg windows` lists the window with its PID;
  check the PID against `pgrep -f "/opt/Grok Bot/grok-bot --$"` first.
- `niri msg action screenshot-window --id <id>` captures that window only.
  It has no output path: it writes to `~/Pictures/Screenshots/` AND
  replaces the clipboard. Save the clipboard first
  (`wl-paste --type text/plain > f`) and put it back after (`wl-copy < f`),
  then move the file to `_scratch/grokbot_live/`.
- Do not send input to the window: on Wayland that means focusing it,
  which takes the focus away from the owner.

## What the window shows

- **Left pane.** Search and "+" chips on top. A row of big bot faces with
  the name under each (pinned bots). Under it the thread list: one row per
  bot, its face, the bot name on top, the last message under it, cut with
  an ellipsis. "Hidden Bots" as a quiet group header. Account initials and a
  "Connect apps" pill at the bottom.
- **Thread header.** A centred pill with the bot face and the thread title,
  "Share" on the right. No model picker anywhere in the thread.
- **Messages** (owner screenshots). Every message is its own bubble. The
  user bubble is right, in the bot's colour (blue for one bot, orange for
  another). Bot bubbles are left, a neutral dark grey with a large radius.
  Two bot replies in a row are two bubbles. Images are their own tiles
  under the bubbles, side by side.
- **Time.** A centred quiet line ("Wed, Nov 4 8:39 PM", "Thu, Nov 5
  9:03 AM") when a new day starts or after a long pause. No stamp on every
  bubble.
- **Composer.** One pill: "+" left, "Message <bot>" hint, mic, and a round
  voice button in the bot's colour on the right.
- **Hover on a bubble** (desktop). Three small glyphs beside the bubble,
  centred on it: react, reply, more. No resend, no copy pill.
- **Right panel.** The bot's face large, its name, then two tabs
  "Activity | Library". Library lists the bot's files ("Older": a sheet, a
  PDF) as quiet rows in one card. A round close chip on top.
- **Links** in an answer carry the site's favicon in front and show a hover
  card (image, title, text, URL). The link preview work owns this.
- **Hidden Bots** is a group header with a count at the right.
- **Dialogs.** "Connect Apps" is a centred modal over a dimmed window:
  title, a "7 connected" stack of logos, a search field, filter chips,
  two-column rows of app logo, name and a tonal "Connect" button.

## Mapped to Agents

| Grok Bot | Agents | Item |
|---|---|---|
| Bubble per message, user bubble in the bot colour, hover actions | Messenger bubbles | CHAT-52 |
| Centred day and time line | Time divider | CHAT-53 |
| No model picker, settings on the right | Model in agent settings, right pane | CHAT-54 |
| Activity / Library tabs in the right panel | Open: not built yet | — |
| Name + last message rows | Roster row | CHAT-35 |
| Bot faces | Own avatar concept (not their blobs with eye slits) | CHAT-34 |
