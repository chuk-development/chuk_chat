---
workflow: general-video (template)
flow: automation
storyboard: no
message: "Ask Chuk Chat to <task>" — one use case per reel
destination: instagram reels / shorts
aspect: 1080x1920
fps: 30
language: en
length: 12s per reel
narration: no
music: supplied (bed muxed on; a second file ships without music)
---

# Reels "Ask Chuk Chat to …" — template + batch 1

Concept (wins on content): `marketing/_shared/concepts/reel-ask-series.md`.
Format copied from Meta's "Ask Muse to sort your Instagram saves"
(`_scratch/reel_ref/DdwMu5VhCUn.mp4`); none of its assets are used.

## How to add a reel

1. Copy the closest file in `reels/` to `reels/<slug>.json`. Change title, prompt, answer and `card` data.
2. Title: `|` breaks a line, `[words]` turn coral. The build warns if a line needs a font under 96 px.
3. `card.type` is one of `document`, `plan`, `chart`, `webpage`, `highlights`, `places` (see below). A new kind of result = one new class in `tools/cards.py`.
4. Check it: `tools/snap.sh <slug>` (frames in `_work/snap/<slug>/`) and `python3 tools/build.py <slug> && npx hyperframes check`.
5. Render: `./render.sh <slug>` → `marketing/out/reels/ask-<slug>.mp4` and `ask-<slug>_nomusic.mp4`.

## Files

| Path | What |
|------|------|
| `reels/<slug>.json` | one data file per reel |
| `tools/build.py` | JSON → `compositions/ask-<slug>.html` (standalone) and `index.html` (copy of the last build, for check/snapshot/preview). Holds the default timing. |
| `tools/kit.py` | canvas, title card, phone frame, status bar, top bar, composer, JS runtime |
| `tools/surfaces.py` | `chat` (the app) and `assistant` (Android assistant overlay) |
| `tools/cards.py` | result card types: in-chat card + full-screen result + animation |
| `render.sh` | build → render through `marketing/_shared/.render.lock` → mux the music bed |
| `tools/make_bed.sh` | cuts the bed for a given length |
| `tools/snap.sh`, `tools/frames.sh` | review frames: snapshots of the composition / full-resolution frames of the MP4 |

## Data file

Required: `slug`, `title`, `prompt`, `answer` (`**bold**` allowed), `card` (`type` + data).
Optional: `surface` (`chat` default, or `assistant` + an `assistant` block), `clock`,
`chat_title`, `attachment` (`{name, meta}` = file message above the prompt),
`steps` (`{logo|icon, text, detail}`; logo = file in `assets/logos/connectors/`),
`fold_steps` (default true, like the app), `worked`, `timing` (overrides, see `DEFAULTS`
in `tools/build.py`, e.g. `{"duration": 13.2, "swipe": 10.2}`).

Card data per type: see the batch files — `invoice.json` (document), `week.json` (plan),
`chart.json` (chart), `page.json` (webpage), `lease.json` (highlights), `pharmacy.json` (places).

## Shape (all reels, beat-aligned to the bed, 100 BPM)

0–2.0 s title card (logo mark + "Ask Chuk Chat to" + coral task, Inter 760, 110 px) ·
2.05–2.45 s phone slides up, lands on bar 2 · 2.75 s prompt bubble · 3.1 s dots (tool
rows from 3.4 s) · 4.85 s answer streams, rows grow line by line · 6.05 s result card ·
8.73 s tap on "Open" · 9.05 s swipe (0.45 s, horizontal motion blur) into the full-screen
result · hold · 11.2 s "chuk.chat" tag · 12.0 s end.
The assistant surface: 2.75 overlay + "Listening" · 4.05 "Working …" + tools ·
4.85 places card with map · 7.25 "Navigation started" + answer · 9.05 swipe to the map.

## Decisions (autonomous run, recorded)

- One standalone composition per reel (no sub-compositions): each font is inlined once.
  Fonts are woff2 subsets (Latin-1 + € – “ ” … →): JetBrains Mono (chat font of the app),
  Arimo (app UI font), Inter (title), Merriweather (lease page). Total ~190 KB.
- Phone: screen 800 x 1600 px = 411 x 822 dp at zoom 1.946 (a Pixel 7 Pro is 412 x 892 dp;
  the screen is 70 dp shorter so the phone fits the 120 px safe margins at this text size).
  Smallest UI text 17.5 dp = 34 px on the canvas. Phone 122–1746 px, tag 1756–1798 px.
- Chat look sampled from the store screenshots: bubble #B6674D / edge #C48B77 / text #E8E4D8,
  mono chat text, "Worked for Xs >", composer edge #565551, coral caret and send button.
  Real app colours kept even where the contrast audit wants 4.5:1 (white on coral 3.1:1,
  bubble text 3.3:1); on the canvas this text is 34–35 px bold/large, so 3:1 applies.
- Rows grow from 0 to their measured height, so the bottom-anchored thread pushes up like
  the app; the answer grows line by line while it streams. Heights are measured after
  `document.fonts` is ready, before the timeline is built.
- No typing into the composer: the bubble appears (lesson 2026-09-27: typing is not the story).
- Swipe = the reference's swipe (new screen from the right, horizontal motion blur via an
  SVG filter), plus a tap on the card's "Open" button just before it.
- Music: the bed starts on the drop (38.43 s of the track), so frame 0 already has the beat.
  Picture rendered once; `ask-<slug>.mp4` = same video stream + bed (AAC 192k);
  `ask-<slug>_nomusic.mp4` has no audio stream.
- Content from the website mocks where one exists (allowed claims): invoice (business),
  week (connectors), page with the `artifacts.chuk.chat/…` public link (founders),
  pharmacy prompt, tools, places and answer (on the go). Invoice total €868.00 = 9 × €62 + €310,
  no VAT line (forbidden claim). Bitcoin numbers are an example series (+6.3 %).
- No competitor names or logos. Connector logos (Linear, Todoist, Notion) come from
  chuk.chat/static/logos/connectors.
- `hyperframes check` passes for all six (lint 0 errors, layout 0, contrast 0). Remaining lint
  warnings are expected: one monolithic root (`nested_structure_needs_subcomposition`) and the
  same connector logo used several times in `week` (`duplicate_media_discovery_risk`).
