# Chalk: a shared visual channel between user and AI

Status: working prototype in `tools/chalk/`, tested with GLM 5.3 Flash and
DeepSeek V4.1 Flash.
It is not in the app yet. Date: 2026-10-30.

## Goal

The user asks, draws or marks something. The AI draws an answer, sees it, and
corrects it. GLM 5.3 Flash must do this with no training. No 3D assets, no
second generator, no GPU, no Excalidraw format.

## Idea

The model does not draw pixels and does not place things. It writes short
lines. Each line names a part. The engine does the rest:

- **2D:** flex layout (`row`, `col`, `card`), wrapped rows, arrows by id, label
  space between neighbours, hand-drawn lines.
- **Sketch:** free strokes (`curve`, `shape`, `poly`) with local coordinates.
- **3D:** parts from a closed catalogue (`loft`, `limb`, `lathe`, `extrude`,
  `fan`, `gear`, `port` and more), with `repeat`, `ring`, `mirror`. One line
  gives a rotor with 22 blades. Nothing is loaded, every model is text.
- **Render:** a CPU z-buffer with cel shading, edge lines from the id, depth and
  normal buffers, a soft shadow, cutaways and exploded views. Labels sit in two
  columns with leader lines. This is the look of the reference video, and it
  costs a few hundred lines. A render takes about 0.3 s on one CPU core.

## Files

| File | Purpose |
|---|---|
| `parse.mjs` | Line parser, edit commands. Bad lines never stop a render |
| `geom.mjs` | 3D catalogue, shape to triangles |
| `raster.mjs` | Software renderer, part statistics, floating part check |
| `scene.mjs` | Layout, SVG output, text feedback, `describeStroke` |
| `PROMPT.md` | System prompt with blueprints and 8 worked examples, about 23 000 characters. `PROMPT_PLUS.md` adds master examples |
| `eval.py` | Draw, feedback, fix loop over the task list |
| `loop.mjs`, `mark.mjs`, `stroke.py`, `shot.py` | Loop step, user mark test, SVG to PNG |
| `kits.mjs`, `anim.mjs`, `video.mjs` | Macro kits, timeline, film export |
| `bench.py`, `pair.py`, `refs.py`, `configs.json` | Benchmark, head-to-head, photos and facts, pipelines |
| `library/` | Vetted models, today the Raspberry Pi 5 |
| `versions/` | Result of each iteration, pictures and films |
| `chalk.test.mjs` | Tests: `node --test` in `tools/chalk` |

Run one request:

```bash
python3 tools/chalk/eval.py _scratch/out --effort high --ask "Zeig einen Panzer in 3D"
```

The key file is `_scratch/rtgfx/.melious_key` (gitignored). Melious API:
`https://api.melious.ai/v1`, model id `glm-5.3-flash`. Slugs like
`z-ai/glm-5.3-flash` give a 404 there.

## Feedback loop

Each draw returns element ids, parts with visible pixels, ERRORS and LINTS
(unknown keys, floating parts, hidden parts, overflow, arrows through elements)
and the image. The model answers with edits (`set`, `del`, `replace`, `add`) or
`DONE`. An edit round that adds issues is rejected, so a fix cannot damage the
picture. Rejecting is required: without it two sketches came out empty.

User marks become text in the model's own ids plus the image, for example:
`user circled pouch, beak at 572,159,682,231`. A 3D part counts only if the
mark holds at least 35 % of its visible pixels.

## Results, 24 objects, 2026-10-30

`hit` is blind recognition: a judge sees the picture with no title and no labels
and names the object. Time is the median per request. All runs use the Melious
plan, so the included models are GLM 5.3, GLM 5.3 Flash and the DeepSeek Flash
models. Kimi and Qwen answer 429 with this plan.

| Pipeline | Hit | Score | Time | Output tokens |
|---|---|---|---|---|
| GLM Flash, low, 3 drafts | 88 % | 3.8 | 6 s | 1 575 |
| GLM Flash, high, 1 draft | 83 % | 3.9 | 9 s | 1 638 |
| GLM Flash, high, photos, 1 draft | 100 % | 4.0 | 13 s | 2 819 |
| GLM Flash, high, 3 drafts, critic round | 96 % | 4.1 | 24 s | 8 731 |
| GLM Flash, high, build sheet, 3 drafts, critic | 100 % | 4.0 | 38 s | 9 736 |
| GLM Flash, high, photos, sheet, 3 drafts, critic | 92 % | 4.3 | 40 s | 11 271 |
| DeepSeek V4.1 Flash, high | 100 % | 4.6 | 46 s | 10 579 |
| DeepSeek V4.1 Flash 1017, high | 96 % | 4.6 | 42 s | 6 599 |
| DeepSeek V4.1 Flash 1017, high, photos | 96 % | 4.5 | 40 s | 5 861 |
| DeepSeek V4 Flash 0731, high | 71 % | 3.3 | 182 s | 26 316 |

Results on 12 new objects that are in no prompt (motorbike, crane, fire truck,
penguin, T. rex, violin, sailboat, robot arm, shuttle, bulldozer, cow, tram):

| Pipeline | Hit | Score | Time | Output tokens |
|---|---|---|---|---|
| GLM Flash, high, photos, 3 drafts | 100 % | 4.3 | 22 s | 8 265 |
| GLM Flash, same, plus master examples | 100 % | 4.3 | 22 s | 9 321 |
| DeepSeek 1017, high, photos | 100 % | 4.2 | see note | 5 538 |
| DeepSeek 1017, same, plus master examples | 92 % | 4.9 | 59 s | 9 546 |

Note: the 203 s median of the plain DeepSeek run is rate limit wait, not model
time. GLM with 3 drafts and photos reaches 96 % on the first 24 objects.

Recommended pipeline:

1. One cheap call names the subject. A library model is used if it exists.
2. The server fetches 3 photos and a fact text, one at a time, cached.
3. GLM Flash writes 3 drafts in parallel at high effort. The judge picks one.
   The user sees a picture after about 22 s.
4. DeepSeek V4.1 Flash 1017 at high effort, with the master examples, replaces
   the picture after about 1 minute.
5. Good results go into the library. A repeated subject is then instant.

No critic round. Keep `max_tokens` at 48 000.

Findings:

- The score is weak: the GLM judge gives almost every picture 3 to 5, and a
  head-to-head vote is near 50 % for most pairs. Judge by eye as well.
- High variance between runs of one object is the main GLM problem.
- By eye DeepSeek with photos gives the best pictures.
- A critic round can damage a good picture. Tank and tractor came apart.
- `max` effort gave worse results at 8 times the time, and DeepSeek needs
  `max_tokens` of 48 000: at 16 000 the reasoning used all tokens and the answer
  was empty.
- Wikimedia answers 429 to bursts. Fetch photos one at a time and cache them.
- Facts need a source. A model places a connector from memory at the wrong
  place. Photos, facts and vetted models in `library/` fix this.

## Pipeline: any subject

`draw.py <out> "<request>" [--ctx image] --film`.

The result is always a 3D model that GLM generates from Chalk parts. Owner
decision, 2026-10-31: a screenshot or photo is only a reference that the model
looks at. Never cut pixels out of it and never put them on the model. The photo
body trial (`photo.mjs`, `tex=`) is rejected, nothing in the pipeline uses it.

1. GLM names the subject and an image search.
2. With `--ctx`, GLM finds the object in the screenshot and the crop is the
   reference. Without it, Bing images and Wikimedia give candidates and GLM
   picks one.
3. GLM writes 3 drafts with the reference at high effort.
4. Lints and a vision vote pick one. Parts that move as one are repaired as a
   group, so a helicopter holds together and stays off its pad.
5. Render and film.

Traps: grid numbers must be pixels of the shown image, because the model reads
pixels. Take screenshots at scale 3. Wikimedia and stock sites: see above.

Hard test of pure Chalk with no kit and no blueprint, 16 odd objects: 94 % blind
hit, 4.4 score, 23 s. See `versions/v10_kontextbild`.

## Forge: dense models with real light (v12)

`forge.py <out> "<request>" [--ctx image] --film`. Long runs: use `systemd-run --user`.

1. Reference: a screenshot crop or an image search. Reference only, as always.
2. Skin: 3 GLM drafts of the outer form with `body`, `loft` and so on, a vision vote,
   2 rounds of correction with a three-quarter and a side view.
3. Surface work on the skin (`paint.mjs`): `paint`, `seam`, `decal` clip the real mesh,
   so windows, liveries, panel lines and text follow the curve for a few tokens.
4. Plan: GLM splits the object into 8 to 16 assemblies with real boxes. The engine prints
   a station table of the skin, so that each builder knows where the surface is.
5. Assemblies: one GLM call each, in parallel, 40 to 120 lines. Off-plan results are fitted
   to their box. `tidy=1` removes small loose crumbs.
6. Critic: 2 rounds with 3 angles. It rebuilds or removes assemblies. A vote keeps a round
   only if it is better.
7. Film: a last call writes `anim`. `swing` is the hinge action.

Renderer: `export3d.mjs` bakes parts per motion and material. `view/viewer.js` is three.js
PBR. One frame adds up 24 to 96 renders with a moving light, which gives soft shadows,
occlusion and clean edges. It runs in a browser on any GPU, 0.05 s per sample here on an
RTX 3060. `render3d.py` drives it in headless Chrome: the flag `--use-angle=gl-egl` is
required, other flags gave a white page.

Numbers: 700 to 1850 parts, 300 000 to 1 000 000 triangles. 8 to 12 minutes of model time.
Traps: a sliver polygon on a clip plane multiplies pieces, so `solid()` drops it. Do not run
`pkill -f` with a pattern that the own shell holds.

## Open work

- Port the engine to Dart and add a chat block. Render time on phones is unknown.
- T3 restarts kill background jobs. Run long tests as a systemd unit:
  `systemd-run --user --unit=chalk-bench --collect ./chain.sh`.
- Orbit by drag needs a lower resolution while dragging.
- Stream lines to the canvas. Show a fast GLM picture first, then replace it
  with the DeepSeek picture.
- Cache good results as library models, so a repeated subject is free and instant.
- Fetch reference photos on the server. Check the image license before any
  image reaches a user. Today the photos only go to the model.
- In the helicopter film a label can stay on the pad for a moment.
- Anatomy (cow, hand) stays the weakest group.
- Arrows between elements that are not neighbours can cross other elements. The
  lint reports it, the router does not avoid it yet.
