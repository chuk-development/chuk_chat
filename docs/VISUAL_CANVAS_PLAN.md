# Visual canvas: a shared drawing channel between user and AI

Status: plan, nothing built. Date: 2026-10-30.

## Goal

The user draws or marks something. The AI sees it and draws back. The loop
repeats. GLM 5.3 Flash (`z-ai/glm-5.3-flash`, `supports_vision: true`; plain
`glm-5.3` has no vision) must do this with no training and a small prompt.

Scope: canvas inside the app. No overlay on the user's desktop.

Reference: heyclicky "real-time graphics" (https://youtu.be/YlW_-hdw7hs,
2026-10-29). The engine is private. The open-source `farzaa/clicky` does not
contain it. The 3D scenes in the video look like generated primitives with
labels on 3D points. This is an inference from the frames, not a known fact.

## Current state

- `markdraw` (`vendor/markdraw`) renders and edits. It has Excalidraw import
  and export, PNG and SVG export, and a text format.
- `artifact_manager` with raw Excalidraw JSON (`lib/services/tool_executor.dart`,
  `_excalidrawSchemaText`). The model must set pixel coordinates. A change is a
  full rewrite. The model gets no image and no check of the result.
- `technical_drawing` is a separate JSON format for DIN drawings.

## Design

### Format

A line-based format with a closed catalogue. The model names things and
relations. A solver sets the coordinates.

```text
scene "Turbofan"
box fan "Fan"
box comp "Compressor"
box burn "Combustor"
row fan comp burn
fan -> comp "air"
note burn "fuel ignites here"
```

Rules:

- One element on each line, with a stable id. The renderer can draw each
  complete line while the stream runs. It drops an incomplete last line.
- Edits are lines too (`move`, `set`, `delete`), so a change is not a rewrite.
- Optional hints, no required coordinates.
- Excalidraw stays an export and import target, not the model's format.

### Feedback loop

Each draw returns text first, because this is cheap and exact:

- Element list with ids and positions.
- Lints: text overflow, overlaps, loose arrows, elements out of frame.

The model asks for an image with `look`, normally once at the end. Research
shows that a render after each step can make untrained models worse.
(https://arxiv.org/html/2604.20730v1)

### User input

User strokes stay in the scene. The app sends what they touch, as text, plus a
small PNG: "user circled `comp`". Pins point at an element. The model can point
back with a tag.

### 3D

A second catalogue, same line format: `box`, `cylinder`, `extrude`, `lathe`,
with position and label. No assets needed for the first version.

Renderer order:

1. `flutter_scene` (0.24.3). Test first: it needs Flutter GPU, so check Linux,
   Android and web.
2. Fallback: own `CustomPainter` renderer with projection, depth sort and flat
   shading.

glTF assets and text-to-3D are optional additions, later.

## Steps

1. Benchmark, no UI: 20 prompts over 3 formats (Excalidraw JSON, Mermaid or D2,
   the new format) on GLM 5.3 Flash. Measure render rate, lint errors, tokens
   and time. **No data for GLM 5.3 Flash exists, so this decides the format.**
2. Parser, solver and output to `markdraw`, with streaming in a chat block.
3. Feedback tools: lints, `look`, edit lines.
4. User strokes and pins as input.
5. 3D: renderer test, then the catalogue.

## Prior art

| Project | What to take | Limit |
|---|---|---|
| excalidraw-mcp (MIT) | Streaming, drop incomplete element, checkpoints | Model still sets coordinates |
| tldraw agent kit | Typed actions, shapes in detail levels, lints, pins | License needs watermark or business plan |
| Feynman + Penrose | Content and layout apart: 97.0 % compile, 87.5 % yield with GPT-4o-mini | Research, no direct comparison with coordinates |
| OpenUI Lang (MIT) | Compact line format, 52 % fewer tokens (own benchmark) | UI only, no image feedback |
| A2UI (Apache-2.0) | Closed component catalogue | UI only |
| D2 (MPL-2.0), Pintora (MIT) | Layout from text | No feedback loop |

Links:

- https://github.com/excalidraw/excalidraw-mcp
- https://tldraw.dev/starter-kits/agent
- https://tldraw.dev/blog/agents-cant-point
- https://arxiv.org/html/2603.12597 (Feynman)
- https://arxiv.org/html/2605.15677v1 (GLM-4.6V on mxGraph: ESR 0.747)
- https://github.com/thesysdev/openui
- https://heyclicky.com/changelog

## Known gaps

- No paper compares semantic formats with coordinates directly on a canvas.
- No tweets or HN threads about the Clicky engine were read.
- `flutter_scene` is not tested on our targets.
