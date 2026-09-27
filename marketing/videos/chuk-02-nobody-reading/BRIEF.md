---
workflow: product-launch-video
flow: automation
storyboard: no
message: "Your chat is encrypted on your device, before we store it."
destination: youtube
aspect: 1920x1080
language: en
audience: people who ask an AI private things (health, money, work) and worry where it goes
length: 45s
angle: privacy as a visual, split screen (device vs server), tense then warm
style_preset: code-editorial
music: supplied
---

## Intent

Launch video 02 of the Chuk Chat series, "Nobody's reading". Approved concept
(`marketing/_shared/concepts/02-nobody-reading.md`):

- Length about 45 s. Music `02-nobody-reading.wav` (tense minor pulse, then a
  release into warm major). The release lands exactly on the switch to Chuk Chat.
- Message: "Your chat is encrypted before it leaves your device."
- Angle: privacy as a visual. Split screen.

Shape:

1. Hook (0-3 s): one message types itself in a plain box: "How do I tell my
   boss that I am burned out?" Text: "Everything you type into an AI goes
   somewhere."
2. Tension (3-20 s): the message travels as a card along a line to a server
   rack. On a neutral, unbranded, grey chat (never a real competitor) it
   arrives as readable text and collects stamps: "stored", "logged", "may be
   used for training". Cold, clinical. Ticking pulse.
3. Switch (20-22 s): hard cut on the music release. "Or…"
4. Chuk Chat (22-38 s): the same message in the real dark Chuk Chat window. On
   send, the text scrambles into ciphertext on the device. It travels to the
   server as noise. Server card from the site: "What our server stores",
   ciphertext only, "AES-256-GCM · the key stays on your device". Back on the
   device the answer appears readable: "Start with facts, not with blame."
5. Claim (38-41 s): "We keep only ciphertext. Never used for training."
6. End card (41-45 s): logo, "Chuk Chat", "Private and Secure. Always.",
   "chuk.chat".

Calm, editorial, Anthropic-launch-film register: warm paper, crisp rebuilt UI,
a cursor that clicks, prompts that type, one short line of text per beat.

## Assets

- assets/bgm/track.wav — `marketing/_shared/music/02-nobody-reading.wav`,
  transcoded to PCM WAV (the source file is MP3 data with a .wav name). The
  bed is cut from it (see Notes).
- assets/logo.svg / assets/logo-ink.svg — Chuk Chat logo from the app repo
  (`assets/logo.svg`), ink-filled copy for the end card.
- assets/fonts/ — Arimo (headline sans, the file the app ships), Ubuntu (the
  site's app UI font), JetBrains Mono variable (= "Chuk Chat Mono").
- capture/ — copy of `marketing/_shared/capture/` (not re-crawled).
- Rebuilt UI: the dark app window, composer, bubbles, timeline row and the
  "vault" card are copied from `/home/user/git/chuk.chat/assets/css/usecases.css`
  and `layouts/partials/uc/{private,a-chrome,a-composer,a-tl,a-acts}.html`.
  Icons are the HugeIcons/Material paths from `layouts/partials/uc/app-icons.html`.

## Customizations

- No voice-over, no TTS, no SCRIPT.md, no captions. On-screen text tells the story.
- Supplied music only, volume about 0.9, hand-written `audio_meta.json`.
- Quiet UI SFX from the bundled local media-use library (typing, click, pop,
  stamp thunks), well under the music.
- Scramble effect: mechanism adapted from the registry component
  `scramble-reveal` (deterministic LCG frame table, one `tl.set` per frame),
  restyled to the brand (no glow, base64 glyph set like the site's scramble).

## Notes

- Decisions (autonomous run, recorded here):
  - Prompt wording follows the site mock exactly: "How do I tell my boss that I
    am burned out?" (the concept drops "that"; the site copy wins so both halves
    and the site match).
  - Claim wording. The concept message says "before it leaves your device". The
    allowed claim is about storage: "Chats are encrypted on your device before
    we store them. We keep only ciphertext." The model still has to read the
    prompt to answer, so the on-screen line is "Encrypted on your device, before
    we store it." and the server side is labelled with the site's own words
    "What our server stores". No on-screen text says nobody can read it.
  - Neutral side: cold grey, unbranded window, no name, no logo, no real app's
    colours or layout. Stamps are phrased as possibilities or plain facts
    about storage ("stored", "logged", "may be used for training").
  - Music: the section change (sparse tense pulse → full continuous section)
    is at 25.352 s in the track, with a riser from 24.08 s. The cut starts the
    track at 4.352 s, so the release lands at video 21.000 s, the first
    Chuk Chat frame. Phrases are 5.053 s long (95 BPM, 8 beats); every frame
    boundary sits on a strong beat.
  - Preference recording (`prefs.mjs record`) skipped: it writes outside the
    project directory, which this run must not do.
  - `build-frame.mjs` inverted the palette (dark app windows dominate the
    capture). `frame.md` colors were corrected by hand to the SERIES brand.
- Build decisions (Step 5, built by the orchestrator, no frame workers, so the
  frame 5 → 6 → 7 window handoff stays pixel-identical):
  - All frames are generated by `_work/build_frames.py` (shared app window,
    fonts, cipher strings). Rebuild everything with `_work/rebuild.sh`
    (generate → assemble-index → transitions inject/verify → lint). Edit the
    generator, not the frame HTML.
  - Chuk Chat half lives in the site's own "night" world of the private use
    case (sky gradient + moon from `usecases.css`, moon halo dropped: no glow).
  - Round 2 (coordinator review, phone readability): hook box 1560 px / 72 px
    type, headline 128 px; frame 2 wide shot only ~0.3 s, then a 1.32× medium
    shot (card text 37 px); frames 5 and 7 show the window at zoom 2.0 (chat
    and answer 32 px) filling the width; frame 5 headline on its own beat
    after the window leaves; frame 6 rebuilt as two equal cards (labels 36 px,
    ciphertext 28–30 px mono, site wording "What our server stores"); claim
    chips 42 px; end card wordmark 140 px, slogan 54 px, URL 48 px.
    Round-1 generator kept as `_work/build_frames.round1.py`.
  - Transitions: hard cuts on strong beats everywhere, except frame 8
    (blur-crossfade 0.4 s out of the dark window into paper).
  - Frame 3 archive questions are invented, generic examples of private
    questions (health, money, work, family), not user data.
- Forbidden: competitor names/logos/UI, "most secure", "military-grade",
  "100% anonymous", VAT, user counts, ratings, glow, coloured box-shadow, neon.
