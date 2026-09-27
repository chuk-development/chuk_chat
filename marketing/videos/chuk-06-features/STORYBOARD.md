---
format: 1920x1080
duration: 64s
message: "One app. All of this."
arc: Hook wall -> 13 feature results (same grammar) -> price -> end card
audience: people who use AI chat every day and want one app for all of it
mode: autonomous
music: supplied
captions: skipped (no narration)
---

# Chuk Chat 06 — What it does — storyboard

Frames are HyperFrames sub-compositions in `compositions/frames/`, generated
by `python3 tools/build.py` (kit: `tools/kit.py`, frames: `tools/frames_a.py`,
`frames_b.py`, `frames_c.py`). Times are video seconds on the 120 BPM grid of
`assets/bgm/track_edit.wav` (downbeats at every even second).

## Video direction

- **Grammar (every feature beat, 4.0 s = 2 bars)** — left column at x 100:
  mono counter "NN / 13" (32 px), feature name in Inter 112 px (one or two
  lines), a short coral rule, one plain line in Inter 46 px. Right two thirds:
  the result card, the app's own dark surface (`#262624`) at `zoom: 1.9`,
  684-900 px tall, soft shadow, no glow, lifted onto one of the website's
  worlds.
- **Worlds** (usecases.css): library, prism, network, dawn, paper, night,
  day (café awning), prism, network, library, dawn, street, prism; paper for
  hook, price and end card. Never the same world twice in a row.
- **Motion** — hard cut on every downbeat. Entrance: counter slides in, name
  words rise (power3.out), the card lifts from +120 px (0.5 s), then a slow
  1.025 push for the whole beat. Results build on beats and 8th/16th notes:
  lines draw, markers drop, values count up, tiles slot in, text streams by
  word. Nothing types. The last ~1 s of every beat holds the finished result.
- **Readability** — feature name 112 px, one-liner 46 px, card UI text
  >= 15 logical px x 1.9 = >= 28.5 px, chips >= 30 px, end card name 124 px,
  slogan 80 px, URL 44 px.
- **Negative list** — no typing, no logo assembly, no "Introducing" card, no
  burned-out prompt, no Mrs Weber, no Spoke page, no competitor names or
  logos (no OpenAI logo), no neon, no glow, no invented product numbers.

## Frame 0 — Hook: one app, all of this

- scene: wall of 9 result cards (chart, map, weather, email, generated image, café page, model logos, lease PDF, connectors) tiles in on 16ths while the camera pulls back from the image; headline band 'One app. All of this.' lands in the break (V2)
- duration: 4s
- start: 0s
- src: compositions/frames/f00-hook.html
- poster: 3.5
- transition_in: cut
- status: animated
- world: paper
- asset_candidates: assets/img/generated-workshop.jpg, assets/logos/models/*.svg, assets/logos/connectors/*.png
- blueprint: compose

Scene 1 (0.0-2.0s): frame 0 is close on the generated image with map and PDF tiles around it; the other six tiles pop in on 16th notes (0.125-0.75); the chart line draws, the route draws; camera pulls back 1.55x -> 0.8x.
Scene 2 (2.0-4.0s): break in the music; headline 'One app.' (2.0) 'All of this.' (2.5) rises in its own band under the wall; hold.

## Frame 1 — Research the web

- scene: bubble 'Best plants for a dark flat?'; 'Searched low light houseplants'; numbered source chips (favicon + domain) pop; answer lists 3 plants with citation chips; '8 sources' pill
- duration: 4s
- start: 4s
- src: compositions/frames/f01-research.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: library
- asset_candidates: rebuilt UI (chuk.chat uc partials + usecases.css), assets/fonts/*
- blueprint: compose

Scene 1 (0-0.5s): DROP 1. Hard cut; counter, name, line and the card lift in.
Scene 2 (0.45-1.2s): search row, source chips pop on 16ths.
Scene 3 (1.3-3.1s): answer lines stream on beats, citation chips pop; '8 sources' pill.
Scene 4 (3.1-4.0s): hold.

## Frame 2 — Live charts

- scene: bubble 'Chart Bitcoin for the last 30 days'; the 30-day line chart draws left to right, the value counts up to $81.2K, +6.3% chip
- duration: 4s
- start: 8s
- src: compositions/frames/f02-charts.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: prism
- asset_candidates: assets/screenshots/screenshot_bitcoin_chart.webp (look reference, read in place)
- blueprint: compose

Scene 1 (0-0.6s): cut, card lifts, lead line streams.
Scene 2 (0.6-2.5s): the line and its area are revealed by one clip rect; the value counts up.
Scene 3 (2.5-4.0s): end dot and change chip pop; hold.

## Frame 3 — Maps and routes

- scene: bubble 'Kiel harbour to the old town, on foot'; map; green origin ring 'Ostseekai' pops, red pin 'Alter Markt' drops, the blue route draws, summary '1.1 km · 14 min'
- duration: 4s
- start: 12s
- src: compositions/frames/f03-maps.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: network
- asset_candidates: rebuilt UI (chuk.chat uc partials + usecases.css), assets/fonts/*
- blueprint: compose

Scene 1 (0-0.6s): cut, map fades in.
Scene 2 (0.6-1.2s): markers drop.
Scene 3 (1.3-2.6s): route polyline draws (app colours: blue shade 400).
Scene 4 (2.7-4.0s): summary row; hold.

## Frame 4 — Weather

- scene: bubble 'Weather in Hamburg this weekend?'; weather card: 17°C counts up, stats, hourly strip pops on 8ths, Sat/Sun rows
- duration: 4s
- start: 16s
- src: compositions/frames/f04-weather.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: dawn
- asset_candidates: assets/screenshots/screenshot_weather_ui.webp (look reference, read in place)
- blueprint: compose

Scene 1 (0-1.1s): cut; card rises, temperature counts 0 -> 17.
Scene 2 (1.0-2.5s): stats and 8 hourly slots pop on 8ths.
Scene 3 (2.0-4.0s): break in the music; daily rows rise; hold.

## Frame 5 — Create images

- scene: bubble 'A sunlit bike workshop, film photo'; the AI-generated image resolves from noise (grain fades, blur clears); file row workshop.png with Edit / Save
- duration: 4s
- start: 20s
- src: compositions/frames/f05-images.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: paper
- asset_candidates: assets/img/generated-workshop.jpg (from marketing/_shared/images/generated-workshop.png, AI-generated), assets/img/noise.png
- blueprint: compose

Scene 1 (0-0.3s): cut; noise field.
Scene 2 (0.3-2.6s): image resolves: blur 26 -> 0, saturation up, grain out.
Scene 3 (2.6-4.0s): file row; hold.

## Frame 6 — Read your files

- scene: bubble with lease.pdf chip 'What are the key points?'; 'Read lease.pdf · 12 pages'; page stack; 3 points stream with page chips p. 2 / 4 / 6 while the matching line on the page lights up
- duration: 4s
- start: 24s
- src: compositions/frames/f06-files.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: night
- asset_candidates: rebuilt UI (chuk.chat uc partials + usecases.css), assets/fonts/*
- blueprint: compose

Scene 1 (0-1.0s): cut; read row, page stack.
Scene 2 (1.0-3.0s): intro + three points on beats 1.35 / 1.95 / 2.55, highlight and page badge follow.
Scene 3 (3.0-4.0s): hold.

## Frame 7 — Documents and pages

- scene: bubble 'Make a menu page for our café'; artifact panel builds the Café Anker menu page; public link artifacts.chuk.chat/m4q9-cafe-anker; Preview flips to Code
- duration: 4s
- start: 28s
- src: compositions/frames/f07-documents.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: day
- asset_candidates: rebuilt UI (chuk.chat uc partials + usecases.css), assets/fonts/*
- blueprint: compose

Scene 1 (0-1.9s): cut; page builds part by part on 8ths.
Scene 2 (2.0-2.7s): public link row and 'Public' tag.
Scene 3 (2.75-4.0s): Preview -> Code flip, HTML lines fade in; hold.

## Frame 8 — Email and calendar

- scene: bubble 'Invite Tom to Friday's planning call'; email card with 'Open in Mail App'; 'Ran create calendar event'; event card 'Planning call · Fri 10:00 – 10:30' lands with 'Added'
- duration: 4s
- start: 32s
- src: compositions/frames/f08-email.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: prism
- asset_candidates: assets/sfx/pop.mp3
- blueprint: compose

Scene 1 (0-1.6s): email card builds, body streams, button pops.
Scene 2 (2.0-2.5s): break; tool row.
Scene 3 (2.5-4.0s): calendar card lands (pop), 'Added'; hold.

## Frame 9 — Your tools

- scene: DROP 2. bubble 'What's due this week? Check Notion.'; 11 connector logos + '+50' slot in on 16ths; 'Ran notion search'; three due items stream
- duration: 4s
- start: 36s
- src: compositions/frames/f09-tools.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: network
- asset_candidates: assets/logos/connectors/{notion,linear,github,todoist,dropbox,figma,stripe,asana,airtable,calcom,vercel}.png
- blueprint: compose

Scene 1 (0-1.6s): drop; tiles slot in on 16th notes.
Scene 2 (1.75-3.3s): tool row, answer lines on beats.
Scene 3 (3.3-4.0s): hold.

## Frame 10 — Your own assistants

- scene: workspace 'Tax helper': instructions, 3 files slot in; chat inside it: 'Can I deduct my home office?' -> answer with citation chip tax-return-2024.pdf · p. 3
- duration: 4s
- start: 40s
- src: compositions/frames/f10-workspaces.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: library
- asset_candidates: rebuilt UI (chuk.chat uc partials + usecases.css), assets/fonts/*
- blueprint: compose

Scene 1 (0-1.0s): cut; instructions, files slot in.
Scene 2 (1.0-2.8s): chat section, answer streams.
Scene 3 (2.8-4.0s): citation chip; hold.

## Frame 11 — Pick the model

- scene: model menu with the open-weight logos; a pointer picks Kimi K3, Qwen3.8 27B, Mistral Small 4 on the downbeats; the tick and the composer pill follow
- duration: 4s
- start: 44s
- src: compositions/frames/f11-models.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: dawn
- asset_candidates: assets/logos/models/{deepseek,moonshot,zai,qwen,minimax,mistral}.svg, assets/sfx/click-soft.mp3
- blueprint: compose

Scene 1 (0-1.0s): cut; menu open on DeepSeek V4 Pro 0813.
Scene 2 (1.0-3.0s): clicks on 1.0 / 2.0 / 3.0; tick and pill label change.
Scene 3 (3.0-4.0s): hold on Mistral Small 4.

## Frame 12 — Android assistant

- scene: phone with the assistant overlay: 'Listening' with the heard request 'Text Anna that I'm ten minutes late.'; 'Working …' with Contact / SMS tool rows; 'Message sent' action card + answer
- duration: 4s
- start: 48s
- src: compositions/frames/f12-android.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: street
- asset_candidates: 01 frame 08-onthego look (PHONE_CSS), new content
- blueprint: compose

Scene 1 (0-1.0s): listening, waveform moves.
Scene 2 (1.0-2.0s): working, tool rows.
Scene 3 (2.0-4.0s): break; action card lands, answer streams; hold.

## Frame 13 — Everywhere

- scene: the same chat 'Plan Saturday' on a desktop window and a phone; 'Synced' tick; platform chips Mac, Windows, Linux, Android, Web; lock pill 'Synced and end-to-end encrypted'
- duration: 4s
- start: 52s
- src: compositions/frames/f13-everywhere.html
- poster: 3.8
- transition_in: cut
- status: animated
- world: prism
- asset_candidates: rebuilt UI (chuk.chat uc partials + usecases.css), assets/fonts/*
- blueprint: compose

Scene 1 (0-1.6s): desktop answer lines, then the phone shows the same lines; 'Synced'.
Scene 2 (2.0-2.5s): platform chips pop on 16ths.
Scene 3 (2.75-4.0s): lock pill; hold.

## Frame 14 — Price and end card

- scene: '€20 / month' + '€16 AI credits included' (V56-58); then logo + 'Chuk Chat', 'Private and Secure. Always.', 'chuk.chat' land on V58 and hold 6 s
- duration: 8s
- start: 56s
- src: compositions/frames/f14-end.html
- poster: 6.0
- transition_in: cut
- status: animated
- world: paper
- asset_candidates: assets/logos/chuk-chat-logo.svg (inlined)
- blueprint: compose

Scene 1 (0-1.8s): price line.
Scene 2 (2.0-8.0s): end card lockup (2.0), slogan (2.5), URL pill (3.0); static hold while the music fades out.
