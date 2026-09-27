---
workflow: product-launch-video
flow: automation
storyboard: no
message: "One chat that does it all, privately."
destination: youtube
aspect: 1920x1080
language: en
audience: people who use AI chat every day and care where their chats go
length: 60s
angle: the whole trailer happens inside one Chuk Chat conversation
narration: no
music: supplied
---

## Intent

Launch video 05 of the Chuk Chat series, "Chuk, announce yourself". About
60 s, YouTube 16:9, no voice. The whole trailer happens inside one Chuk Chat
conversation. The user types "Announce yourself on YouTube. Keep it short."
and sends it on a beat. The agent works for a moment ("Worked for 3s", tool
rows such as "Ran create artifact"). Then the reply builds the trailer: each
part is a real app card, cut fast on the beat, and the camera punches in on
each one:

- Model picker cycles through the open-weight model logos: "Pick a model for
  each message."
- Connector row, logos slide in: "Drives Notion, Linear, GitHub and 50+ more."
- Artifact panel renders the "Spoke - Bike repair at your door" landing page
  from the founders world: "Builds pages, PDFs, code."
- Invoice PDF from the business world: "Does the office work."
- Encryption card, the chat turns to ciphertext: "Encrypted on your device."
- Price line: "€20 / month. €16 AI credits included."

On the drop the reply ends with one big line: "Private and Secure. Always."
Then the window scales down, the painted sky fills the frame, and the end
card holds. This is the series format: later videos are new prompts
("Chuk, compare yourself", "Chuk, show Agents") in the same frame.

Tone: calm, editorial, warm paper and painted skies like chuk.chat; crisp
rebuilt UI, a cursor that clicks, prompts that type, one short line per
beat, logo sting at the end (the Anthropic launch films are the reference).

## Assets

- assets/bgm/track.wav — the supplied track `marketing/_shared/music/05-announce-yourself.wav`, transcoded to PCM WAV (the source file is MP3 data with a .wav name).
- assets/bgm/track_edit.wav — the cut used in the video, made from track.wav only (see Notes, "Music edit").
- capture/ — copy of `marketing/_shared/capture/` (chuk.chat capture, no new crawl).
- assets/fonts/ChukChatMono-wght.woff2 — JetBrains Mono variable ("Chuk Chat Mono"), from chuk.chat/static/fonts. OFL.
- assets/fonts/Ubuntu-wdth-wght.ttf — Ubuntu variable, the app UI font of the website mocks (`--ui-font`). Ubuntu Font Licence.
- assets/fonts/InterVariable.ttf — Inter variable for light sans headlines on the paper end card (the site asks for -apple-system, which has no file). OFL.
- assets/logos/models/*.svg — model logos from chuk.chat/static/logos/models (DeepSeek, Moonshot/Kimi, Z.ai/GLM, Qwen, MiniMax, Mistral).
- assets/logos/connectors/*.png — connector logos from chuk.chat/static/logos/connectors.
- assets/logos/chuk-chat-logo.svg — `assets/logo.svg` of this repository.
- assets/sfx/*.mp3 — bundled media-use SFX library (key-press, click-soft, pop), local, no login.

## Customizations

- Reusable window: `compositions/chuk-window.html` is the Chuk Chat desktop
  window (markup and CSS copied from chuk.chat `layouts/partials/uc/*` and
  `assets/css/usecases.css`, `uc-menu.css`) as ONE sub-composition. The
  prompt, the chat title, the sky and the reply cards are composition
  variables. See Notes, "Reuse the window".
- Beat-cut: every card change, send, click and camera cut sits on the
  120 BPM grid of the edited track. "Private and Secure. Always." lands on
  the drop at 49.0 s.

## Notes

### Decisions (autonomous run, recorded)

- Style preset: `code-editorial` (warm paper, terracotta as scarce accent,
  hairlines, JetBrains Mono). Reason: closest to chuk.chat's calm editorial
  paper look. Brand tokens override it.
- Frame workers: not dispatched. The video is one continuous window with one
  camera, so frames are not independent. I built the reusable window
  sub-composition and the end card myself. `index.html` is hand-assembled
  (the sequential `assemble-index.mjs` model does not fit one continuous
  window), then checked with lint / check / snapshot.
- Captions: skipped (no narration).
- Model list: DeepSeek V4 Pro 0813, Kimi K3, GLM 5.3, Qwen3.8 27B,
  MiniMax M3, Mistral Small 4 (from the website `models.html`). gpt-oss-120b
  is left out on purpose so no OpenAI logo is on screen.
- Tool rows in the "working" step use the app's real row format ("Ran …").
  Names: "Ran list models", "Ran list connectors", "Ran create artifact".
- Headlines are the reply lines inside the window (markdown heading style in
  the chat), not overlays. Camera punch-ins keep them >= 64 px on screen.
- Phone readability (coordinator rule after the 02/04 reviews): the camera
  stays close. The whole window on its sky only 0-1 s and in the pull-out.
  UI text >= 28 px, reply headings >= 64 px, logos >= 72 px (chip logos 26 px
  x 3.2, model logos 19 px x 3.95), slogan 42 px x 2.65 = 111 px, end card
  logo + "Chuk Chat" 128 / 112 px, slogan 88 px, URL pill 40 px.
- User bubble: `#AD6048` with white text instead of the website's
  `#B6674D` / `#E8E4D8` (3.28:1), so the WCAG AA gate in `hyperframes check`
  passes (4.6:1). Still the same terracotta.
- Chips and model logos are drawn a little larger than on the website
  (chip 50 px high with a 26 px logo; model logo 19 px) so logos read on a
  phone. Markup and structure are unchanged.
- Skies still change per card (the website's worlds), but with the close
  camera they only show at the start and in the pull-out.

### Music map (measured, `tools/analyze_music.py`, `tools/kicks.py`)

- The track is 120 BPM, not 118: kicks land every 1.000 s, bars are 2.0 s,
  phrases 8 s. Downbeats in the source at 0.069 + 2k s.
- Source sections: 0.07 intro (pads) · 8.07 kick once per bar ·
  16.07 groove, riser 1 about 19.5-22.0 · 22.07-24.07 break with fill ·
  24.07 DROP (main groove) · 38.07-40.07 break · 40.07 groove ·
  48.07 breakdown · 56.07 groove, riser 2 about 59.5-62.0 with an 8th-note
  kick roll · 62.07-64.07 break with fill (identical to 22.07) · 64.07 the
  track just rings out to 66.77. The only real drop is 24.07.
- Loudness: ffmpeg ebur128, about -20 LUFS momentary in the intro, -10 in
  the groove.

### Music edit (supplied track only, no generation)

"The line lands on the drop" and "drop near the end" cannot both hold on the
raw track, because its only drop is at 24.07 s. So the cut reuses it. All
splices sit on downbeats; splice 2 joins two identical breaks, so it is
seamless.

| Video time | Source time | Content |
|---|---|---|
| 0.0 - 41.0 | 7.069 - 48.069 | pickup, kick build, groove + riser 1, break, DROP 1 at V17, groove, break V31-33, groove |
| 41.0 - 49.0 | 56.069 - 64.069 | groove, riser 2 (V44.5-47), break V47-49 |
| 49.0 - 61.0 | 24.069 - 36.069 | DROP 2 at V49 ("Private and Secure. Always."), groove, fade-out 57-61 |

Video beat grid: beats at every 0.5 s, downbeats at odd seconds
(1, 3, 5 …). Fade-in 0.35 s, fade-out 4 s, 30 ms crossfades at splices.
Built by `tools/make_music_edit.sh`.

### Reuse the window (series template)

Files: `compositions/chuk-window.html` is generated from
`tools/chuk-window.src.html` by `python3 tools/build_window.py` (it pastes in
the icon subset and the landing-page / invoice markup). Edit the `.src.html`,
never the generated file. `index.html` is generated by
`python3 tools/build_index.py` from `script.json` + `audio_meta.json`.

A later video copies `compositions/`, `tools/`, `assets/` and edits only:

1. `script.json` — the timed beats:
   - `prompt` (type / send times), `work` (tool rows), `cursor` (send click).
   - `blocks`: each reply block has `heading`, `text` or `slogan`, and a
     `card` with a `kind` from the card library (`models`, `connectors`,
     `platforms`, `artifact-page`, `artifact-invoice`, `encrypt`, `quote`,
     `recap`). `slogan` blocks take `clear_others` and `space_below`.
   - **Lift-out** (round 2): any card takes
     `"lift": {"at": s, "back": s, "sky": "dawn|day|paper|prism|library|network|night|street", "fit": [maxW, maxH], "dy": px}`.
     At `at` the card leaves the window and lands big on that world; at
     `back` it drops back into its slot. Use `"until": s` instead of `back`
     when a montage follows. Lifts size themselves so card text stays
     >= 28 px on screen.
   - `montage`: `{"at", "end", "end_sky", "steps": [[time, block id], …]}`
     flashes the lifted cards on the beat (video 05: quarter notes, then
     8ths, then 16ths into the hush).
   - `shots`: window camera. `"col": true` is the default close framing: it
     keeps every chat line inside the frame with >= 80 px margin (zoom 2.36
     for a 760 px column), keeps the composer out (only its top edge), and
     older lines fade out at the top of the thread. Special shots use `t`
     targets (`composer`, `block:<id>`, `work`, `window`) with `zoom` /
     `sub` / `dy`.
   - `skies` (first world), `outro` (pull-out fade, sun rise).
2. The prompt text (`PROMPT` in `tools/build_index.py`) and
   `audio_meta.json` (its own music cut and SFX times).
3. Run `python3 tools/build_window.py && python3 tools/build_index.py`.

Camera shots and lift start/end points are measured from the real layout
at init, so a new prompt or new copy keeps the framing. New card kinds go
into the `CARD` library in the source file. Known limit: the window file is
one large composition (lint warns `composition_file_too_large`); it stays
one file on purpose so the series has a single template.

### Round 2 changes (coordinator review)

- Cards lift out of the window onto the website's worlds: model menu
  (prism), connector chips (network), Spoke page (dawn), invoice (day),
  ciphertext card (night), price (paper), open-source chips (library).
- Window close-ups use column framing: no line cut by the frame edge, the
  composer is only a thin top edge, older lines fade at the top.
- The "So, in short" recap is gone. Riser 2 (41-47 s) is a montage of the
  lifted cards: quarter notes, then 8ths, then 16ths, into the hush.
- The side panel no longer opens in the window; the artifact card itself
  lifts into the landing page / PDF. The slogan lands in a cleared window.
- Soft whoosh SFX on each lift; model clicks moved to the lifted menu.

### Claims used (all from SERIES.md "Allowed claims")

Open-weight models, switch the model for each message; 50+ connectors
(Notion, Linear, GitHub, Todoist, Dropbox); artifacts (pages, PDFs, code);
AES-256-GCM, encrypted on your device, key stays on your device; €20 per
month with €16 AI credits included, one budget, one invoice; 100% open
source; Desktop (Mac, Windows, Linux), Android and Web; slogan
"Private and Secure. Always."; chuk.chat.
