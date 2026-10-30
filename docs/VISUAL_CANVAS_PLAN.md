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
