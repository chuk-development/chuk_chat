---
format: 1920x1080
duration: 35s
message: "No hype. Here is exactly what you get."
arc: Parody hook → Record stop → The receipt → Tear → End card
audience: people who want a private AI chat and are tired of AI hype
mode: autonomous
music: supplied
fps: 30
---

## Video direction

- **Palette** (from `frame.md`, fixed by SERIES.md): warm paper canvas `#FDFBF7`,
  tiles `#F3F0E8` / `#ECE8DE`, lines `#E6E1D5`, ink `#26251F` / soft `#5F5D55` /
  faint `#8C8A80`. The printer body uses the dark app surface `#262624`. Coral
  `#D97757` appears once per frame at most (printer status light, caret). The
  receipt paper is a cool-warm thermal white `#FFFEFA` on a warm table.
- **Frame 01 is the only exception**: a generic, unbranded "AI hype" look (deep
  purple space, glow, lens flare, chrome gradient type, Montserrat Black). It is a
  parody and must look overblown. It never returns after the record stop.
- **Type**: everything after frame 01 is "Chuk Chat Mono" (embedded JetBrains
  Mono). Receipt rows are mono with dotted leaders, labels 500, values 700.
- **Motion grammar**: mechanical and deadpan. The receipt paper feeds out of the
  printer in short stepper jerks, one row per beat. The camera is calm, then
  cuts in hard (smash punch-in) on each funny "0", holds still in the silence,
  and snaps back out on the next music hit. No floating, no breathing, no
  easing flourishes. Long-tail `power3` only for the two big camera moves (the
  start and the pull-back after the tear).
- **Reveal model**: silent film on a beat grid. Every receipt row reveals on a
  beat of the supplied track (110 BPM, `beats/assets/bgm/track.wav.json`). Big
  reveals land on downbeats. The track's own deadpan stops are placed under the
  "0" punch-ins.
- **Held beats**: frame 02 ("Ours is shorter.") is a deliberate held beat in
  silence. The two "0" close-ups are held, still reads in silence. The end card
  holds still.
- **Negative list**: no glow, no coloured box-shadow, no gradients on content
  after frame 01; no competitor names; no claims outside SERIES.md; no slideshow
  front-loading, no screensaver drift.
- **Audio**: frame 01 has a bundled "epic" impact + whoosh + riser, then a tape
  stop (record stop). Silence in frame 02 except quiet key clicks. The supplied
  track starts on the first receipt row (bar 1 at 5.40 s). One musical edit
  inside the track's own silence joins bar 3 of the opening groove to the ticking
  stop section. Printer buzz per row, a paper rip on the tear, all quiet under
  the bed.

## Frame 1 — Hype parody

- scene: Fake generic AI trailer: purple space, lens flare, "THE MOST POWERFUL AI EVER", then it grinds to a halt
- voiceover: ""
- duration: 3.8s
- transition_in: cut
- status: animated
- src: compositions/frames/01-hype.html
- type: hook
- persuasion: Negative contrast (parody of generic AI hype, no real brand)
- beat: amusement + skepticism
- blueprint: compose
- asset_candidates:
- focal: headline "THE MOST POWERFUL AI EVER"
- roles: starfield + nebula = background · headline = hero · lens flare = supporting
- sfx: whoosh-cinematic, impact-bass-2, riser (tail), sparkle, then tape stop

narrativeRole: grab attention with the most generic AI hype possible, so the turn lands.
keyMessage: everyone else shouts.

Scene 1 (0.0–0.2s): frame 0 is already moving: purple flash decays, starfield warps outward, kicker "INTRODUCING" tracks open. Centered.
Scene 2 (0.15–1.2s): headline slams in two lines on the impact, chrome-lavender gradient type with a purple glow, ~60% of frame width. Centered hero.
Scene 3 (1.2–3.4s): anamorphic lens flare sweeps across the headline; sub-line "Revolutionary. Limitless. Beyond." fades in under it; slow push-in underneath.
Scene 4 (3.4–3.8s): record stop. Everything decelerates, sags and desaturates while the audio tape-stops. Hard cut out.

## Frame 2 — Ours is shorter

- scene: Warm paper, silence. Mono text types "Ours is shorter." and holds, deadpan
- voiceover: ""
- duration: 1.6s
- transition_in: cut
- status: animated
- src: compositions/frames/02-shorter.html
- type: problem
- persuasion: Pattern interrupt (hard cut from noise to calm)
- beat: surprise → curiosity
- blueprint: compose
- asset_candidates:
- focal: line "Ours is shorter."
- roles: paper canvas = background · line = hero
- sfx: quiet key clicks

narrativeRole: the turn. Deadpan pause after the noise.
keyMessage: we do not do hype.

Scene 1 (0.0–0.15s): empty warm paper, caret visible, silence. Centered.
Scene 2 (0.15–0.6s): "Ours is shorter." types in, mono, large.
Scene 3 (0.6–1.6s): held still read. Caret blinks. Silence.

## Frame 3 — The receipt

- scene: A thermal receipt prints out of a small dark printer, one row per beat; smash punch-ins on the "0" rows; TOTAL, barcode, tear, whole receipt
- voiceover: ""
- duration: 26.182s
- transition_in: cut
- status: animated
- src: compositions/frames/03-receipt.html
- type: key_feature
- persuasion: Value stacking as a plain itemised list; deadpan rule of three on the zeros
- beat: amusement + clarity → trust
- blueprint: compose
- asset_candidates: assets/logo-ink.svg — Chuk Chat logo mark, printed at the receipt head
- focal: the receipt paper strip
- roles: warm table = background · printer = supporting · receipt = hero · "0" values = punch-in targets
- sfx: printer buzz per row, dot ticks, "0" stamps, paper rip on the tear

narrativeRole: the whole product, itemised, with no hype. The receipt IS the pitch.
keyMessage: this is exactly what you get.

Rows (all copy from SERIES allowed claims): header logo, CHUK CHAT, THE SHORT VERSION;
Your chats .... encrypted / on your device; Training on your data .... 0;
Tracking .... 0; Models .... open-weight only; Model switch .... every message;
Connectors .... 50+; Open source .... 100%; Price .... €20 / month;
incl. AI credits .... €16; From .... Germany; Lens flares .... 0 (callback joke,
not a product claim); TOTAL / Private and Secure. / Always.; Code 128 barcode that
encodes and reads "chuk.chat".

Scene 1 (0.0–4.36s, bars 1–2): camera close on the printer slot. On the downbeat the head of the receipt feeds out: logo, CHUK CHAT, THE SHORT VERSION, a dashed rule; bar 2 "Your chats … encrypted / on your device". Camera eases back a little as the strip grows. Centered, paper ~55% of width.
Scene 2 (4.36–8.16s, bar 3 + stop): "Training on your data" feeds out, the leader dots tick in, the "0" stamps on the stab, the music stops dead. Smash punch-in on the "0". Held still in the ticking silence. Snap out on the next hit.
Scene 3 (8.73–12.52s, bars 12–13): "Tracking" feeds out, dots tick slowly, the camera already creeps in (it knows). "0" stamps on the hit, smash punch-in, short silence, snap out.
Scene 4 (13.09–21.82s, bars 14–17): two rows per bar, steady: Models, Model switch, Connectors, Open source, Price, incl. AI credits, From, Lens flares (quick punch-in on its "0"). Camera wide enough to read ~10 rows.
Scene 5 (21.82–24.0s, bar 18): TOTAL, then "Private and Secure." and "Always." in double size, rule, barcode, "chuk.chat".
Scene 6 (24.0–26.18s, bar 19): the receipt tears off with a rip, lifts free; the printer drops away; camera pulls back to the whole short receipt, slight tilt, held.

## Frame 4 — End card

- scene: Logo, "Chuk Chat", "Private and Secure. Always.", "chuk.chat" on warm paper, held
- voiceover: ""
- duration: 3.725s
- transition_in: cut
- status: animated
- src: compositions/frames/04-endcard.html
- type: brand_outro
- persuasion: Brand recall
- beat: calm confidence
- blueprint: compose
- asset_candidates: assets/logo-ink.svg — Chuk Chat logo mark
- focal: logo + wordmark lockup
- roles: paper canvas = background · lockup = hero · URL = supporting
- sfx: none (the track's final stab lands at 2.68s)

narrativeRole: sign-off.
keyMessage: Chuk Chat. Private and Secure. Always. chuk.chat

Scene 1 (0.0–0.55s): on the bar 20 downbeat the logo and "Chuk Chat" print in with a thermal raster wipe (callback to the receipt). Centered.
Scene 2 (0.55–1.1s): slogan "Private and Secure. Always." prints under it.
Scene 3 (1.1–3.725s): "chuk.chat" appears; the full card holds still (2.6 s); the logo gives one small bump on the final stab.
