# Reels "Ask Chuk Chat to …" — micro-reel template + first batch of 6

- Format: 1080x1920 (9:16), 30 fps, 10–14 s each. Instagram Reels / Shorts.
- Reference: Meta "Ask Muse to sort your Instagram saves",
  `_scratch/reel_ref/DdwMu5VhCUn.mp4` (sheet `sheetB.jpg`). Copy the format,
  never its assets.
- This is the high-volume format: one reel = one use case. Build it as ONE
  template driven by a data file per reel, so a new reel is a new JSON entry
  plus one render command.
- Music: a short bed from `marketing/_shared/music/01-introducing.wav`. Render
  every reel twice: with the bed, and with no music (owner adds IG audio).

## Shape of every reel (from the reference)

1. 0–2 s: big bold title card, centred: "Ask Chuk Chat to <task>" (≥ 96 px,
   the task words in coral). Dark ground #26251F, cream text — a thumb-stop.
2. 2–3 s: an Android phone (the real app look: dark UI, coral user bubble,
   see `fastlane/metadata/android/en-US/images/phoneScreenshots/*.png`) slides
   up and fills most of the frame.
3. 3–5 s: the user bubble appears, then typing dots.
4. 5–9 s: the answer streams in and a result card appears in the chat.
5. 9–12 s: swipe / zoom into the result full screen (like the reference's
   swipe into the collection grid). Hold it.
6. Last 0.8 s: small "chuk.chat" tag at the bottom. No big end card.

Phone UI text ≥ 34 px on the canvas. Safe margins 120 px top and bottom.

## Batch 1 (each prompt unique)

1. invoice — "Ask Chuk Chat to turn your notes into an invoice" → prompt
   "Invoice for the Berger bathroom: 9 hours at €62, tiles €310. PDF please." →
   Typst PDF card → full-screen PDF (Total €868.00).
2. week — "Ask Chuk Chat to plan your week" → "What is due this week? Check
   Linear, Todoist and Notion." → tool rows with logos → full-screen plan.
3. pharmacy — "Ask Chuk Chat to find a pharmacy open now" → Android assistant
   overlay → map with 3 pins → "Navigation started".
4. chart — "Ask Chuk Chat to chart any number" → "Chart Bitcoin for the last
   30 days." → line chart draws → full-screen chart.
5. page — "Ask Chuk Chat to build your café a website" → "Make a menu page
   for my café and publish it." → artifact → full-screen page with the public
   link.
6. lease — "Ask Chuk Chat to explain your lease" → PDF chip "lease.pdf" +
   "What are the 3 things I must know?" → 3 points with page refs → full-screen
   PDF page with the lines highlighted.
