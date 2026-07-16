---
name: chart-authoring
description: Authors <chart> blocks — bar, line, pie, scatter and radar — with the exact JSON field schema. Use when the user asks for a chart, graph, plot, trend, comparison, Diagramm, Grafik, Verlauf, or when numeric data would read better visualized. Load before emitting a <chart> block.
metadata:
  version: "1.0"
---

# Chart authoring

The app renders a `<chart>` block as an interactive chart. It is an output
tag, not a tool: write the JSON directly in your response text. There is no
tool to call and nothing to discover — get the data first with whatever tool
fits, then draw it.

## Format

<chart>
{"type":"line","title":"Revenue Growth","labels":["Q1 2024","Q2 2024","Q3 2024","Q4 2024"],"datasets":[{"label":"2024","data":[120,180,250,310],"color":"#4CAF50"},{"label":"2023","data":[90,110,140,190],"color":"#2196F3"}],"height":350}
</chart>

## Types

`bar`, `line`, `pie`, `scatter`, `radar`.

Pick by question, not by habit: `line` for change over time, `bar` for
comparison across categories, `pie` only for parts of one whole (and only
with a handful of slices), `scatter` for correlation between two numeric
variables, `radar` for several comparable dimensions of the same subject.

## Fields

- `type`: `bar` | `line` | `pie` | `scatter` | `radar` (required)
- `title`: chart title (required)
- `labels`: x-axis labels, e.g. `["Jan 2025","Feb 2025","Mar 2025"]`
  (required for bar/line/radar)
- `datasets`: array of data series (required for bar/line/radar/scatter)
  - `label`: series name
  - `data`: array of numbers, or `{x, y}` objects for scatter
  - `color`: hex color like `"#FF5722"`
- `data`: for pie charts only — array of
  `{"label":"...","value":N,"color":"#..."}`
- `height`: pixels (default 250; use 350-500 for detailed charts)
- `max_y` / `min_y`: fix the y-axis range
- `max_x` / `min_x`: fix the x-axis range (scatter only)

## Rules

- Only chart numbers that came from tool results in this conversation, or
  that the user supplied. Never fabricate data points to make a nicer curve.
- For stock and financial time series, include the full history you were
  given — do not downsample.
- Never use `scatter` for geographic data. Use a `<map>` block instead.
- Give every dataset an explicit `color` when there is more than one series.
- Write your full text answer FIRST, then the `<chart>` block at the very
  END, and stop after `</chart>`.
