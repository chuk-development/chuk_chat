---
format: 1920x1080
duration: 61s
message: "One chat that does it all, privately."
arc: Hook (prompt) → Working → The reply builds the trailer (6 cards) → Recap on riser 2 → Slogan on the drop → Pull-out → End card
audience: people who use AI chat every day and care where their chats go
mode: autonomous
music: supplied
captions: skipped (no narration)
---

# Chuk, announce yourself — storyboard

The whole film is one Chuk Chat conversation in one desktop window. One
camera (`#cw-cam`) moves over one window. Frames 01-14 are time ranges of the
reusable window sub-composition `compositions/chuk-window.html`; frame 15 is
`compositions/end-card.html`. Times are video seconds on the 120 BPM grid of
`assets/bgm/track_edit.wav` (beats every 0.5 s, downbeats at odd seconds).

## Video direction

- **Palette** — paper `cream #FDFBF7` only behind the end card and in the
  "paper" sky; the window is `navy #262624` with `app-fg #E8E4D8` text;
  `coral #D97757` only for the send button, the user bubble and the "+50"
  chip; ticks in the app's green `#86C795`. Skies are the website's worlds
  (dawn, network, day, night, prism, street), copied from `usecases.css`.
- **Type** — chat text and reply headings in Chuk Chat Mono (the app's chat
  font); app chrome in Ubuntu (the website's `--ui-font`); end-card slogan
  in Inter 300 (the site's light sans headline voice).
- **Lift-out (round 2)** — each card leaves the window, lands big on one of
  the website's worlds (prism, network, dawn, day, night, paper, library),
  holds on the beat and drops back into the reply. The window is the frame
  between lifts. Riser 2 is a montage of the lifted cards.
- **Camera lives close** (coordinator rule after the 02/04 reviews): the
  full window small on its sky only in the first second and in the pull-out.
  Every other shot is a punch-in: UI text >= 28 px on screen, reply headings
  >= 64 px, logos >= 72 px, the slogan >= 110 px. Shots are measured from the
  real layout at init (`script.json` → `shots`), so they stay on target when
  copy changes.
- **Motion grammar** — camera cuts land on beats (hard `set`), then a slow
  push (drift x1.02-1.10) holds the read; moves are `power3.inOut`, pans
  across chip rows are `sine.inOut`.
  Reveals stream like the app streams tokens (word or char opacity),
  cards slide up 12 px and fade in (`power3.out`), the side panel opens with
  its real flex-basis motion. A macOS pointer clicks send and the model
  pill. No bounce, no glow, no coloured shadow.
- **Reveal model** — nothing is on screen before its beat. Each reply block
  (heading + card) is laid out at its downbeat, its parts reveal on the
  following beats.
- **Rhythm / holds** — held breaths: 04 (the heading types in the break before drop 1),
  12 (the hush before drop 2, only a blinking caret), 15 (end card hold).
  Fast cuts on the beat: 05-10. The riser 2 recap (11) is one continuous push.
- **Negative list** — no competitor names or logos, no OpenAI logo, no neon,
  no glow, no space backgrounds, no invented numbers; no slideshow
  (front-load then freeze) and no screensaver (things floating for no
  reason).

## Frame 1 — Hook: the prompt types

- scene: close on the dark composer, "Announce yourself on YouTube. Keep it short." types, the pointer clicks send on the downbeat
- duration: 4s
- src: compositions/chuk-window.html
- poster: 1.6
- transition_in: cut
- status: animated
- asset_candidates: compositions/chuk-window.html (composer), assets/sfx/typing.mp3, assets/sfx/click-soft.mp3, assets/sfx/pop.mp3
- blueprint: compose
- focal: composer field text
- roles: composer = focal · window + dawn sky = background (revealed on send)
- sfx: typing, click-soft (send), pop (bubble)

Scene 1 (0.0-1.0s): establishing shot, the whole window on the dawn sky, the prompt already typing (the only wide shot before the pull-out).
Scene 2 (1.0-2.3s): the kick enters: hard cut tight on the composer (3x), the prompt types at ~48 px.
Scene 3 (2.3-3.0s): pointer glides to the coral send button; camera widens to include it (2.4x).
Scene 4 (3.0-4.0s): click on the downbeat, the field clears, the camera follows the user bubble up into the thread (2.8x).

## Frame 2 — Working

- scene: agent timeline "Running list models / connectors / create artifact", rows tick in on beats, folds to "Worked for 3s"; the reply starts "Hi, I'm Chuk Chat."
- duration: 5s
- src: compositions/chuk-window.html
- poster: 6.0
- transition_in: cut
- status: animated
- asset_candidates: compositions/chuk-window.html (a-tl timeline, stream text)
- blueprint: compose
- focal: tool rows
- roles: timeline = focal · thread = supporting

Scene 1 (4.0-7.0s): cut close on the timeline; header "Running …" swaps as each "Ran …" row fades in on 4.5 / 5.0 / 5.5; slow push.
Scene 2 (7.0-9.0s): downbeat: header folds to "Worked for 3s", camera eases to the reply, "Hi, I'm Chuk Chat. Here's the short version." streams.

## Frame 3 — Models

- scene: heading "Pick a model for each message."; the pointer opens the model menu and clicks through the open-weight models on each beat
- duration: 6s
- src: compositions/chuk-window.html
- poster: 11.8
- transition_in: cut
- status: animated
- asset_candidates: assets/logos/models/{deepseek,moonshot,zai,qwen,minimax,mistral}.svg, composer model menu (uc-menu.css)
- blueprint: compose
- focal: model menu
- roles: menu = focal · heading = headline · pill = supporting
- sfx: click-soft on each click

Scene 1 (9.0-10.5s): groove starts: heading streams in at 2.9x (70 px); the pointer clicks the pill on 10.0 and the menu opens.
Scene 2 (10.5-13.5s): cut to the whole menu at 3.95x (logos 75 px); each beat a new model gets the tick and the pill label changes (DeepSeek → GLM → Qwen → MiniMax → Mistral → Kimi).
Scene 3 (13.5-15.0s): heading + pill "Kimi K3" at 2.7x; the menu closes on 14.0; riser 1 builds.

## Frame 4 — Breath before drop 1

- scene: close on the empty line, the next heading types letter by letter during the break
- duration: 2s
- src: compositions/chuk-window.html
- poster: 16.4
- transition_in: cut
- status: animated
- asset_candidates: assets/logos/connectors/*.png (sky nodes)
- blueprint: compose
- focal: whole window
- roles: window = focal · network sky = background

Scene 1 (15.0-17.0s): held at 2.7x; heading "Drives Notion, Linear, GitHub and 50+ more." streams letter by letter (65 px); the space for the chips waits below.

## Frame 5 — Connectors (drop 1)

- scene: on the drop, cut close: connector chips (Notion, Linear, GitHub, Todoist, Dropbox, Figma, Stripe, +50 more) slide in on 8th notes
- duration: 4s
- src: compositions/chuk-window.html
- poster: 18.6
- transition_in: cut
- status: animated
- asset_candidates: assets/logos/connectors/{notion,linear,github,todoist,dropbox,figma,stripe}.png
- blueprint: compose
- focal: chip row
- roles: heading = headline · chips = focal

Scene 1 (17.0-21.0s): on the drop, cut to the chip rows at 3.2x (logos 83 px); chips arrive one per 8th while the camera pans left to right across them.

## Frame 6 — Builds pages

- scene: heading "Builds pages, PDFs, code." + artifact card; the side panel opens and the Spoke landing page "Bike repair at your door." builds
- duration: 4s
- src: compositions/chuk-window.html
- poster: 23.6
- transition_in: cut
- status: animated
- asset_candidates: founders world markup (lp-*), a-art card, a-ph panel header
- blueprint: compose
- focal: landing page preview
- roles: heading = headline · artifact card = supporting · panel = focal

Scene 1 (21.0-22.0s): heading + "Spoke landing page · HTML · v1" card; the panel slides open.
Scene 2 (22.0-23.0s): cut close on the page: nav, "Bike repair at your door.", button reveal on beats.
Scene 3 (23.0-25.0s): ease down the page at 3.4x, the bike art and the feature tiles land.

## Frame 7 — Does the office work

- scene: heading "Does the office work." + invoice card; the panel shows the Typst PDF "Invoice No. 2026-031", rows and total €488.00 land
- duration: 4s
- src: compositions/chuk-window.html
- poster: 27.8
- transition_in: cut
- status: animated
- asset_candidates: business world markup (a-page, doc-*)
- blueprint: compose
- focal: PDF page
- roles: heading = headline · page = focal

Scene 1 (25.0-26.0s): heading + "Invoice Mrs Weber · Typst · PDF · v1".
Scene 2 (26.0-29.0s): cut to the page; lines land on beats; push toward the total.

## Frame 8 — Encrypted on your device

- scene: heading "Encrypted on your device."; on the break the whole chat turns to ciphertext under "What our server stores · AES-256-GCM · the key stays on your device", night sky
- duration: 4s
- src: compositions/chuk-window.html
- poster: 32.2
- transition_in: cut
- status: animated
- asset_candidates: private world markup (vault badge)
- blueprint: compose
- focal: ciphertext thread + vault badge
- roles: badge = focal · thread = focal

Scene 1 (29.0-31.0s): panel closes, heading streams.
Scene 2 (31.0-33.0s): break: cut close to the top of the window (3x); the text scrambles to ciphertext top to bottom, the badge and the AES-256-GCM note drop in; on 33.0 the text reads again.

## Frame 9 — Price

- scene: heading "€20 / month." + "€16 AI credits included. One budget, one invoice."
- duration: 4s
- src: compositions/chuk-window.html
- poster: 35.6
- transition_in: cut
- status: animated
- asset_candidates: stream text
- blueprint: compose
- focal: price heading
- roles: heading = focal · text = supporting

Scene 1 (33.0-35.0s): heading lands on the downbeat, text streams.
Scene 2 (35.0-37.0s): cut tighter on the credits line (3.5x), push.

## Frame 10 — Open source, everywhere

- scene: heading "100% open source." + chips Mac, Windows, Linux, Android, Web
- duration: 4s
- src: compositions/chuk-window.html
- poster: 39.4
- transition_in: cut
- status: animated
- asset_candidates: chips (a-src style)
- blueprint: compose
- focal: heading + chips
- roles: heading = headline · chips = focal

Scene 1 (37.0-39.0s): heading, chips on 8ths.
Scene 2 (39.0-41.0s): cut to the chips at 3.4x and pan across them.

## Frame 11 — Montage on riser 2

- scene: the lifted cards flash on their worlds, one per beat, then 8ths, then 16ths
- duration: 6s
- src: compositions/chuk-window.html
- poster: 46.4
- transition_in: cut
- status: animated
- asset_candidates: stream list, tick icon
- blueprint: compose
- focal: the list
- roles: list = focal

Scene 1 (41.0-47.0s): model menu, chips, Spoke page, invoice, ciphertext, €20, open source; quarter notes 41-44, 8ths 44.5-46, 16ths 46.125-46.875, each with a small scale punch.

## Frame 12 — Hush

- scene: a new empty line, only the caret blinks on the beat
- duration: 2s
- src: compositions/chuk-window.html
- poster: 48.0
- transition_in: cut
- status: animated
- asset_candidates: caret
- blueprint: compose
- focal: caret
- roles: caret = focal

Scene 1 (47.0-49.0s): close on the empty line, caret blinks 4 times.

## Frame 13 — Private and Secure. Always. (drop 2)

- scene: on the drop the whole slogan lands at once in big mono
- duration: 2s
- src: compositions/chuk-window.html
- poster: 50.0
- transition_in: cut
- status: animated
- asset_candidates: slogan text
- blueprint: compose
- focal: slogan
- roles: slogan = focal

Scene 1 (49.0-51.0s): slogan slams in (42 px x 2.65 = 111 px on screen), everything else in the window dims to 28 %, a small camera kick settles, hold.

## Frame 14 — Pull-out

- scene: the window scales down to a small card, the dawn sky fills the frame, the sun rises
- duration: 4s
- src: compositions/chuk-window.html
- poster: 53.0
- transition_in: cut
- status: animated
- asset_candidates: dawn sky
- blueprint: compose
- focal: window
- roles: window = focal · sky = background

Scene 1 (51.0-54.4s): power3.inOut pull-out; the sun rises behind.
Scene 2 (54.2-55.0s): the window fades away.

## Frame 15 — End card

- scene: logo, "Chuk Chat", "Private and Secure. Always.", "chuk.chat" on the dawn sky
- duration: 6s
- src: compositions/end-card.html
- poster: 58.0
- transition_in: crossfade
- status: animated
- asset_candidates: assets/logos/chuk-chat-logo.svg
- blueprint: compose
- focal: lockup
- roles: logo + wordmark = focal · slogan = headline · URL = supporting

Scene 1 (55.0-56.0s): logo and wordmark land on the downbeat, slogan on 55.5, URL on 56.0.
Scene 2 (56.0-61.0s): hold, music fades out.
