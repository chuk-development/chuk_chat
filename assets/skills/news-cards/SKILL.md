---
name: news-cards
description: Fetches time-sensitive news and renders it as a <news> card block with thumbnail, publisher and age. Use when the user asks for the latest, news, today, breaking, recent, aktuell, neu, heute, Schlagzeilen — load this before emitting a <news> block.
allowed-tools: web_search web_crawl
metadata:
  version: "1.0"
---

# News cards

The app renders a `<news>` block as polished article cards (thumbnail, title,
publisher, summary, tap-to-open). It is an output tag, not a tool: write the
JSON directly in your response text.

## Workflow

1. Call `web_search` with `type: "news"` and a matching `freshness`:
   - `pd` — past day ("today", "breaking", "heute", "gerade")
   - `pw` — past week ("this week", "diese Woche")
   - `pm` — past month
   - `py` — past year
   The news mode returns publisher, age and thumbnail directly, so no
   separate crawl is needed just to build the cards.
2. For German or DE-specific queries, also pass `country: "DE"` and
   `search_lang: "de"` so the SERP is localized.
3. Emit exactly one `<news>` block built from the results.
4. Only call `web_crawl` afterwards when the user asks for full article
   detail — the cards already carry the summary.

## Format

<news>
{"items":[{"title":"Qualcomm surges on OpenAI tie-up","publisher":"Reuters","age":"3 hours ago","url":"https://www.reuters.com/...","thumbnail":"https://...","summary":"Qualcomm shares jump 13% on reports of a partnership with OpenAI and MediaTek to develop AI smartphone processors.","breaking":false}]}
</news>

## Fields per item

- `title`: headline (required)
- `url`: article URL (required)
- `publisher`: source name, e.g. "Reuters" (optional)
- `age`: e.g. "3 hours ago", "1 day ago" (optional)
- `thumbnail`: image URL from the search result's `thumbnail_url` (optional)
- `summary`: 1-2 sentences, taken from the result description (optional)
- `breaking`: true when the result is flagged BREAKING (optional)

## Rules

- Only include fields that came from `web_search type:"news"` results.
  Never fabricate URLs, publishers or thumbnails.
- Do NOT also list the same articles as markdown — the cards contain
  everything. A short intro sentence above the block is fine.
- Emit at most one `<news>` block per response.
- Put the block at the very END of your answer and stop after `</news>`.
