# Visualizations / Interactive Views — Expansion Plan

Goal: match and beat ChatGPT's "Visualize" feature, but keep everything
**on-brand native Flutter UI** instead of raw model HTML. Raw HTML from the
model renders off-style in a Flutter app, so the strategy is: expand the
**native typed-view catalogue** and add **interactivity** (buttons that send
prompts, AI questions), not lean on generic HTML.

Reference: OpenAI "Make information visual with ChatGPT" (video jzmNh8lbSp8) +
https://learn.chatgpt.com/docs/visualizations

---

## 1. What ChatGPT "Visualize" actually does

From the video + docs:

- Turns dense info (e.g. meeting notes) into an **interactive interface** at a glance.
- User triggers with `@Visualize` or asks; model can also auto-pick.
- Supported forms: charts/plots, diagrams, **maps**, **calendars**, calculators,
  interactive simulations, interactive explanations.
- Iterate in place: "give me a calendar view" → re-renders.
- **Interactive**: tabs, adjustable inputs (sliders/toggles), and **buttons that
  send a prompt back into the chat**.
- Share: **export as image**, or **publish as a site** (public link).
- Under the hood it is one generic sandboxed HTML/JS canvas (snapshot, not a live dashboard).

## 2. What we already have (better than people think)

We do NOT start from zero. We already ship a **native, typed** view system that
looks better than generic HTML.

Inline view tags (model writes tag in its reply → regex parse → native widget):

- `<chart>` bar/line/pie/scatter/radar (`chart_widget.dart`, fl_chart)
- `<map>` markers / places / route+OSRM polyline (`map_block_renderer.dart`, `route_map_widget.dart`)
- `<weather>` current + daily + hourly (`weather_widget.dart`)
- `<news>` article cards w/ thumbnails (`cards.dart` `_NewsCard`)
- `<email>` mailto card, `<image>` image card, `<diff>` VS Code-style diff

Interactivity we already have:

- **`ask_user` tool** → native clickable option chips; tapping an option sends
  that label back as the user's next message. (`ask_user_card.dart`,
  `tools.dart` `_buildAskUserOptions`, wired in both chat UIs.) **This is already
  "AI asks you a question with buttons" and "button sends a prompt back."**
- **`request_mcp_server`** → inline Connect button card, same emit-button /
  tap-to-act pattern (`mcp_connect_card.dart`).

Artifacts (separate pipeline, editable side panel):

- Types: code, markdown, html, mermaid, svg, technical_drawing, typst, excalidraw
  (`artifact.dart`, `artifact_panel.dart`).
- `<artifact type="html">` renders live in a **sandboxed webview**
  (`html_artifact_view_io.dart`, flutter_inappwebview; JS on, fs/CORS/nav blocked).
  Web = iframe; Linux = source view unless the `-full` CI variant with webview_cef.
- `create_artifact` / `update_artifact` tools already **publish a self-contained
  HTML doc to a host and return a public link** (`artifact_tools.dart`). We
  already have "publish as a site."

Skills (progressive disclosure, keep prompt cheap): `chart-authoring`,
`weather-cards`, `news-cards` carry the tag schema on demand instead of always
sitting in the system prompt. New views should ship the same way.

## 3. The gap vs ChatGPT

Missing pieces, in rough priority:

1. **Generic action buttons anywhere in a reply** — `ask_user` only draws chips
   under the last message as a forced question. We want the model to drop
   tap-to-send buttons inline in normal answers ("buttons that send prompts").
2. **Calendar view** — none in-app (only a native OS "add to calendar" dialog).
3. **Table / grid view** — tables only render via markdown, not as a sortable native block.
4. **Timeline view** — meeting-notes / delivery-timeline use case from the video.
5. **KPI / stat cards, checklist / decision-tracker** — "what was decided / what
   still needs a decision" at-a-glance layout.
6. **Tabbed container** — group several views behind tabs.
7. **HTML artifact can't talk back to chat** (no postMessage bridge) and no
   **export-as-image**. Sliders/toggles that feed back into chat do not exist natively.

## 4. Proposal — three tracks

### Track A — Interactive action buttons (highest leverage, cheapest)

Generalise the `ask_user` pattern into a real inline block the model can place
anywhere: e.g. `<actions>{"buttons":[{"label":"Show calendar view","prompt":"give me a calendar view"}]}</actions>`.
Tapping a button sends its `prompt` back into the chat — exactly the video's
"buttons that send prompts for you." Reuse the existing chip widget + the
existing tap-to-send callback path.

Touches (per the mapped add-a-view path): `_richBlockRegex` + `_visualBlockStartRegex`
in `message_bubble.dart`; a branch in `rich_blocks.dart _buildVisualContent`;
a small widget (reuse `_OptionChip`); teaching text as a **skill**
(`assets/skills/action-buttons/SKILL.md`) so it costs no base tokens.

### Track B — New native typed views

Add, one at a time, as native widgets + skills, using the exact 5-step wiring
the codebase already uses for `<chart>`:

- `<calendar>` month/week/agenda (event list w/ date, title, time). Candidate lib
  `table_calendar`, or hand-rolled grid to stay on-brand.
- `<table>` sortable/native data grid (columns + rows + types).
- `<timeline>` vertical milestone timeline (date, title, status).
- `<stats>` KPI/stat-tile row (value, label, delta).
- `<checklist>` decision tracker (item, status: decided / needs-decision / blocked).

Each: add tag to both regexes, add dispatch branch in `rich_blocks.dart`, build
`lib/widgets/<x>_widget.dart`, ship a `assets/skills/<x>/SKILL.md` schema, run
`dart run tool/gen_skills.dart`. No flag needed unless we want a kill switch.

### Track C — Interactive HTML artifact bridge (the generic escape hatch)

For the "long doc → whole interface" case where a typed view is too rigid, keep
using the HTML artifact webview but make it interactive:

- Add a `postMessage` bridge so HTML inside the webview can **send a prompt back
  into the chat** (same callback as Track A). Sandboxed, whitelisted message shape.
- Add **export-as-image** of the rendered artifact (screenshot the webview / render boundary).
- Publish-as-site already exists (`create_artifact`).
- Do NOT try to make raw inline HTML render inside normal markdown — it stays in
  the artifact panel where the sandbox lives. This is the on-brand-vs-flexible tradeoff.

## 5. Decision points (for review)

1. **A `@Visualize` / explicit trigger** vs auto-only? We have no `@` mention
   composer today — is a trigger worth building, or just let the model auto-pick
   like the other view tags?
2. **How far into Track C** (generic HTML) do we go vs staying native? Native is
   on-brand and fast but finite; HTML is infinite but off-style and needs the webview
   (Linux desktop only gets it in the `-full` variant).
3. **Which native views first?** Suggest order: A (action buttons) → calendar →
   table → timeline/stats/checklist.
4. **Sliders/toggles that re-run the model** — worth it, or overkill? These are the
   most work (need state + re-prompt loop) for the least frequent use.
5. **Tabbed container** — build a real `<tabs>` block, or fake it with action
   buttons that swap views? Buttons are far cheaper.

## 6. Recommendation

Start with **Track A** (action buttons) — it is small, reuses `ask_user`
plumbing, and directly delivers the video's headline interaction. Then Track B
calendar + table + timeline as skills. Treat Track C as a later, optional
"generic canvas" escape hatch, gated behind the artifact panel so it never
pollutes the native look. This keeps every common case on-brand and native, and
only falls back to HTML when a bespoke interface truly needs it.
