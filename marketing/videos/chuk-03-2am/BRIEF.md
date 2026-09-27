---
workflow: product-launch-video
flow: automation
storyboard: no
message: "Ask the questions you would not ask anyone else."
destination: youtube
aspect: 1920x1080
language: en
audience: "people who type private questions into AI chats late at night"
length: 57s
angle: "emotion first, product second"
narration: no
music: supplied
---

## Intent

Launch video 03 of the Chuk Chat series, "2 a.m.". Approved pitch
(`marketing/_shared/concepts/03-2am.md`), kept as written:

- Length about 50 s. Music: `03-2am.wav` (sparse late-night piano, then a warm swell).
- Message: "Ask the questions you would not ask anyone else."
- Angle: emotion first, product second. No product UI for the first ~18 s.
- Hook (0–4 s): deep night-blue canvas (the moon-night world of the site). A small
  clock "01:57". An empty input field. The cursor blinks. Silence, then the first
  piano note.
- The questions (4–22 s): prompts type slowly, one at a time, each with a new clock
  time. The writer hesitates, deletes, retypes. Human, not medical advice:
  "is this mole something to worry about" · "how do I tell my boss I am burned out" ·
  "can we still afford the flat if I lose my job" · "how do I say sorry to my sister".
  Each one is deleted before it is sent.
- The question (22–27 s): text alone: "The questions you would not ask anyone else."
  Then: "Who else reads them?"
- Swell (27–42 s): the music swells. The real Chuk Chat window fades in on the
  moon-night sky. This time the message is sent. "Thought for 4s". Answer from the
  site mock: "Start with facts, not with blame." A small lock line:
  "Encrypted on your device. We keep only ciphertext."
- Claim (42–46 s): "Never used for training. No tracking."
- End card (46–50 s): night-blue, logo + "Chuk Chat" + "Private and Secure. Always." +
  "chuk.chat".

Tone: quiet, intimate, a little lonely, then warm relief. Calm and editorial like the
site. No neon, no glow, no coloured box-shadow, no space background.

## Assets

- assets/bgm/track.wav — supplied music (`marketing/_shared/music/03-2am.wav`, re-encoded
  from its MP3 stream to real PCM WAV). assets/bgm/track-cut.wav is the cut used in the
  video: from 5.05 s of the track, 57.4 s long, so the first piano note lands on 1.40 s
  (first keystroke) and the swell hit (38.45 s in the track) lands on the app reveal at
  33.4 s. Made by `tools/make-audio.mjs`.
- assets/sfx/keys.wav — keystroke bed pre-mixed at the exact tape times from the bundled
  media-use `key-press.mp3` (local, no login).
- capture/ — copy of `marketing/_shared/capture/` (crawl of https://chuk.chat). The
  moon-night world (`capture/screenshots/scroll-005.png`, `scroll-010.png`) is the
  visual world.
- /home/user/git/chuk.chat (read-only) — the rebuilt app UI (private world partial,
  `usecases.css` app window, composer, bubbles, night sky, moon) is copied into the
  frames.
- /home/user/git/chuk_chat/assets/logo.svg — the Chuk Chat logo for the end card.
- assets/fonts/jetbrains-mono-latin-wght.woff2 — "Chuk Chat Mono" (site font).
- assets/fonts/Ubuntu-wght.ttf — the app UI font (`--ui-font: Ubuntu`).
- assets/fonts/InterVariable.ttf — light sans for headlines (Inter is in the site's
  `--font-sans` stack).

## Customizations

- Human typing: uneven key timing, pauses, typos, backspaces, select-all delete.
  Deterministic and seek-safe (seeded PRNG, one proxy driver per frame).
- Quiet key-press SFX, pre-mixed into one track at the exact keystroke times
  (bundled media-use `key-press.mp3`, local, no login).
- The clock advances per question (01:56 → 01:57 → 02:09 → 02:23 → 02:38), time passes while nobody sends.

## Notes

- Decision (length): the pitch says "about 50 s". The build runs 57.4 s. Four human-paced
  questions with hesitations and edits need about 27 s, and the only silence before a
  first piano note that fits the hook is at 4.8–6.3 s of the track. Cutting to 50 s would
  either rush the typing or drop a question. All beats keep the pitch's order.
- Decision (preferences): `prefs.mjs record` was not run; it can write to `~/.media/`,
  which is outside this project (hard limit: write only inside the project).
- Decision (fonts): headlines use Inter variable at weight 300 ("Chuk Sans"), as the
  site's headline stack lists Inter and its headlines are a light sans.

- Series rules: `marketing/_shared/SERIES.md` win over any skill default.
- No voice, no TTS, no SCRIPT.md, no captions. Music is supplied, not generated.
- Allowed claims only: encrypted on your device before we store them, we keep only
  ciphertext, AES-256-GCM, the key stays on your device, never used for training,
  no tracking. No competitor names. No "most secure", no user counts.
- Slogan exact: "Private and Secure. Always."
- Render only through the shared flock lock. Deliver to `marketing/out/03-2am.mp4`.
  No git commit.
