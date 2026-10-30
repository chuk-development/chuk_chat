# Chalk: a shared visual channel between user and AI

Status: working prototype in `tools/chalk/`, tested with GLM 5.3 Flash.
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
| `PROMPT.md` | System prompt with 8 worked examples, about 13 000 characters |
| `eval.py` | Draw, feedback, fix loop over the task list |
| `loop.mjs`, `mark.mjs`, `stroke.py`, `shot.py` | Loop step, user mark test, SVG to PNG |
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

## Results, 18 tasks, GLM 5.3 Flash

Six tasks are holdouts with no matching example (tank, drone, phone, boat, hand,
lighthouse).

| Effort | Median time for all rounds | Median output tokens | Quality by eye |
|---|---|---|---|
| low | about 10 s | about 1 200 | 2D good, physical objects often wrong |
| high | 22 s | 3 255 | Most physical objects recognizable |

Median input over all rounds is 18 789 tokens, because the prompt is sent in
each round. Output speed was about 180 tokens/s by rough estimate. The numbers
are from one run on 2026-10-30. Quality was judged by one person from images,
not by a metric.

Weak results at high effort: anatomy (heart, hand) and hard silhouettes (F-35).

## Open work

- Port the engine to Dart and add a chat block. Render time on phones is unknown.
- Orbit by drag needs a lower resolution while dragging.
- Stream lines to the canvas. High effort thinks first, so a first picture can
  come from a fast low-effort draft and be replaced.
- Arrows between elements that are not neighbours can cross other elements. The
  lint reports it, the router does not avoid it yet.
