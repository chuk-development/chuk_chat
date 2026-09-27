---
format: 1920x1080
fps: 30
duration: 57.4s
message: "Ask the questions you would not ask anyone else."
arc: Hook (2 a.m., an empty field) → Unsent questions → The real question → Sent, answered, encrypted → Claim → End card
audience: people who type private questions into AI chats late at night
mode: autonomous
music: supplied
captions: skipped (no narration; on-screen text carries the story)
---

# 03 — 2 a.m. · Storyboard

## Video direction

- **World.** One continuous place: the chuk.chat moon-night sky (`.uc-scene--night`
  gradient + horizon radial, seeded small stars, the site's moon without halo). Every
  frame paints the identical sky on its own `class="clip"` ground. Stars twinkle and the
  moon sinks ~0.9 px/s as a pure function of GLOBAL time (each frame carries its global
  start `G0`), so the frame seams are invisible and time visibly passes.
- **Palette.** Night `#0A0F1F → #131A33 → #1D2444`; ink `#F6F3EC`; faint `#8E97B5`;
  coral `#D97757` only for the caret, the Chuk Chat send button and the user bubble
  (`#B6674D`); gold `#F2C56B` never larger than an eyebrow. No glow, no coloured shadow.
- **Type.** Chuk Chat Mono for typing, clock, app chat text. Chuk Sans (Inter 300) for
  the three statement lines. Ubuntu only inside the app window.
- **Motion grammar.** Slow and soft (`power2.out`, `sine.inOut`, 0.6–1.2 s). The typing
  is the only fast motion: deterministic keystroke tapes with a seeded PRNG — bursts of
  0.05–0.16 s inside words, 0.2–0.5 s at spaces, 0.6–1.4 s hesitations, typos fixed with
  backspace, three different ways to delete (hold backspace, select-all, word by word).
  Caret is solid while keys are pressed and blinks (0.53 s on/off) when idle.
- **Camera.** Night frames: one very slow push on the field group (scale 1.00 → 1.035
  over 0–28.6 s, keyed to global time). Frame 4: the window arrives close (1.75), one
  glide from composer to thread, one drop-away. Never more.
- **Phone minimums (coordinator).** Typed prompts ≥ 56 px in a ≥ 1200 px field (60 px,
  1620 px). Clock ≥ 40 px (66). Headlines ≥ 88 px (88–104). App UI text ≥ 28 px on screen
  (scale 1.75). No headline over UI. End card: "Chuk Chat" 118 px, slogan 64 px, URL
  pill 44 px.
- **Music map (cut starts at 5.05 s of the track, 57.4 s long).** Silence 0–1.4 s,
  **first piano note 1.40 s = first keystroke** (beats 1.45). Q2's first key on the
  7.85 note. Piano silence 17.5–20.6 s (Q3's long pause). Fuller piano from 20.6 s.
  Breath (falling) 31.8–33.4 s. **Swell hit 33.44 s** = app reveal. Percussive hits
  (`hyperframes beats` strength ≥ 0.88, confirmed as −5 dB RMS transients): 35.45,
  36.65, 38.65 (send), 39.84 ("Thought for 4s"), 41.86, 43.06, 45.05 (ciphertext),
  46.25 (window drops, lock line), 48.24, 49.44 (claim), 51.44, 52.66 (end card), 54.65. Natural decay from 55.85 s, fade-out 56.0–57.4 s. Why 57.4 s and not 50 s: four human-paced questions with edits need
  ~27 s; the only silence before a first note that fits the hook is at track 4.8–6.3 s.
- **Stillness allocation.** Frame 3 is a deliberate held read (two lines, one each).
  Frame 6 holds ≥ 3.5 s with all elements in.
- **Negative list.** No competitor names or look-alike UIs. No "most secure", no
  "military-grade", no counts. No UI before 27 s except the bare unbranded field. No
  front-loaded frames, no exit tweens in non-final frames, no `repeat: -1`, no CSS
  animations, no Math.random / Date.

## Frame 1 — 01:57

- status: animated
- src: compositions/frames/01-hook.html
- duration: 7.4s
- transition_in: cut
- scene: Night sky, clock 01:57, an empty field; the first key lands on the first piano note; "is this mole something to worry about" is typed, then held-backspace away
- poster: 4.6
- blueprint: typewriter-reveal (Adapt — Hook variant, typed inside an unbranded input pill; no brand pop, the line is deleted instead)
- asset_candidates: assets/scroll-010.png — reference for the moon-night world (not mounted)
- focal: the typed line in the field
- roles: sky = background (painted, full-bleed) · clock = supporting · field + caret = focal
- sfx: key-press per keystroke (pre-mixed into assets/sfx/keys.wav)

Scene 1 (0.0–1.4s): sky, moon upper-left, clock "01:56" rolls to "01:57" at 0.45 s
(centered, y≈313, Chuk Chat Mono 66 px, faint), the empty field centered at y≈554
(1620×160, radius 48). The coral caret blinks at the line start. Frame 0 already shows
the caret on and the stars moving.
Scene 2 (1.4–5.1s): first key on the first piano note. "is this mole" in a burst → 0.6 s
hesitation → "something to worry about". The dim send button lifts to "enabled" grey
when text exists.
Scene 3 (5.1–5.8s): hold. Caret blinks. Nobody presses send.
Scene 4 (5.8–6.9s): held backspace eats the line right to left (22 ms repeat after a
0.34 s delay). Empty field, caret blinks.

## Frame 2 — Unsent

- status: animated
- src: compositions/frames/02-questions.html
- duration: 21.2s
- transition_in: cut
- scene: Three more questions at 02:09, 02:23, 02:38 — typed with hesitation and edits, each deleted before it is sent
- poster: 12.4
- blueprint: typewriter-reveal (Adapt — backspace-and-retype edits; three delete styles)
- asset_candidates: assets/scroll-010.png — reference for the moon-night world (not mounted)
- focal: the typed line in the field
- roles: sky = background · clock = supporting (rolls to the next time) · field = focal
- handoff_in: field + clock group — x 0, y 0, scale continues the global push (1 + 0.035·ease(t/22)), opacity 1, empty text, clock "01:57" then rolls to "02:09" at local 0.2s
- sfx: key-press per keystroke (pre-mixed)

Scene 1 (0.0–7.1s, clock rolls to 02:09 at 0.05): first key on the 7.8 s note. "how do I
tell my boss I am tired" → 0.6 s pause → backspace "tired" → "burned out". Hold.
Select-all (coral-tint highlight) → gone.
Scene 2 (7.45–15.6s, clock 02:23): "can we still afford the flat if" → 1.45 s pause in the
piano silence → "I lose my job" (wraps to a second line; the field grows downward).
Hold. Deleted word by word (Ctrl+Backspace).
Scene 3 (15.65–21.2s, clock 02:38, fuller piano): "how do I say sorry" → pause → "to my
sister". The longest hold (1.0 s). One decisive select-all → gone. Empty field.

## Frame 3 — Who else reads them?

- status: animated
- src: compositions/frames/03-who-reads.html
- duration: 4.8s
- transition_in: cut
- scene: The field and clock dissolve; "The questions you would not ask anyone else." then "Who else reads them?"
- poster: 3.6
- blueprint: kinetic-type-beats (Adapt — two calm statement beats, word-group fade-ups, no slam)
- asset_candidates: assets/scroll-010.png — reference for the moon-night world (not mounted)
- focal: the statement line
- roles: sky = background · statement = focal
- handoff_in: field + clock group — scale 1.035, opacity 1, empty field, clock "02:38"

Scene 1 (0.0–0.95s): field + clock blur out and fade. Scene 2 (0.35–2.2s): "The
questions you would not / ask anyone else." rises in two word groups (Chuk Sans 300,
88 px, centered). Scene 3 (2.2–4.8s, bar 31.0): the statement lifts and fades; "Who else
reads them?" (104 px) fades up in its place, held through the breath before the swell.

## Frame 4 — Sent

- status: animated
- src: compositions/frames/04-sent.html
- duration: 16.04s
- transition_in: crossfade 0.8s
- scene: On the swell the real Chuk Chat window rises close into the night; the burnout question is typed and, this time, sent; "Thought for 4s"; the answer streams; the chat turns into ciphertext — what the server stores; then "Encrypted on your device. We keep only ciphertext."
- poster: 9.8
- blueprint: prompt-type-submit-generate (Adapt — sub-shape B, full generate loop, then the site's vault state)
- asset_candidates: assets/scroll-005.png — the site's private world (reference for the rebuilt window, not mounted)
- focal: the app window (rebuilt from usecases.css / private.html)
- roles: sky = background · app window = focal · brand label + lock line = supporting
- sfx: key-press per keystroke + the Enter key on send (pre-mixed)

Phone rule (coordinator, 2026-09-27): every UI shot holds the window at scale 1.75, so
chat text, bubble, "Thought for 4s" and composer text are ≥ 28 px on screen. The full
window is never shown small in an empty sky; no headline over the UI.

Scene 1 (0.0–1.0s, swell hit 33.44): the window rises close (scale 1.75, framed on the
composer; y +150 → 0, blur 8 → 0, opacity 0 → 1). Under it, in the sky: logo + "Chuk Chat"
(Chuk Chat Mono 76 px) from 0.55 to 4.95. Scene 2 (0.7–5.25s): "How do I tell my boss that
I am burned out?" types with a steadier hand, done at 3.85, then a 1.4 s hesitation with
the caret blinking. Scene 3 (5.25s, hit 38.65): Enter — the send pill presses; the coral
bubble rises into the thread; the camera glides to the thread (window bottom meets the
frame bottom). Scene 4 (6.44–10.2s): "Thought for 4s ›" on the 39.84 hit; the answer
streams word by word — "Start with facts, not with blame." then three bullets; action
row; a held read to 11.65. Scene 5 (11.65s, hit 45.05): the whole chat scrambles left to
right into ciphertext; "What our server stores" badge drops in with "AES-256-GCM · the key
stays on your device". Scene 6 (12.9–13.35s): the window drops away and fades. Scene 7
(13.4s / 13.85s, after the window is gone): "Encrypted on your device." / "We keep only
ciphertext." (Chuk Sans 300, 92 px, gold lock icon) alone on the sky; clears at 15.68.

## Frame 5 — Never used

- status: animated
- src: compositions/frames/05-claim.html
- duration: 3.22s
- transition_in: crossfade 0.6s
- scene: "Never used for training." then "No tracking."
- poster: 2.0
- blueprint: kinetic-type-beats (Adapt — two lines, calm fade-ups)
- asset_candidates: assets/scroll-010.png — reference for the moon-night world (not mounted)
- focal: the claim lines
- roles: sky = background · lines = focal

Scene 1 (0.1–1.0s, hit 49.44): "Never used for training." fades up (Chuk Sans 300, 100 px).
Scene 2 (1.0–2.8s): "No tracking." joins below. Clears at 2.8 before the end card.

## Frame 6 — End card

- status: animated
- src: compositions/frames/06-endcard.html
- duration: 4.74s
- transition_in: crossfade 0.6s
- scene: Night sky; logo + "Chuk Chat" lockup, "Private and Secure. Always.", "chuk.chat" pill
- poster: 3.5
- blueprint: logo-assemble-lockup (Adapt — calm fade/scale assembly, no spring)
- asset_candidates: assets/logo-light.svg — the repo logo (assets/logo.svg) recoloured light, not redrawn
- focal: the logo lockup
- roles: sky = background · logo = focal · slogan + url = supporting

Scene 1 (0.1–1.0s, hit 52.66): logo mark (132 px) fades and settles; "Chuk Chat" (Chuk Chat
Mono 600, 118 px) slides in beside it from 0.3. Scene 2 (0.62s): "Private and Secure.
Always." (Chuk Sans 300, 64 px). Scene 3 (0.95s): "chuk.chat" in a gold pill (mono 44 px).
All in by 1.65; hold 3.1 s to the end while the piano decays.
