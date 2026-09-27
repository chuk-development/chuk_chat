---
workflow: product-launch-video
flow: automation
storyboard: no
message: "One private chat for all your work."
destination: youtube
aspect: 1920x1080
language: en
audience: people who use AI chat for work and private questions, EU privacy-minded
length: 60s
angle: classic launch film (Anthropic-style: warm paper, rebuilt UI, typed prompts, logo sting)
narration: no
music: supplied
---

## Intent

01 Introducing Chuk Chat, the first of five launch videos for the Chuk Chat YouTube channel.
The classic launch film, closest to the Anthropic references: warm paper canvas, crisp rebuilt
app UI, a cursor that clicks, prompts that type, one short line of text per beat, logo sting at
the end. Message: "One private chat for all your work."

Approved concept (verbatim shape, `marketing/_shared/concepts/01-introducing.md`):

1. Hook (0–4 s): warm paper canvas. The composer box from the site is centred. A cursor clicks
   in. "Ask me anything !" placeholder, then a prompt types itself. Send button pops on a downbeat.
2. Title (4–7 s): "Introducing Chuk Chat" with the logo. Mono eyebrow "Private AI chat from Germany".
3. The worlds (7–48 s): 5 to 6 fast beats, one per world from the website: private questions
   (moon night), founder landing page (sunset), small business invoice (café awning), connectors
   (logos orbit the window), models (model picker, logos), on the go (phone). Each beat: one short
   headline + the dark app window doing the real action (prompt typed, "Worked for 6s", answer or
   artifact appears). Cut on the beat.
4. Proof (48–55 s): claim chips land one by one on beats: "End-to-end encrypted" · "Never used for
   training" · "Open-weight models only" · "€20/month, €16 AI credits included".
5. End card (55–60 s): logo, "Chuk Chat", "Private and Secure. Always.", "chuk.chat".

## Assets

- marketing/_shared/music/01-introducing.wav — supplied music bed (warm piano + electronic pulse,
  100 BPM, builds). It is an MP3 stream in a .wav name; transcoded to real PCM WAV at
  `assets/bgm/track.wav`. Whole track used from 0 s.
- marketing/_shared/capture/ — copied to `capture/` (no re-crawl).
- /home/user/git/chuk.chat (read-only) — app UI markup/CSS rebuilt from `layouts/partials/uc/*`,
  `assets/css/usecases.css`, `uc-menu.css`, `uc-assistant.css`; HugeIcons symbols from
  `app-icons.html`; copy from `content/_index.md`.
- assets/img/logo.svg — Chuk Chat logo (from the app repo `assets/logo.svg`).
- assets/logos/models/*.svg, assets/logos/connectors/*.png — from the website static folder.
- assets/fonts/jetbrains-mono-latin-wght.woff2 — "Chuk Chat Mono". assets/fonts/Arimo-wght.ttf —
  headline/UI sans (the app ships Arimo; it matches the site's light sans as captured).

## Customizations

- No voice-over, no TTS, no SCRIPT.md, no captions. Story told by on-screen text, UI motion, music.
- Cuts land on the 100 BPM grid (beat 0.6 s, bar 2.4 s, downbeats at 0.105 + 2.4·n s).

## Notes

- SERIES.md rules win over skill defaults (brand, allowed/forbidden claims, render lock).
- Allowed claims only. No competitor names or logos in any comparison. The OpenAI/Google/Meta
  model logos are left out entirely to stay clear of UWG risk.
- Decision: the caption keep-out band (bottom 17%) is released, because there are no captions.
  The app window may use the full frame height with a ~40 px margin.
- Decision: frame 01's typed prompt ("How do I tell my boss that I am burned out?") is the same
  message frame 03 answers, so the hook pays off in the first world.
- Decision: frames are built by `_work/build.py` (shared UI kit `_work/ui.css`, icons inlined from
  the website's HugeIcons sprite, deterministic GSAP driver for typing/streaming/scramble). Rebuild
  with `python3 _work/build.py`, then `node <skill>/scripts/assemble-index.mjs`. No frame workers
  were dispatched, so the ten frames share one kit and one look.
- Decision: no SFX. No login-free local SFX source was at hand, and generating clicks would be
  generation. The supplied music is the only sound.
- Decision: preference memory (`prefs.mjs record`) was not written; it would write outside the
  project directory.
- Headline copy is website copy (`content/_index.md`), except frame 07 ("Switch the model for each
  message." = allowed claim) and frame 09 ("One private chat for all your work." = the message).
