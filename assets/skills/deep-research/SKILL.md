---
name: deep-research
description: Multi-step research discipline — search, crawl primary sources, cross-check from a second angle, then answer. Use when a question needs current or contested facts, when the user claims something is new or just released, or when one search would only give a shallow answer.
allowed-tools: web_search web_crawl
metadata:
  version: "1.0"
---

# Deep research

A single search plus a summary of its snippets is a shallow answer. It reads
as confident and is wrong often enough to matter. Use this loop instead.

## The loop

1. **Search** — `web_search` to find candidate sources. Read the
   `extra_snippets` bullets (on by default) before deciding you need more.
2. **Crawl** — `web_crawl` the 1-3 best results for full detail and context.
   Snippets are lossy; the article is the source.
3. **Cross-check** — if gaps or contradictions remain, search again from a
   different angle (different wording, different source type, the primary
   party's own page).
4. **Compile** — build the answer from crawled content, not from search
   snippets. Say what you could not confirm.

## Search tuning

- German queries or DE-specific facts (prices in EUR, DE law, local events):
  pass `country: "DE"` and `search_lang: "de"` so the SERP is localized.
- `freshness` (`pd`/`pw`/`pm`/`py`) applies to web mode too, not just news —
  use it whenever recency matters ("latest release notes", "current version").

## Fresh releases

Search engines take hours to days to index new content. When the user says
something was JUST released, `web_search` alone is not evidence of absence.
Crawl primary sources directly:

- HuggingFace org pages (e.g. `https://huggingface.co/MiniMaxAI`,
  `https://huggingface.co/Qwen`)
- GitHub org pages and release pages
- Official blogs and announcement pages

If search results contradict the user's claim about a very recent release,
crawl the source directly before concluding it does not exist.

## Rules

- Never fabricate facts, URLs, prices, or figures to fill a gap. An
  unanswered sub-question stated plainly beats a fluent guess.
- Never stop with intention-only text ("I will now search"). Either emit the
  next tool call, or give the complete final answer.
- Distinguish what a source states from what you inferred. When sources
  disagree, say so and name them rather than silently picking one.
