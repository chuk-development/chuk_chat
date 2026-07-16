// GENERATED CODE - DO NOT MODIFY BY HAND
//
// Source: assets/skills/<name>/SKILL.md
// Regenerate: dart run tool/gen_skills.dart
//
// builtin_skills_freshness_test.dart fails if this file is
// out of date with the .md sources.

// ignore_for_file: lines_longer_than_80_chars

import 'package:chuk_chat/models/skill.dart';

/// Skills authored in this repo and compiled into the binary.
///
/// Built-in skills carry the same trust level as the Dart code
/// around them: they are reviewed here and cannot change after
/// the build. Nothing is fetched from a marketplace at runtime.
const List<Skill> kBuiltinSkills = <Skill>[
  Skill(
    name: 'chart-authoring',
    description:
        'Authors <chart> blocks — bar, line, pie, scatter and radar — with the exact JSON field schema. Use when the user asks for a chart, graph, plot, trend, comparison, Diagramm, Grafik, Verlauf, or when numeric data would read better visualized. Load before emitting a <chart> block.',
    body:
        '# Chart authoring\n\nThe app renders a `<chart>` block as an interactive chart. It is an output\ntag, not a tool: write the JSON directly in your response text. There is no\ntool to call and nothing to discover — get the data first with whatever tool\nfits, then draw it.\n\n## Format\n\n<chart>\n{"type":"line","title":"Revenue Growth","labels":["Q1 2024","Q2 2024","Q3 2024","Q4 2024"],"datasets":[{"label":"2024","data":[120,180,250,310],"color":"#4CAF50"},{"label":"2023","data":[90,110,140,190],"color":"#2196F3"}],"height":350}\n</chart>\n\n## Types\n\n`bar`, `line`, `pie`, `scatter`, `radar`.\n\nPick by question, not by habit: `line` for change over time, `bar` for\ncomparison across categories, `pie` only for parts of one whole (and only\nwith a handful of slices), `scatter` for correlation between two numeric\nvariables, `radar` for several comparable dimensions of the same subject.\n\n## Fields\n\n- `type`: `bar` | `line` | `pie` | `scatter` | `radar` (required)\n- `title`: chart title (required)\n- `labels`: x-axis labels, e.g. `["Jan 2025","Feb 2025","Mar 2025"]`\n  (required for bar/line/radar)\n- `datasets`: array of data series (required for bar/line/radar/scatter)\n  - `label`: series name\n  - `data`: array of numbers, or `{x, y}` objects for scatter\n  - `color`: hex color like `"#FF5722"`\n- `data`: for pie charts only — array of\n  `{"label":"...","value":N,"color":"#..."}`\n- `height`: pixels (default 250; use 350-500 for detailed charts)\n- `max_y` / `min_y`: fix the y-axis range\n- `max_x` / `min_x`: fix the x-axis range (scatter only)\n\n## Rules\n\n- Only chart numbers that came from tool results in this conversation, or\n  that the user supplied. Never fabricate data points to make a nicer curve.\n- For stock and financial time series, include the full history you were\n  given — do not downsample.\n- Never use `scatter` for geographic data. Use a `<map>` block instead.\n- Give every dataset an explicit `color` when there is more than one series.\n- Write your full text answer FIRST, then the `<chart>` block at the very\n  END, and stop after `</chart>`.',
    metadata: <String, String>{'version': '1.0'},
  ),
  Skill(
    name: 'deep-research',
    description:
        'Multi-step research discipline — search, crawl primary sources, cross-check from a second angle, then answer. Use when a question needs current or contested facts, when the user claims something is new or just released, or when one search would only give a shallow answer.',
    body:
        '# Deep research\n\nA single search plus a summary of its snippets is a shallow answer. It reads\nas confident and is wrong often enough to matter. Use this loop instead.\n\n## The loop\n\n1. **Search** — `web_search` to find candidate sources. Read the\n   `extra_snippets` bullets (on by default) before deciding you need more.\n2. **Crawl** — `web_crawl` the 1-3 best results for full detail and context.\n   Snippets are lossy; the article is the source.\n3. **Cross-check** — if gaps or contradictions remain, search again from a\n   different angle (different wording, different source type, the primary\n   party\'s own page).\n4. **Compile** — build the answer from crawled content, not from search\n   snippets. Say what you could not confirm.\n\n## Search tuning\n\n- German queries or DE-specific facts (prices in EUR, DE law, local events):\n  pass `country: "DE"` and `search_lang: "de"` so the SERP is localized.\n- `freshness` (`pd`/`pw`/`pm`/`py`) applies to web mode too, not just news —\n  use it whenever recency matters ("latest release notes", "current version").\n\n## Fresh releases\n\nSearch engines take hours to days to index new content. When the user says\nsomething was JUST released, `web_search` alone is not evidence of absence.\nCrawl primary sources directly:\n\n- HuggingFace org pages (e.g. `https://huggingface.co/MiniMaxAI`,\n  `https://huggingface.co/Qwen`)\n- GitHub org pages and release pages\n- Official blogs and announcement pages\n\nIf search results contradict the user\'s claim about a very recent release,\ncrawl the source directly before concluding it does not exist.\n\n## Rules\n\n- Never fabricate facts, URLs, prices, or figures to fill a gap. An\n  unanswered sub-question stated plainly beats a fluent guess.\n- Never stop with intention-only text ("I will now search"). Either emit the\n  next tool call, or give the complete final answer.\n- Distinguish what a source states from what you inferred. When sources\n  disagree, say so and name them rather than silently picking one.',
    metadata: <String, String>{'version': '1.0'},
    allowedTools: <String>['web_search', 'web_crawl'],
  ),
  Skill(
    name: 'news-cards',
    description:
        'Fetches time-sensitive news and renders it as a <news> card block with thumbnail, publisher and age. Use when the user asks for the latest, news, today, breaking, recent, aktuell, neu, heute, Schlagzeilen — load this before emitting a <news> block.',
    body:
        '# News cards\n\nThe app renders a `<news>` block as polished article cards (thumbnail, title,\npublisher, summary, tap-to-open). It is an output tag, not a tool: write the\nJSON directly in your response text.\n\n## Workflow\n\n1. Call `web_search` with `type: "news"` and a matching `freshness`:\n   - `pd` — past day ("today", "breaking", "heute", "gerade")\n   - `pw` — past week ("this week", "diese Woche")\n   - `pm` — past month\n   - `py` — past year\n   The news mode returns publisher, age and thumbnail directly, so no\n   separate crawl is needed just to build the cards.\n2. For German or DE-specific queries, also pass `country: "DE"` and\n   `search_lang: "de"` so the SERP is localized.\n3. Emit exactly one `<news>` block built from the results.\n4. Only call `web_crawl` afterwards when the user asks for full article\n   detail — the cards already carry the summary.\n\n## Format\n\n<news>\n{"items":[{"title":"Qualcomm surges on OpenAI tie-up","publisher":"Reuters","age":"3 hours ago","url":"https://www.reuters.com/...","thumbnail":"https://...","summary":"Qualcomm shares jump 13% on reports of a partnership with OpenAI and MediaTek to develop AI smartphone processors.","breaking":false}]}\n</news>\n\n## Fields per item\n\n- `title`: headline (required)\n- `url`: article URL (required)\n- `publisher`: source name, e.g. "Reuters" (optional)\n- `age`: e.g. "3 hours ago", "1 day ago" (optional)\n- `thumbnail`: image URL from the search result\'s `thumbnail_url` (optional)\n- `summary`: 1-2 sentences, taken from the result description (optional)\n- `breaking`: true when the result is flagged BREAKING (optional)\n\n## Rules\n\n- Only include fields that came from `web_search type:"news"` results.\n  Never fabricate URLs, publishers or thumbnails.\n- Do NOT also list the same articles as markdown — the cards contain\n  everything. A short intro sentence above the block is fine.\n- Emit at most one `<news>` block per response.\n- Put the block at the very END of your answer and stop after `</news>`.',
    metadata: <String, String>{'version': '1.0'},
    allowedTools: <String>['web_search', 'web_crawl'],
  ),
  Skill(
    name: 'weather-cards',
    description:
        'Renders weather data as a <weather> card with current conditions, daily forecast and hourly outlook. Use when the user asks about weather, forecast, temperature, rain, wind, storm, Wetter, Vorhersage, Regen, Temperatur — load this before emitting a <weather> block.',
    body:
        '# Weather cards\n\nThe app renders a `<weather>` block as a polished weather card. It is an\noutput tag, not a tool: write the JSON directly in your response text.\n\n## Workflow\n\n1. Call the `weather` tool first. If the user named a place the tool cannot\n   resolve, use `geocode` to get coordinates, then call `weather` again.\n2. Emit exactly one `<weather>` block, populated **only** from the tool\n   output.\n3. Do not also dump the raw tool text — the card already contains everything.\n   A short sentence above the block is fine.\n\n## Format\n\n<weather>\n{"location":"Kiel, Schleswig-Holstein, Germany","current":{"temp":8,"feels_like":5,"condition":"Partly cloudy","code":2,"humidity":72,"wind_speed":14,"wind_dir":"W","precipitation":0,"unit_temp":"C","unit_wind":"km/h","unit_precip":"mm"},"daily":[{"date":"2026-04-24","code":2,"temp_max":10,"temp_min":3,"precip_prob":20,"condition":"Partly cloudy"}],"hourly":[{"time":"14:00","code":2,"temp":8,"precip_prob":10}]}\n</weather>\n\n## Fields\n\n- `location`: display name (required)\n- `current`: `{temp, feels_like, condition, code (WMO 0-99), humidity,\n  wind_speed, wind_dir (N/NE/.../NW), precipitation, unit_temp ("C"|"F"),\n  unit_wind, unit_precip}` (required)\n- `daily`: array of `{date (YYYY-MM-DD), code, temp_max, temp_min,\n  precip_prob, condition}` (optional, recommended for forecast queries)\n- `hourly`: array of `{time (HH:MM or ISO), code, temp, precip_prob}`\n  (optional, include when the user asks for the next hours)\n\n## WMO codes\n\n`0`=clear, `1-2`=partly cloudy, `3`=overcast, `45`/`48`=fog, `51-57`=drizzle,\n`61-67`=rain, `71-77`=snow, `80-82`=rain showers, `85-86`=snow showers,\n`95-99`=thunderstorm.\n\n## Rules\n\n- Only include fields that came from `weather` tool results in this\n  conversation. Never fabricate temperatures, codes, or forecasts.\n- Emit at most one `<weather>` block per response.\n- Put the block at the very END of your answer and stop after `</weather>`.\n- Match `unit_temp` to the user\'s locale expectation: "C" for German and\n  European queries, "F" only when the user is clearly using Fahrenheit.',
    metadata: <String, String>{'version': '1.0'},
    allowedTools: <String>['weather', 'geocode'],
  ),
];
