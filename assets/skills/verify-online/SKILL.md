---
name: verify-online
description: Confirm a specific fact with one web_search or web_crawl instead of answering from training memory. Use when about to state a checkable current fact — a version, price, date, who holds a role, whether something exists. For deep multi-source investigation use deep-research instead.
allowed-tools: web_search web_crawl
metadata:
  version: "1.0"
---

# Verify online

Training data is a snapshot with no date stamp on each fact. The model cannot
feel which facts went stale. So a wrong "current" fact comes out with the same
confidence as a right one — a version number that moved, a price that changed,
a person who left the role, a feature that now exists. One lookup costs far
less than one confident wrong answer.

This skill is the cheap reflex: confirm one fact before you assert it. It is
not the deep dive. When a whole question needs investigation across several
sources, that is [[deep-research]].

## When to use

Reach for it the moment your answer rests on a **specific, checkable fact that
can change over time**:

- current software version, model id, API shape, or release date
- a price, a fee, a rate, a limit
- who currently holds a role or owns a thing
- whether a product, feature, or support for X exists right now
- any figure the user could catch you getting wrong

If the fact is stable (math, settled history, how a known algorithm works),
you do not need this — answer directly.

## The move

1. **One targeted search** — `web_search` with a precise query for the exact
   fact. Read the `extra_snippets` bullets before deciding you need more.
2. **Crawl the primary source when the number matters** — `web_crawl` the
   official page (vendor site, release notes, the primary party's own page).
   A snippet is lossy; for a price or a version, read the source.
3. **State it with the source** — give the fact and where it came from. If the
   lookup did not settle it, say what you could not confirm rather than
   filling the gap from memory.

Keep it small: one search, maybe one crawl. That is the whole point — this is
a confirm, not a loop.

## When to escalate to deep-research

Hand off to [[deep-research]] when one lookup is not enough:

- the sources disagree and you need to cross-check from a second angle
- the question has several sub-parts, each needing its own sources
- the user asked for a thorough investigation, a comparison, or a report

## Rules

- Never assert a specific current fact from memory when a lookup is cheap and
  the fact could have moved. Search first, then answer.
- Never fabricate a version, price, date, or figure to fill a gap. A plainly
  stated "I could not confirm X" beats a fluent guess.
- Do not hedge with "as of my training" and stop there — that is the exact
  case this skill exists to fix. Look it up.
- Distinguish what a source states from what you inferred. Name the source.
