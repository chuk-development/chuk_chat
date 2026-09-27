# Chuk Chat launch series — shared brief

Five launch videos for the Chuk Chat YouTube channel. Each video is one
HyperFrames project. This file holds the rules that all five share. Read it
completely before you start.

## Run shape (fixed, do not ask)

- `flow: automation`, `storyboard: no`. The owner said "build it, I give
  feedback later". Ask no questions. Decide, record the decision, continue.
- Workflow: `product-launch-video` (installed at
  `~/.claude/skills/product-launch-video/SKILL.md`). Follow its steps in
  autonomous mode.
- Canvas: 1920x1080, 30 fps. Destination: YouTube (16:9).
- Language on screen: English.
- **No voice-over. No TTS. No narration. No SCRIPT.md.** The story is told by
  on-screen text, UI motion and music only.
- **Music is supplied** (see "Music" below). Do not generate BGM. Do not call
  MusicGen, Lyria or HeyGen.

## Project locations

| Video | Project directory | Music file |
|-------|-------------------|------------|
| 01 Introducing | `marketing/videos/chuk-01-introducing` | `marketing/_shared/music/01-introducing.wav` |
| 02 Nobody's reading | `marketing/videos/chuk-02-nobody-reading` | `marketing/_shared/music/02-nobody-reading.wav` |
| 03 2 a.m. | `marketing/videos/chuk-03-2am` | `marketing/_shared/music/03-2am.wav` |
| 04 The receipt | `marketing/videos/chuk-04-receipt` | `marketing/_shared/music/04-receipt.wav` |
| 05 Announce yourself | `marketing/videos/chuk-05-announce-yourself` | `marketing/_shared/music/05-announce-yourself.wav` |
| 06 Features | `marketing/videos/chuk-06-features` | `marketing/_shared/music/05-announce-yourself.wav` (re-edited) |

Status 2026-09-28: the owner rejected round 1 as "all the same". 06 replaces
01. Every video must have its own job, hook and prompts (see
`tasks/lessons.md`, 2026-09-27). Proposed line-up: 06 features, 03 privacy,
04 humour, new "models + price", new "small-business use case".

All paths are relative to the repository root `/home/user/git/chuk_chat`.
Write only inside your own project directory. Never write to `/tmp` or to a
scratchpad directory. Never edit the website repository.

## Brand

Source: capture of https://chuk.chat in `marketing/_shared/capture/`
(`extracted/tokens.json`, `extracted/design-styles.json`,
`screenshots/contact-sheet-*.jpg`). Look at the contact sheets first.

- Canvas (warm paper): `#FDFBF7`. Tiles: `#F3F0E8`, `#ECE8DE`. Lines: `#E6E1D5`.
- Ink: `#26251F`. Ink soft: `#5F5D55`. Ink faint: `#8C8A80`.
- Site accent (goldenrod): `#B8860B`. Use it for small eyebrows only.
- App accent (coral): `#D97757`. Send button, user message bubbles.
- App surface (dark window): `#262624` / `#26251F`, text on it `#E8E4D8`.
- Type: "Chuk Chat Mono" = JetBrains Mono variable
  (`/home/user/git/chuk.chat/static/fonts/jetbrains-mono-latin-wght.woff2`).
  The app UI and eyebrows are mono. Headlines on the site are a light sans.
  Embed every font file into the project. Do not rely on system fonts.
- Logo: `assets/logo.svg` in this repository. Name: "Chuk Chat".
- Slogan (exact wording, do not change): **Private and Secure. Always.**
- The site is calm and editorial. The "worlds" have painted gradient skies
  (moon night, sunset, café awning, soft green grid). No neon, no glow, no
  coloured box-shadow, no space backgrounds (video 04 may parody them once).

## Real UI to reuse (copy, do not re-invent)

The website already rebuilds the app UI in HTML/CSS at the real proportions.
Copy markup and CSS from these files into your project (read-only source):

- `/home/user/git/chuk.chat/layouts/index.html` — the home page with all nine
  "worlds" (dark app window, composer, sidebar, artifacts panel).
- `/home/user/git/chuk.chat/layouts/partials/uc/*.html` — one partial per
  world: `private.html`, `founders.html`, `business.html`, `connectors.html`,
  `models.html`, `engineers.html`, `prototypers.html`, `research.html`,
  `onthego.html`, plus parts (`a-composer.html`, `a-chrome.html`,
  `a-tl.html`, `a-acts.html`, `a-art.html`, `app-icons.html`, `sprite.html`).
- `/home/user/git/chuk.chat/assets/css/usecases.css`, `uc-assistant.css`,
  `uc-sidebar.css`, `uc-menu.css`, `styles.css`.
- `/home/user/git/chuk.chat/public/index.html` — the built page (all partials
  resolved). Use it when the Hugo templates are hard to read.
- Model logos: `/home/user/git/chuk.chat/static/logos/models/*.svg`.
  Connector logos: `/home/user/git/chuk.chat/static/logos/connectors/*.png`.
- Real app screenshots: `assets/screenshots/*.webp` (desktop) and
  `fastlane/metadata/android/en-US/images/phoneScreenshots/*.png` (phone).

Rebuilt HTML UI is better than a screenshot when it must move (typing,
streaming, clicks). Use a screenshot only for a static beat.

## Allowed claims (use only these, word-for-word facts)

All claims come from chuk.chat. Do not invent numbers or features.

- Private AI chat from Germany.
- End-to-end encrypted storage. Chats are encrypted on your device before we
  store them. We keep only ciphertext. AES-256-GCM, the key stays on your device.
- Never used for training. No tracking.
- Open-weight models only (take model names from `models.html`).
- Switch the model for each message.
- €20 per month, €16 AI credits included. One budget, one invoice.
- 50+ connectors (MCP): Notion, Linear, Todoist, Dropbox, GitHub and more.
- 100% open source.
- Desktop (Mac, Windows, Linux), Android and Web.
- The use-case prompts and answers that the website mocks show.

Forbidden:

- Naming or showing a competitor (ChatGPT, OpenAI, Claude, Gemini, Meta AI…)
  in a negative comparison. German competition law (UWG) makes that an
  expensive warning letter. Say "most AI apps" or show a neutral unbranded
  chat instead.
- "Most secure", "military-grade", "100% anonymous", VAT/MwSt, closed models,
  user counts, ratings.

## Music

- Your track: `marketing/_shared/music/<NN-slug>.wav` (table above). Copy it
  to `assets/bgm/track.wav` in your project.
- Run `npx hyperframes beats` in your project and cut on the beat grid.
  Big reveals land on downbeats.
- The track is longer than the cut. Pick the strongest section. Trim with a
  short fade-in and a longer fade-out. The music must cover the full cut
  with no silent tail.
- There is no voice, so the bed is the main sound: volume about 0.9.
- Write `audio_meta.json` by hand with one `bgm` cue (`path`, `volume`,
  `mode: "supplied"`, `duration_s`). Mark the storyboard `music: supplied`.
  Do not run `audio.mjs` for TTS or BGM.
- Small UI sounds (key clicks, a send "pop", a receipt printer) are allowed
  via `/media-use` SFX if they come from a local or catalog source without a
  login. Keep them quiet under the music.

## Quality bar

- Reference style: the Anthropic launch films (warm paper, crisp rebuilt UI,
  a cursor that clicks, prompts that type, one short line of text per beat,
  logo sting at the end). Contact sheets:
  `_scratch/trailer_ref/sheet_*.jpg` (and the MP4s next to them).
- The first 2 seconds must hook: something moves or is typed at frame 0.
- One idea per beat. Maximum about 8 words of headline text on screen.
- Text must be readable on a phone. Round 1 of videos 02 and 04 failed on
  this, so these are hard minimums (effective size on the 1920x1080 frame):
  - Headlines ≥ 88 px. Eyebrows ≥ 28 px. Chips ≥ 30 px.
  - UI text inside the app window (prompt, bubble, answer, tool rows) ≥ 28 px.
    Punch in or scale the window to get there.
  - No shot shows the full window small in a big empty field for longer than
    about 0.7 s. The default framing is close.
  - Never put a headline over the UI.
  - End card: logo + "Chuk Chat" ≥ 110 px, slogan ≥ 44 px, URL pill ≥ 36 px.
- Check the minimums on a sheet made from the rendered MP4, not only on the
  snapshots: `ffmpeg -i renders/video.mp4 -vf fps=1,scale=480:-1,tile=8x8 -frames:v 1 _work/sheet.jpg`.
- End card for every video: logo + "Chuk Chat" + "Private and Secure. Always."
  + "chuk.chat". Hold it at least 2.5 s.

## Render and delivery

- Lint, check and snapshot as the workflow says. Look at the contact sheet
  yourself and fix what looks wrong before you render.
- Only one render runs at a time on this machine. Render through the shared
  lock:
  `flock /home/user/git/chuk_chat/marketing/_shared/.render.lock npx hyperframes render --quality high --output renders/video.mp4`
- Copy the result to `marketing/out/<NN-slug>.mp4`.
- Do not commit. The coordinator commits.
- Report back: MP4 path, final duration, contact sheet path, frame ids, and
  any claim or asset you were unsure about.
