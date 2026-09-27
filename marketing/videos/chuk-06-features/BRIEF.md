---
workflow: product-launch-video
flow: automation
storyboard: no
message: "One app. All of this."
destination: youtube
aspect: 1920x1080
language: en
audience: people who use AI chat every day and want one app for all of it
length: 65s
angle: a fast list of RESULTS, one feature per beat, the same grammar every beat
narration: no
music: supplied
---

## Intent

Launch video 06 of the Chuk Chat series, "What Chuk Chat does". About 64 s,
YouTube 16:9, no voice. It replaces video 01, whose opening (send a message,
nothing happens, the logo assembles) the owner rejected. Concept:
`marketing/_shared/concepts/06-features.md` (it wins on content).

The viewer must leave with a list in their head: research, charts, maps,
weather, images, files, documents, email, tools, assistants, models, Android,
everywhere.

- Hook (0-4 s): frame 0 is already busy. A wall of 9 result cards tiles in on
  16th notes while the camera pulls back. Headline in its own band:
  "One app. All of this." (lands in the break, V2).
- 13 feature beats of 4.0 s each (V4-56), one per 2 bars. Same grammar every
  beat: left third = mono counter "03 / 13" + feature name (112 px) + one plain
  line (44 px); right two thirds = the result card, big (>= 60 % of the frame
  height), lifted onto one of the website's worlds. The prompt is already a
  sent one-line bubble; the RESULT builds (chart draws, route draws, image
  resolves, page builds, calendar card lands).
- Price line (V56-58), then the end card (V58-64): logo + "Chuk Chat",
  "Private and Secure. Always.", "chuk.chat". Static, on the beat.

No typing animation, no logo assembly, no "Introducing" card. Every prompt and
result is new in the series.

## Assets

- assets/bgm/track.wav — `marketing/_shared/music/05-announce-yourself.wav`
  (MP3 data with a .wav name) transcoded to PCM WAV.
- assets/bgm/track_edit.wav — the 64 s cut, built only from track.wav by
  `tools/make_music_edit.sh`.
- assets/img/generated-workshop.jpg — `marketing/_shared/images/generated-workshop.png`
  (AI-generated image for the "Create images" beat), re-encoded to JPEG.
- assets/fonts/ — Chuk Chat Mono (JetBrains Mono variable, OFL), Ubuntu
  variable (the website's app UI font), Inter variable (light sans headlines,
  OFL). From video 05. Inter and Ubuntu are subset to Latin-1 + the few
  signs used (€ ° · → – “ ” …) as woff2 (`pyftsubset`, axes kept): the render
  inlines every font once per frame file, and the full 1-2 MB TTFs x 15
  frames made a 15 MB page that Chrome could not load in time.
- assets/logos/models/*.svg, assets/logos/connectors/*.png — from
  chuk.chat/static/logos (read-only source).
- assets/logos/chuk-chat-logo.svg — `assets/logo.svg` of this repository.
- assets/sfx/ — bundled media-use SFX (click-soft, pop), local, no login.
- Brand capture: `marketing/_shared/capture/` is read in place, not copied
  (coordinator rule).

## Notes

### Decisions (autonomous run, recorded)

- Style: `frame.md` is copied from video 05 (preset `code-editorial`,
  remixed onto the same brand tokens). `build-frame.mjs` was not run again,
  because it needs `capture/` inside the project and the capture must stay
  shared.
- Preferences were not recorded with `prefs.mjs` (it writes outside the
  project directory; the coordinator allows writes only inside it).
- Sign-in: `hyperframes auth status` = signed out. Nothing needs HeyGen: no
  TTS, no generated music, music is supplied.
- Frame workers: not dispatched. Every beat uses the same grammar and one UI
  kit, so one generator (`tools/build.py`) writes all 15 frame compositions
  and `index.html`. Workers in parallel would drift apart in exactly the
  things that must stay identical (text column, counter, card size).
- Captions: skipped (no narration).
- Cards are the app's own markup and CSS (class names from chuk.chat
  `layouts/partials/uc/*`, `usecases.css`, `uc-menu.css`, `uc-assistant.css`)
  at logical px, scaled with `zoom: 1.9`, so every UI text is >= 15 logical
  px = >= 28.5 px on the 1920x1080 frame.
- Hard cuts on every downbeat between beats. The card rises into place
  (the lift-out cue of video 05) and pushes slowly while the result builds.
- Worlds per beat, never the same twice in a row: library, prism, network,
  dawn, paper, night, day (café awning), prism, network, library, dawn,
  street, prism; paper for price and end card.
- Model list (from the website `models.html`): DeepSeek V4 Pro 0813, Kimi K3,
  GLM 5.3, Qwen3.8 27B, MiniMax M3, Mistral Small 4. gpt-oss-120b is left out
  on purpose so no OpenAI logo is on screen.
- The artifact public link uses the real host `artifacts.chuk.chat`
  (`lib/services/api_config_base.dart`).
- The route card copies the app's route widget: blue polyline, green origin
  ring, red destination pin, summary row "km · min".

### Music map (measured, `tools/analyze_music.py`)

Track: 120 BPM, bars 2.0 s, source downbeats at 0.069 + 2k s. Only one real
drop in the source (24.07 s). Sections: groove + riser 1 16-22, break 22-24,
DROP 24.07, break 38-40, groove 40-48, breakdown 48-56, groove + riser 2
56-62, break 62-64 (identical to 22-24), ring-out 64-66.8.

| Video | Source | Content |
|---|---|---|
| 0-28 | 20.069-48.069 | riser 1 tail (hook wall), break V2-4 (headline), DROP 1 at V4, groove, break V18-20, groove |
| 28-36 | 56.069-64.069 | groove, riser 2 V31.5-34, break with fill V34-36 |
| 36-64 | 24.069-52.069 | DROP 2 at V36 (Your tools), groove, break V50-52, groove, breakdown from V60 under the end card |

Video downbeats at every even second; beats every 0.5 s. Kicks in the edit
verified on whole seconds, silent in the breaks. Fade-in 0.12 s, fade-out
59.5-64 s, 30 ms crossfades at the two splices.

### Render notes

- First render hung at `Page.navigate` (60 s timeout): the render compiler
  inlines every `@font-face` file as base64 once per frame file, and the full
  Inter + Ubuntu TTFs (1.9 MB) x 15 frames made a 15 MB page. Subset woff2
  fonts brought it to 3.5 MB and the render passes (about 1 min).
- Final: `renders/video.mp4`, 64.0 s, 1920x1080, 30 fps, h264 + aac,
  -14.3 LUFS integrated. Copy: `marketing/out/06-features.mp4`.
- Readability checked on full-resolution frames (`tools/frames_check.sh`
  writes one per beat to `_work/check/`), sheet `_work/sheet.jpg`.
