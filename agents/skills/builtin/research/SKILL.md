---
name: research
description: Thorough, source-checked research. Use for news, "what is new at X", a check of a project, model or topic, release and paper monitoring. Reads each primary source directly (GitHub, Hugging Face, arXiv, official pages) with dates, links and "nothing new" per source.
metadata:
  version: "1.3"
---

# Research: check each source yourself

A search snippet is not a source. Read each primary source directly, compare
its dates with a time window, give a link for each claim. Do not stop after
one search. Call the reads of independent sources in the same round.

## 1. Window and sources

- Today comes from the `[clock]` note. "today" or a daily check: the last
  24 hours. "this week" or a weekly check: the last 7 days. "new" without a
  time: the last 7 days. Write the window with dates into the answer.
- Check the premise first: does the product, project or series exist under
  the name the user gives? A wrong name is the first thing to say, then
  research the right one.
- Take every source the user names, plus the obvious primary sources: the
  repository, the model page, the paper search, the benchmark or leaderboard,
  the official blog. Find an unknown URL with ONE `web_search`.

## 2. Recipes (`fields` keeps JSON short)

GitHub (no key, 60 calls per hour):

```text
web_fetch("https://api.github.com/repos/OWNER/REPO/commits?since=2026-10-02T00:00:00Z&per_page=30", fields=["commit.author.date","commit.message","html_url"])
web_fetch("https://api.github.com/repos/OWNER/REPO/issues?since=2026-10-02T00:00:00Z&state=all&per_page=50", fields=["number","title","state","created_at","closed_at","comments","html_url","pull_request.merged_at"])
web_fetch("https://api.github.com/repos/OWNER/REPO/releases?per_page=5", fields=["tag_name","published_at","html_url"])
```

- No commit in the window: read `commits?per_page=1` for the date of the last one.
- `issues?since=` gives every issue and pull request UPDATED in the window:
  new, closed, merged or commented. An old PR closed in the window is news
  ("PR #121 from March 2025 closed on 04.10. without merge").
- Rate limit (403): read `https://github.com/OWNER/REPO/commits.atom`.

Hugging Face (no key):

```text
web_fetch("https://huggingface.co/api/models/ORG/MODEL", fields=["lastModified","createdAt","downloads"])
web_fetch("https://huggingface.co/api/models?filter=base_model:ORG/MODEL&sort=createdAt&direction=-1&limit=20", fields=["id","createdAt","lastModified"])
web_fetch("https://huggingface.co/ORG/MODEL/raw/main/README.md", max_chars=3000)
```

- `filter=base_model:` gives fine-tunes, quantizations and adapters. New
  means `createdAt` in the window.
- Never guess what a model, repository or paper is from its name. Read its
  README, model card or abstract first. Say what it says (a copy, a
  fine-tune on which data, which language). No card: say "no model card".

arXiv: ONE query with all terms joined by OR and the window as a
submission-date range. Put in every name and synonym (with and without a
hyphen, short and long form):

```text
web_fetch("https://export.arxiv.org/api/query?search_query=(all:%22full-duplex%22+OR+all:%22full+duplex%22+OR+all:%22duplex+speech%22+OR+all:%22spoken+dialogue%22+OR+all:%22conversational+TTS%22+OR+all:%22conversational+text-to-speech%22+OR+all:%22turn-taking%22+OR+all:%22speech+language+model%22+OR+all:%22voice+agent%22)+AND+submittedDate:[202610020000+TO+202610092359]&sortBy=submittedDate&sortOrder=descending&max_results=100")
```

- "N entries of M results" with M > N: read the next page (`&start=100`).
- Read every title. Keep the papers on the topic, drop the others (radio
  "full-duplex" papers in a speech question) and say how many you dropped.

Leaderboards and benchmarks:

- Never take a date from the overview: a new entry at rank 1 looks like an
  old one. You need the submission date of each top entry.
- Step 1, one call: search the page and its script files for the data:

```text
web_fetch("https://turnbench.sesame.com/", grep="submitted", scripts=true)
```

  Each snippet shows one entry with its id and date, for example
  `model:"turn-1-mini",...,submitted:"2026-10-05"`. Use one or two words the
  data uses (`submitted`, `date`, `created`), not a long list.
- Step 2, when step 1 shows no dates: open the detail pages of the top three
  entries and of each entry you do not know, in the same round:
  `web_fetch("https://turnbench.sesame.com/models/turn-1-mini")` ("Submitted
  October 5, 2026 by p99lab"). The id is in the snippets, or it is the name
  in lower case with hyphens.
- No date found after both steps: write "date not readable", never
  "nothing new".

Other pages: `web_fetch`, look for dates. A bot check or an empty page: the
browser and one `browser_evaluate`. News coverage: `web_search` with
`freshness` ("pw" week).

## 3. Check, then answer

- Each date compared with the window. Each claim with a link. Each source
  with a result, also "nothing new". Each description from a card, README or
  abstract, not from a name.
- One block per source, short lines, in the user's language:

```markdown
Zeitraum: 02.10.–09.10.2026

**GitHub SesameAILabs/csm**: keine neuen Commits (letzter 27.05.2025, [Link](...)). PR [#121](...) am 04.10. ohne Merge geschlossen.
**Hugging Face sesame/csm-1b**: unverändert seit 01.12.2025. Neu: [vnbot-ai/csm-1b](...) (03.10.), laut README eine Kopie für VNBot, kein Training.
**TurnBench**: neuer Eintrag [p99lab turn-1-mini](...), eingereicht 05.10., Rang 1.
**Papers (arXiv)**:
- 06.10. [Titel](https://arxiv.org/abs/...) – ein Satz, worum es geht.
```

- Before you send, read the answer again, line by line. Every word in the
  user's language (no "seven" in German, no Chinese characters), grammar
  right ("eine ruhige Woche", not "ein ruhige"). Names and titles stay.
- Do not create a routine for a daily check. You may offer one in one
  sentence at the end.
