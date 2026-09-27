---
workflow: product-launch-video
flow: automation
storyboard: no
message: "No hype. Here is exactly what you get."
destination: youtube
aspect: 1920x1080
language: en
audience: people who want a private AI chat and are tired of AI hype
length: 35-40s
angle: anti-hype receipt, funny and dry
narration: no
music: supplied
style_preset: code-editorial
---

## Intent

Video 04 of the Chuk Chat launch series ("The receipt"). Approved concept
(`marketing/_shared/concepts/04-receipt.md`), about 40 s, message "No hype.
Here is exactly what you get." Angle: anti-hype, funny and dry.

1. Parody hook (0-4 s): a fake generic AI hype frame. Purple space glow, lens
   flare, huge text "THE MOST POWERFUL AI EVER". This is the only glow in the
   series, and it is a joke. No real brand.
2. Record stop (4-5 s): hard cut to warm paper and silence for a beat. Mono
   text: "Ours is shorter."
3. Receipt (5-33 s): a narrow thermal receipt prints line by line, on the beat,
   with a small printer tick. Monospace, dotted leaders:
   CHUK CHAT / THE SHORT VERSION; Your chats .... encrypted on your device;
   Training on your data .... 0; Tracking .... 0; Models .... open-weight only;
   Model switch .... every message; Connectors .... 50+; Open source .... 100%;
   Price .... €20 / month; incl. AI credits .... €16; From .... Germany; then a
   TOTAL line: "Private and Secure. Always." The camera follows the paper. Punch
   in on the funny "0" lines.
4. Tear (33-36 s): the receipt tears off. The barcode at the bottom reads
   "chuk.chat".
5. End card (36-40 s): logo + "Chuk Chat" + "Private and Secure. Always." +
   "chuk.chat", held at least 2.5 s.

Tone: deadpan comedy. The receipt is the hero: a real-looking thermal paper
strip (slight curl, paper texture, mono type, dotted leaders).

## Assets

- assets/bgm/track.wav — supplied music, copy of `marketing/_shared/music/04-receipt.wav` (marimba, pizzicato, ticking, deadpan stops, 110 BPM measured). The bed starts after the parody hook.
- capture/ — copy of `marketing/_shared/capture/` (chuk.chat capture; no new crawl).
- ../../../assets/logo.svg — Chuk Chat logo (repository root `assets/logo.svg`), copied into `assets/`.
- /home/user/git/chuk.chat/static/fonts/jetbrains-mono-latin-wght.woff2 — "Chuk Chat Mono", embedded.

## Customizations

- No voice, no TTS, no SCRIPT.md, no captions. Story is told by on-screen text, motion and music.
- Music starts AFTER the hook: the hype frame gets a generic "epic" whoosh/impact (bundled media-use SFX), then a record-stop (tape stop), then silence, then the track starts with the receipt.
- Each receipt line prints on a beat of the `npx hyperframes beats` grid. The track's own deadpan stops land on the "0" punch-ins.
- Small printer ticks and one paper rip, quiet under the music.

## Notes

- Series rules: `marketing/_shared/SERIES.md` wins over any skill default.
- Allowed claims only (SERIES.md). No competitor names. No "most secure",
  "military-grade", "100% anonymous", VAT, user counts, ratings.
- The hype frame is an unbranded parody. "THE MOST POWERFUL AI EVER" is the joke, not a claim about Chuk Chat.
- Render only through `flock marketing/_shared/.render.lock`. Deliver to `marketing/out/04-receipt.mp4`. No git commit.
- Canvas 1920x1080, 30 fps, YouTube.

## Decisions (autonomous run, recorded)

- Preset `code-editorial`. `build-frame.mjs` inverted the palette (read the brand as dark mode); `frame.md` was fixed by hand to the SERIES.md values and all type roles set to the embedded "Chuk Chat Mono".
- HeyGen not signed in, so no catalog SFX. Hype audio uses the bundled media-use SFX (Pixabay licence: whoosh-cinematic, impact-bass-1/2, riser, sparkle, key-press). The record stop is a tape stop computed from that mix. Printer buzz, dot ticks, stamps and the paper rip are synthesised locally and deterministically in `_work/make_audio.py`. No music generation, no TTS.
- Music: `assets/bgm/bed.wav` is built from the supplied track only. Silence until 5.33 s, track 7.10-12.859 s (bar 1 downbeat lands on the first receipt row at 5.40 s), then track 28.092-52.349 s joined inside the track's own stop. That puts the track's ticking stop under the first "0" punch-in, its short stop under the second "0", and its final stab on the end card. The track ends naturally (0.3 s safety fade), so the cut is 35.307 s instead of the concept's ~40 s. Bed volume 0.9.
- The receipt is printed by a small dark printer at the bottom of the frame and feeds UP out of the slot, one row per beat. This keeps the reading order right (header first, at the top). "The camera follows the paper" is done as a camera that tracks the newest printed row, smash-cuts in on the zeros and pulls back to the whole receipt after the tear.
- The gag zeros are printed double size (real receipt printers do this for totals) so the "0" dominates each close-up.
- Added one row that is not a product claim: "Lens flares .... 0", a callback to the parody hook. Easy to remove in `_work/build_receipt.py` if unwanted.
- Hype sub-line "REVOLUTIONARY. LIMITLESS. BEYOND." is parody copy for the fake trailer, not a claim.
- The barcode is a real Code 128B encoding of "chuk.chat" (verified by decoding with pyzbar).
- Frames were built directly by the orchestrator (no worker dispatch), because the receipt needs one continuous camera and exact beat timing. `_work/build_receipt.py` generates `compositions/frames/03-receipt.html` and `_work/receipt_times.json` from one plan, so picture and printer SFX stay in sync.
- Preferences were recorded into the project tier with `HYPERFRAMES_MEDIA_HOME=_work/media-home`, so nothing was written outside the project directory.
- Round 2 (coordinator review, phone readability): default receipt framing is now close (camera scale 1.70-1.78, receipt ~72% of frame width, row text ~61 px) and tracks the newest row with a 1-2.6° handheld tilt. The whole receipt is shown only while the header prints (~1 s) and in the pull-back after the tear (~1 s). TOTAL slogan is now the biggest type on the receipt (62 px) with a punch-in on the bar 18 downbeat (~130 px). Barcode + "chuk.chat" held close (~68-72 px). Frame 02 line is 128 px; end card "Chuk Chat" 168 px, slogan 56 px, URL 52 px. Paper texture moved into the paper background (no overlay layer).
