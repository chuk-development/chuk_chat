---
format: 1920x1080
fps: 30
duration: 45.6s
message: "Your chat is encrypted on your device, before we store it."
arc: BAB — hook → before (neutral app: stored, logged, may train) → "Or…" → after (Chuk Chat: ciphertext only) → claim → end card
audience: people who ask an AI private things and worry where it goes
mode: autonomous
music: supplied
captions: skipped (no narration; the on-screen text is the story)
---

# 02 — Nobody's reading

## Video direction

- **Palette** (from `frame.md`): warm paper `cream #FDFBF7` for hook, "Or…", claim and end
  card; ink `#26251F`, ink-soft `#5F5D55`. Tension half = a cold clinical grey world
  (`#E7E9EC` ground, `#F6F7F9` window, `#3A3F47` rack, muted stamp red `#A8463C`) — the
  only non-brand palette, and it exists only to be left behind. Chuk Chat half = the site's
  own "night" world for the private questions (gradient `#0A0F1F → #1D2444`, cream moon, a
  few stars) with the real dark app window `#262624`, coral `#D97757` send, bubble `#B6674D`.
  Goldenrod `#B8860B` for small mono eyebrows only.
- **Type**: headlines Arimo 400–500, sentence case, −0.04em, ≥ 72 px. App UI Ubuntu, chat
  text Chuk Chat Mono. Every UI text is ≥ 22 px effective on the 1920 canvas (the app window
  is shown at 1.45× its logical size).
- **Motion grammar**: long-tail `power3.out` / `expo.out` entrances, no bounce; stamps are the
  only hard, fast moves (the cold side). Every frame boundary is a strong beat of the track.
  Reveals follow the music beats (no voice): one element per beat, never front-loaded.
- **Rhythm**: F1 hooks with typing at frame 0. F2–F3 tick (the dotted line lights one tick per
  beat, rack LEDs blink on the drum fill). F4 is the held breath on the riser. F5 lands on the
  release. F8 and F9 are the held, calm beats.
- **Negative list**: no competitor name, logo, colours or layout; no glow, no coloured
  box-shadow, no neon, no space stock imagery; no CSS transitions; no slideshow (front-load
  then freeze) and no screensaver drift.

## Frame 1 — Hook: it goes somewhere

- scene: A plain box on warm paper types the burnout question by itself; the headline rises above it.
- voiceover: ""
- duration: 4.264s
- transition_in: cut
- status: animated
- src: compositions/frames/01-hook.html
- type: hook
- persuasion: Pain validation
- beat: tension
- blueprint: typewriter-reveal (Adapt)
- focal: the typed question
- sfx: typing (0.0s), soft
- asset_candidates:

narrativeRole: open cold on the private question everyone has typed somewhere.
keyMessage: Everything you type into an AI goes somewhere.

Adapt: keep "someone is typing this" as the engine; no brand payoff yet — the payoff is the headline.
Scene 1 (0.0–1.74s): centered white box on paper, caret at frame 0, the question types itself
  character by character (Arimo 54 px). Centered, ~70 % width.
Scene 2 (1.74–2.6s): on the strong beat the box glides down; headline "Everything you type into
  an AI goes somewhere." rises word by word above it (Arimo 84 px, two lines).
Scene 3 (2.6–4.26s): held read; the caret keeps blinking.

## Frame 2 — The trip to their server

- scene: Split screen: a neutral grey chat sends the message; it travels as a readable card along a ticking line into a server rack.
- voiceover: ""
- duration: 6.631s
- transition_in: cut
- status: animated
- src: compositions/frames/02-trip.html
- type: pain_point
- persuasion: Show-don't-tell
- beat: unease
- blueprint: camera-journey (Adapt — action roundtrip, locked camera)
- focal: the travelling message card
- sfx: click-soft (1.578s), whoosh-short (1.75s)
- asset_candidates:

Scene 1 (0.0–1.3s): left half: unbranded grey chat window (no name, no logo) with the question in
  its composer, label "YOUR DEVICE". Right half: grey server rack rises in, label "THEIR SERVER";
  a dotted line draws between them.
Scene 2 (1.3–1.58s): pointer glides to the grey Send button; click on the phrase downbeat.
Scene 3 (1.58–5.05s): the message lands as a grey bubble; a readable copy lifts off as a card and
  travels along the line, each tick lighting as it passes (ticking pulse).
Scene 4 (5.05–6.63s): the card slots into the rack; the rack LEDs blink with the drum fill.

## Frame 3 — Stored. Logged. May be used for training.

- scene: Inside the server the message is a readable record; three stamps slam onto it, then it pulls back into an archive of other private questions.
- voiceover: ""
- duration: 8.526s
- transition_in: cut
- status: animated
- src: compositions/frames/03-stamps.html
- type: pain_point
- persuasion: Pain agitation
- beat: anxiety
- blueprint: zoom-out-workspace-reveal (Adapt — record close-up, zoom-out to the archive)
- focal: the record card with the stamps
- sfx: impact-bass-2 (0.947s, 3.474s, 5.053s), quiet
- asset_candidates:

Scene 1 (0.0–0.95s): close-up record card: mono meta row, the question in Arimo 56 px, readable.
Scene 2 (0.95s): stamp "STORED" slams on (upper right).
Scene 3 (3.47s): stamp "LOGGED" slams on.
Scene 4 (5.05s): stamp "MAY BE USED FOR TRAINING" slams on, the biggest.
Scene 5 (6.0–8.53s): one decelerating zoom-out: the card becomes one tile in a grid of other
  readable private questions (health, money, family), each stamped; headline "Out of your hands."

## Frame 4 — Or…

- scene: Warm paper, silence before the release: "Or…" builds dot by dot on the riser.
- voiceover: ""
- duration: 1.579s
- transition_in: cut
- status: animated
- src: compositions/frames/04-or.html
- type: product_intro
- persuasion: Negative contrast
- beat: curiosity
- blueprint: kinetic-type-beats (Adapt)
- focal: "Or…"
- asset_candidates:

Scene 1 (0.0–1.58s): "Or" lands at 0.05 s (Arimo 180 px), the three dots arrive on the riser
  (0.35 / 0.65 / 0.95 s). Held.

## Frame 5 — Chuk Chat: encrypted on your device

- scene: Release. The real dark Chuk Chat window lands in the night world; send; the bubble scrambles into ciphertext on the device.
- voiceover: ""
- duration: 5.053s
- transition_in: cut
- status: animated
- src: compositions/frames/05-encrypt.html
- type: product_intro
- persuasion: Show-don't-tell proof
- beat: relief
- blueprint: prompt-type-submit-generate (Adapt — the answer is the ciphertext)
- focal: the user bubble turning into ciphertext
- sfx: click-soft (0.948s), pop (1.0s)
- asset_candidates:

Round 2 (phone readability): the window is shown at zoom 2.0 (chat text 32 px) and fills the width.
Scene 1 (0.0–0.95s): on the release downbeat the big window rises in; the question sits in the composer;
  pointer moves to the coral send button.
Scene 2 (0.95–1.3s): click, the coral user bubble appears, composer empties.
Scene 3 (1.35–2.45s): the bubble text scrambles left→right into base64 noise (cipher grey `#33343C`).
Scene 4 (3.08–5.05s): the window drops away; on the 3.474 beat the headline gets its own beat, centred on the sky:
  "Encrypted on your device, / before we store it." (Arimo 112 px). Never over UI.

## Frame 6 — It travels as noise

- scene: Split screen in the night world: two cards, ciphertext packets cross from "Your device" to "Our server", the site's vault card shows what the server stores.
- voiceover: ""
- duration: 5.053s
- transition_in: cut
- status: animated
- src: compositions/frames/06-noise.html
- type: feature_showcase
- persuasion: Show-don't-tell proof
- beat: trust
- blueprint: compose
- focal: the vault card ("What our server stores")
- sfx: whoosh-short (0.95s)
- asset_candidates:

Round 2: two equal cards, labels 36 px mono.
Scene 1 (0.0–0.9s): "Your device" card (the app's ciphertext bubble, 30 px mono, over the app composer) and
  "Our server" card (site vault, badge "What our server stores") slide in; the dotted line draws.
Scene 2 (0.95–3.0s): four ciphertext packets (28 px mono) cross the gap one by one; each landing adds its
  part to the stored ciphertext bubble in the vault.
Scene 3 (3.47–5.05s): stored answer ciphertext and "AES-256-GCM · the key stays on your device" arrive. Held.

## Frame 7 — Readable on your device

- scene: Back on the device: the bubble decrypts, "Thought for 4s", the real answer streams: "Start with facts, not with blame."
- voiceover: ""
- duration: 5.052s
- transition_in: cut
- status: animated
- src: compositions/frames/07-answer.html
- type: benefit_highlight
- persuasion: Feature-to-benefit translation
- beat: relief + control
- blueprint: prompt-type-submit-generate (Adapt — the answer streams)
- focal: the streamed answer
- asset_candidates:

Round 2: same big window as frame 5 (zoom 2.0), eyebrow on the sky above it.
Scene 1 (0.0–0.75s): eyebrow "Back on your device"; the ciphertext bubble decrypts to the readable question.
Scene 2 (1.05s): "Thought for 4s ›" row.
Scene 3 (1.35–3.3s): the bold lead "Start with facts, not with blame." then three bullets stream (32 px).
Scene 4 (3.45–5.05s): action bar; held read.

## Frame 8 — The claim

- scene: Warm paper: "We keep only ciphertext." then "Never used for training." and the site chips.
- voiceover: ""
- duration: 5.053s
- transition_in: blur-crossfade 0.4s
- status: animated
- src: compositions/frames/08-claim.html
- type: benefit_highlight
- persuasion: Risk reversal
- beat: trust
- blueprint: titlecard-reveal (Adapt — two lines + chip row)
- focal: the two claim lines
- asset_candidates:

Scene 1 (0.0–0.95s): line 1 slides up and settles (Arimo 112 px).
Scene 2 (0.95s): line 2 on the strong beat, ink-soft.
Scene 3 (3.47–5.05s): chip row "End-to-end encrypted storage · No tracking"; held.

## Frame 9 — End card

- scene: Logo, "Chuk Chat", "Private and Secure. Always.", "chuk.chat" on warm paper, held.
- voiceover: ""
- duration: 4.389s
- transition_in: cut
- status: animated
- src: compositions/frames/09-endcard.html
- type: cta
- persuasion: Brand recall
- beat: peace of mind
- blueprint: logo-assemble-lockup (Adapt — calm settle)
- focal: the logo lockup
- asset_candidates: assets/logo-ink.svg — Chuk Chat logo, ink fill

Scene 1 (0.0–1.2s): logo scales in 0.9→1, wordmark, slogan, URL arrive one by one.
Scene 2 (1.2–4.39s): held still (≥ 2.5 s); the music decays under it.
