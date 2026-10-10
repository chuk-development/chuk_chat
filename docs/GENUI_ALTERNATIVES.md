# Generative UI for chuk_chat: alternatives to OpenUI

Status: research, 2026-10-10. Read-only survey. No code changed.

Scope: the LLM writes a UI description. The app renders native Flutter
widgets in its own theme, while the tokens stream in. OpenUI itself
(thesysdev/openui and the port mtwichel/openui_flutter) is covered in
`docs/OPENUI_RESEARCH.md`. This file only compares OpenUI with the other
options.

Data sources: `gh api` (repo metadata, commits, contributors, releases) and the
pub.dev JSON API (`/api/packages/<name>`, `/score`). All dates are UTC.

## Comparison table

Tokens = o200k_base tokens for one sample card (flight card: title, subtitle,
three key/value rows, two buttons), measured with tiktoken. See
[Token cost](#token-cost-of-the-formats) for the method and the limits.

| Candidate | Maintainer / backing | License | Last release / activity | Flutter status | Streaming | Tokens (sample card) | Own theme / own widgets | Catalogue | Model-agnostic | Web |
|---|---|---|---|---|---|---|---|---|---|---|
| **A2UI protocol** (a2ui-project/a2ui, ex google/A2UI) | Google (Flutter + Gemini teams), open org, 16.7k stars | Apache-2.0 | v0.9.1 stable, v1.0 RC; 100+ commits in last 30 days; push 2026-10-10 | Official Dart core `a2ui_core` 0.2.2 (2026-09-28) | Yes, JSONL message by message | 393 (JSON min), 730 (JSON pretty), 165 (Express DSL) | Yes. Client owns the catalog, every component is your widget | Basic catalog: 18 components + 14 functions; custom catalogs | Yes. Any model that writes JSON | Yes |
| **Flutter GenUI SDK** (`genui`, flutter/genui) | Google Flutter team (publisher labs.flutter.dev) | BSD-3-Clause | genui 0.10.4 on 2026-09-29; 40 commits since 2026-07-01 | Official A2UI renderer today. Being replaced by `a2ui_flutter` (new API, 0.0.1-wip) | Yes, per A2UI message; text and UI interleave | as A2UI | Yes. `CatalogItem` = name + JSON schema + Flutter builder | 18 basic widgets; add your own | Yes. `A2uiTransportAdapter.onSend` takes chunks from any client | Yes (pub tags: android, ios, macos, web; no linux/windows tag) |
| **Flutter AI Toolkit** (`flutter_ai_toolkit`) | Google Flutter team | BSD-3-Clause | 1.0.0 on 2025-12-15; only dependency bumps in 2026 | Chat widgets only. No generative UI | Text only | n/a | Chat styling only | n/a | Pluggable provider | Yes |
| **AG-UI** (+ Dart `ag_ui`) | CopilotKit company; Dart SDK is "community" | MIT | ag_ui 0.3.0 on 2026-06-24; last Dart commit 2026-08-05 | Dart client exists | Yes (SSE events) | n/a (transport, not a UI format) | n/a | n/a | Yes | Yes |
| **MCP Apps** (SEP-1865, modelcontextprotocol/ext-apps) and **MCP-UI** | MCP project (Anthropic + OpenAI + community); MCP-UI-Org | Apache-2.0 | ext-apps v2.0.3 on 2026-09-25; mcp-ui client v7.1.1 on 2026-05-09 | No Flutter renderer. UI is HTML in a sandboxed iframe, so Flutter needs a WebView | No (whole HTML resource) | n/a (MCP server writes HTML, not the LLM) | No. Server owns the look | Unlimited (HTML) | Yes | Yes (iframe) |
| `flutter_mcp_ui_runtime` (own "MCP UI DSL") | app-appplayer / makemind.dev, 2 people, 1 star | MIT | 0.8.4 on 2026-10-03 | Flutter only | No | JSON, verbose | Yes (ThemeDefinition to ThemeData) | 158 widgets | Yes | No web tag |
| **json-render** (vercel-labs/json-render) | Vercel Labs; 1 main author (ctate, 180 of ~215 commits) | Apache-2.0 | v0.21.0 on 2026-09-18 | No Dart. Two 0-1 star solo ports (BetaPundit/genui, Dev-Beom/flutter-json-render) | Yes (JSONL of JSON-Patch ops, "SpecStream") | 227 | Yes (registry maps names to components) | 36 shadcn components (web) | Yes | Web only |
| **Tambo** (tambo-ai/tambo) | Tambo company | MIT | react v1.4.0 on 2026-10-08, **Tambo Cloud shuts down 2026-10-31** | React only | Yes (props as tool calls) | n/a | React components | your components | Yes | Web only |
| **Thesys C1** | Thesys company | proprietary API | Renamed "OpenUI Cloud"; docs.thesys.dev now redirects to openui.com | No Flutter SDK | Yes | OpenUI Lang | Thesys components | Thesys library | Hosted gateway | Web |
| **OpenUI** (for comparison only) | Thesys company (10.7k stars) | MIT | push 2026-10-10 | Official runtimes React, Vue, Svelte, Angular. Flutter = solo port `openui_flutter`, 7 stars, last push 2026-05-28 | Yes, token by token | ~89 (higher-level components) | Yes | Charts, forms, tables, layouts | Yes | Yes |
| **rfw** (Remote Flutter Widgets) | Google Flutter team (publisher flutter.dev), in flutter/packages | BSD-3-Clause | 1.1.4 on 2026-09-17; first release 2021 | First-party Flutter. All 6 platforms, wasm-ready | No. Parse needs a full library file | 169 (text format) | Yes. You register a "local widget library" in Dart | 39 core + 22 material widgets; add your own | Yes, but models know little rfw syntax | Yes |
| **Stac** (ex Mirai) | Stac company (stac.dev); 1 main author (925 commits), ~5 others | MIT | stac 1.6.0 on 2026-09-13 | Flutter SDUI framework | No | 217 (JSON min) | Partly. `StacTheme` + custom parsers; JSON mirrors Flutter widgets | ~97 widget parsers | Yes, but not designed for LLMs | Yes |
| **Duit** (`flutter_duit`) | solo (lesleysin, 336 of 341 commits), 60 stars | MIT | 4.4.1 on 2026-03-16; last push 2026-05-15 | Flutter SDUI | No | JSON, verbose | Custom widgets possible | Flutter set | not designed for LLMs | Yes |
| `json_dynamic_widget` | Peiffer Innovations | MIT | **Archived** 2026-02; pub "discontinued" | dead | No | JSON, verbose | - | - | - | - |
| `mirai` | renamed to Stac | MIT | last 0.8.0 on 2025-01-08 | replaced by `stac` | - | - | - | - | - | - |

## Short notes per candidate

### 1. A2UI protocol (Google)

- Repo: https://github.com/a2ui-project/a2ui (the old URL github.com/google/A2UI
  redirects here). Site: https://a2ui.org
- What it is: a declarative JSON format for agent UI. The agent sends a flat
  list of components with ids (`createSurface`, `updateComponents`,
  `updateDataModel`, `deleteSurface`). The client maps each component name to
  its own native widget. The agent can only use components in the client's
  catalog. No code runs on the client.
- Status: "Early stage public preview". v0.9.1 is the production release, v1.0
  is a release candidate, v0.8 is legacy. Expect changes.
- Activity: very high. Top contributors are Google staff (gspencergoog 286,
  nan-yu 162, jacobsimionato 158, polina-c 73, ditman 71 commits). More than
  100 commits between 2026-09-10 and 2026-10-10.
- SDKs: Dart (`a2ui_core`, `a2ui_agent`), TypeScript, Python, Kotlin, Swift.
  Web renderers: Lit, Angular, React. Transports: A2A and AG-UI.
- Basic catalog v1: Text, Image, Icon, Video, AudioPlayer, Row, Column, List,
  Card, Tabs, Modal, Divider, Button, TextField, CheckBox, ChoicePicker, Slider,
  DateTimeInput. There is no Table and no Chart in the basic catalog. We add
  them as custom catalog items (we already have `ChukTable` and chart widgets).
- **A2UI Express**: a compact DSL that the model writes instead of JSON. A
  compiler turns it into standard A2UI v1.0 JSON. Syntax:
  `root = Card(col)` / `title = Text("LH 2041", "h3")`. It is the direct answer
  to OpenUI Lang. A pure-Dart compiler, parser and prompt generator exist in
  `dart/a2ui_agent/lib/src/inference_formats/express/`. Status: experimental
  (gated by `A2UI_EXPRESS_ENABLED` in Python). The Dart compiler works on a
  whole `<a2ui>...</a2ui>` block. It does not stream statement by statement.
  Docs: https://github.com/a2ui-project/a2ui/tree/main/specification/proposals/express
- Model-agnostic: yes. The README says "any model capable of generating JSON
  output". Express examples use Gemini, but the format is plain text.

### 2. Flutter GenUI SDK (`genui`)

- Repo: https://github.com/flutter/genui. Pub: https://pub.dev/packages/genui
  (publisher labs.flutter.dev, 197 likes, 42.6k downloads in 30 days).
- Version history: `flutter_genui` (2025-07, discontinued) became `genui`
  (2025-11). `genui_a2ui` is discontinued and replaced by `genui_a2a`.
  Provider adapters: `genui_firebase_ai`, `genui_google_generative_ai`,
  `genui_dartantic` (last 2026-05-04).
- **Important (2026-09-30):** the README says "`genui` is being redesigned as a
  set of modular packages: `a2ui_core`, `a2ui_agent`, and `a2ui_flutter`. The
  new packages will have a different API." `a2ui_flutter` is 0.0.1-wip002
  (2026-08-12) and its README says "A new `a2ui_flutter` package is coming. In
  the meantime, please use genui." So the protocol is stable, but the Flutter
  API will change once more.
- How it works: `SurfaceController` (catalogs) + `A2uiTransportAdapter`
  (`onSend` callback; you call your own LLM and push chunks with `addChunk`) +
  `Conversation` facade + `Surface` widget per surface id. This fits our
  OpenAI-compatible stream from api.chuk.chat with no Gemini dependency.
- Streaming: `A2uiParserTransformer` reads the text stream, emits plain text
  as `TextEvent` and each complete JSON block (fenced or balanced) as an A2UI
  message. So the UI grows message by message, not token by token. The model
  must split big UIs into several `updateComponents` messages to show progress.
- Theming: each `CatalogItem` has a name, a JSON schema and a Flutter
  `widgetBuilder`. The builder can return our own widgets with our `ThemeData`.
  We do not have to use the basic catalog at all.
- Platforms: pub.dev tags android, ios, macos, web. It does not tag linux or
  windows. The likely cause is the basic catalog dependencies (`video_player`,
  `audioplayers`). `a2ui_core` itself is tagged for all six platforms. A Linux
  build must be tested before we adopt it.
- Prompt cost: a third-party repo (https://github.com/vildevev/genui_min) states
  that the default genui prompt is about 19k tokens and a pruned catalog is
  about 4.7k. We would send only our own small catalog. `a2ui_agent` has a
  "pruning" catalog transformer for this.
- Real use: VGV demo for Google Cloud Next 2026
  (https://github.com/VGVentures/genui_life_goal_simulator), Flutter blog post
  https://blog.flutter.dev/rich-and-dynamic-user-interfaces-with-flutter-and-generative-ui-178405af2455

### 3. Flutter AI Toolkit

- https://github.com/flutter/ai, https://pub.dev/packages/flutter_ai_toolkit
- A chat view (`LlmChatView`) with a provider interface. It has no generative
  UI. Since 1.0.0 (2025-12-15) there are only dependency updates. chuk_chat
  already has a better chat UI. Not relevant.

### 4. AG-UI (CopilotKit) and the Dart client

- https://github.com/ag-ui-protocol/ag-ui (MIT, 16.4k stars),
  Dart SDK in `sdks/community/dart`, pub `ag_ui` 0.3.0 (2026-06-24).
- AG-UI is an event transport between agent backend and frontend (SSE: text,
  tool calls, state patches). It is not a UI format. A2UI can travel over it.
- We already have our own streaming protocol to api.chuk.chat. AG-UI adds no
  rendering. Only relevant if we want to talk to third-party AG-UI agents.

### 5. MCP Apps (SEP-1865) and MCP-UI

- Spec: https://github.com/modelcontextprotocol/ext-apps (spec 2026-01-26,
  ext-apps v2.0.3 on 2026-09-25). MCP-UI: https://github.com/MCP-UI-Org/mcp-ui
  (client v7.1.1 on 2026-05-09).
- An MCP server ships a `ui://` HTML resource. The host shows it in a
  sandboxed iframe and talks to it with postMessage. The look belongs to the
  server, not to our theme. Flutter needs a WebView (we already ship
  `flutter_inappwebview` / `webview_flutter`).
- This solves a different problem: UI from MCP connectors (we have
  `FEATURE_MCP`). It is not a way for the chat model to write native widgets.
  Keep it as a separate, later feature.
- `flutter_mcp_ui_runtime` (https://github.com/app-appplayer/flutter_mcp_ui_runtime)
  is not MCP-UI. It is its own JSON DSL with 158 widgets, by a 2-person org
  with 1 star. Too much risk.

### 6. Vercel json-render

- https://github.com/vercel-labs/json-render (Apache-2.0, 18.6k stars,
  v0.21.0 on 2026-09-18). Renderers: React, React Native, Vue, Svelte, Solid,
  Ink, PDF, email, Remotion. No Dart.
- Format: a flat map of elements (`type`, `props`, `children`, `on`), streamed
  as JSONL JSON-Patch operations. The idea is simple to port. But the only
  Flutter ports are 0-1 star solo repos. Most commits come from one Vercel
  Labs author. Labs projects can stop without notice.

### 7. Tambo

- https://github.com/tambo-ai/tambo (MIT). React only. Components are
  registered as tools with Zod schemas.
- **The README says: "Tambo Cloud is shutting down" on 2026-10-31.** The team
  moves to another product. Do not use.

### 8. Thesys C1

- C1 is now "OpenUI Cloud" ("Formerly the C1 API", https://www.thesys.dev/).
  docs.thesys.dev redirects to openui.com. It is a hosted gateway with React
  components and a proprietary API. It does not fit our own api_server and our
  own model routing. See `docs/OPENUI_RESEARCH.md` for OpenUI itself.

### 9. rfw (Remote Flutter Widgets)

- https://github.com/flutter/packages/tree/main/packages/rfw,
  https://pub.dev/packages/rfw (publisher flutter.dev, 697 likes, release
  1.1.4 on 2026-09-17, first release 2021).
- The most stable option. Google owns it, it is pure Dart, it runs on all six
  platforms and on web (wasm-ready).
- Format: text (`.rfwtxt`) or binary. The text is compact (169 tokens for the
  sample card). Widgets come from a "local widget library" that we write in
  Dart, so every component is our own widget in our own theme.
- Limits for LLM use: it was built for server-written UI, not for LLMs.
  `parseLibraryFile` needs a complete file, so there is no token streaming
  (we could re-parse a cut-off prefix, but a syntax error drops the whole
  block). Models know little rfw syntax, so the prompt must teach it. There is
  no prompt generator and no repair pass. Its own README says it is good for
  "rich result cards" made of prebuilt components, which is our case.

### 10. Server-driven UI packages on pub.dev

- **Stac** (https://github.com/StacDev/stac, ex `mirai`): MIT, stac 1.6.0 on
  2026-09-13, company stac.dev, but one author has 925 commits. About 97
  widget parsers. JSON mirrors the Flutter widget tree (`column`,
  `elevatedButton`, `style.fontSize`). That gives the model too much freedom
  over the look and costs tokens. No streaming. Built for server-pushed
  screens, not for chat.
- **Duit** (https://github.com/Duit-Foundation/flutter_duit): solo
  maintainer, 60 stars, last push 2026-05-15. Too small.
- **json_dynamic_widget**: archived, discontinued on pub.dev. Dead.

### 11. Other 2026 finds (all small, not candidates)

- https://github.com/diegolopezrm/genui_gen: build_runner codegen that turns
  an annotated Flutter widget into a genui `CatalogItem`. Solo, 0 stars, but a
  useful idea for our catalog.
- https://github.com/vildevev/genui_min: minimal genui catalog plus a repair
  pass for small-model output. Solo.
- https://github.com/ananmouaz/flutter_ai (12 stars), flyerhq/flutter_chat_ui
  (chat UI, no UI format). Not relevant.

## Token cost of the formats

Method: one flight card (title, subtitle, three key/value rows, two buttons)
written in each format by hand, counted with tiktoken `o200k_base`.

| Format | Tokens | Characters |
|---|---|---|
| A2UI v0.9 JSONL, minified | 393 | 1335 |
| A2UI v0.9 JSON, pretty (models often indent) | 730 | 2551 |
| A2UI Express DSL | 165 | 468 |
| rfw text | 169 | 606 |
| Stac JSON, minified | 217 | 793 |
| json-render SpecStream, minified | 227 | 787 |
| OpenUI Lang (approximate syntax) | 89 | 288 |

Limits of this estimate:

- Component granularity matters as much as syntax. The OpenUI and json-render
  samples use a `Table` and a `CardHeader`. The A2UI basic catalog has no
  table, so the A2UI samples use nine `Text` nodes in three `Row`s. With a
  custom `KeyValue` or `Table` item, A2UI JSON drops to about 200 tokens and
  Express to about 90.
- GLM/DeepSeek/Kimi tokenizers differ from o200k. The ratios stay similar.
- The system prompt (catalog description) often costs more than the output.
  Keep the catalog small (10-15 items).

## Recommendation for chuk_chat

Constraint from the owner: no dependency on a dead solo project. We run GLM,
DeepSeek, Kimi and others through an OpenAI-compatible API, so the solution
must not need Gemini or a hosted gateway.

**1. A2UI as the protocol, rendered with Google's Flutter SDK (`genui` now,
`a2ui_flutter` later), with our own catalog.**

- Lowest maintenance risk: Google owns the protocol and the Flutter renderer.
  Both are very active (100+ commits per month). Apache-2.0 / BSD-3.
- Model-agnostic: we feed our own stream into `A2uiTransportAdapter.addChunk`.
- Our look: every catalog item is our widget (ChukTable, our charts, map,
  buttons from `docs/DESIGN.md`). We skip the basic catalog.
- Token cost: JSON is expensive. Use a small catalog with high-level items.
  Later, test A2UI Express (Dart compiler exists) to get near OpenUI Lang cost.
- Risks: the `genui` API will change (redesign announced 2026-09-30), and
  A2UI is still "preview". Mitigation: keep genui behind one adapter file,
  pin the version, and keep catalog builders as thin wrappers so the move to
  `a2ui_flutter` touches one place. Test a Linux build first (no linux tag on
  pub.dev).
- Streaming is per message, not per token. Instruct the model to emit the
  card skeleton first and fill data with later messages.

**2. rfw as a fallback renderer for a compact, fully native format.**

- Google-owned since 2021, stable API, all platforms, compact text.
- Every widget is our own local widget library, so theming is complete.
- Weak points: no streaming, no LLM tooling, models do not know the syntax,
  one syntax error drops the block. Use it only if A2UI JSON turns out too
  expensive or too unstable with our models.

**3. OpenUI Lang with our own Dart parser (not `openui_flutter`).**

- Lowest token cost and real token-by-token streaming. The language is MIT
  and small, so we can own the parser and do not depend on the solo port.
- Risk: the format belongs to one company (Thesys), and the official runtimes
  are web only. Details are in `docs/OPENUI_RESEARCH.md`.

Do not use: Tambo (cloud shuts down 2026-10-31), Thesys C1 (hosted, now OpenUI
Cloud), json-render (no Dart, Labs project), Stac/Duit/json_dynamic_widget
(server-driven UI, not LLM-oriented; Duit solo, json_dynamic_widget dead),
`flutter_mcp_ui_runtime` (tiny team), Flutter AI Toolkit (no generative UI).
Keep MCP Apps in mind as a separate feature for MCP connectors.

Baseline to remember: chuk_chat already has its own tag protocol
(`<chart>`, `<map>`, `<email>` in `lib/services/tool_prompt_builder.dart`,
rendered in `lib/widgets/message_bubble.dart`). Option 1 can start as one more
tag (for example an `<a2ui>` block) that the existing stream handler routes to
a genui `Surface`, so the current tags keep working.
