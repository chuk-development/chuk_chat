# Agents live test, 2026-10-09

The test compares the Agents product with the jobs that the owner gives to
Grok Bot. The test sends real prompts through the desktop app (Xvfb `:77`)
to the coworker `steady-kestrel`. The times come from the host `runs` table
(`agents/bench`, `agents-bench report --fresh --all`).

Model: `z-ai/glm-5.3-flash` on `fireworks/serverless`.

## Speed: "hi"

| Run | Wall | Prepare | Model | Tokens |
|-----|-----:|--------:|------:|-------:|
| 1 (first after idle) | 4.9 s | 7 ms | 3.3 s | 5 601 |
| 2 | 1.7 s | 1 ms | 1.7 s | 5 639 |
| 3 | 3.0 s | 1 ms | 2.9 s | 5 668 |

The model is almost all of the time. Prepare is 1-7 ms.

## Grok Bot jobs

| Job (Grok Bot thread) | Result | Wall | Model calls | Tokens |
|-----------------------|--------|-----:|------------:|-------:|
| Research: news on Sesame CSM, GitHub, Hugging Face, papers ("Voice Mode") | Done, 20 sources, links | 14.0 s | 3 | 22 100 |
| Find 4 official product images, download, one ZIP ("Images Bot") | Done, 415 KB ZIP with 4 images from raspberrypi.com, through the browser past Cloudflare | 91.9 s | 17 | 210 998 |
| Weekly routine, Thursday 09:00 ("Zuerst Update") | Done, first run Thu 15 Oct 09:00 | 16.7 s | 4 | 84 082 |
| Live parcel status on dhl.de ("Paket") | Done, live status read from the page | 9.1 s | 3 | 72 789 |
| Delete the routine again | Done, no routine left | 11.4 s | 4 | 107 098 |
| Research again, as thorough as Grok Bot's daily check (last commit, issues, HF fine-tunes, TurnBench, arXiv of the last 7 days) | Report good while streaming (4 papers of 06.10. with links). The stored answer lost the report. The agent also set up a daily routine that nobody asked for. | 61.0 s | 10 | 314 971 |
| Delete that routine | Done | 9.5 s | 3 | 106 961 |

Not tested: login jobs with stored credentials ("Asterix & Friends") and the
budget review ("Main"). They need the owner's data.

## Result quality compared with Grok Bot

| Job | Grok Bot | Ours |
|-----|----------|------|
| Daily research check | Checks the repository for new commits, TurnBench, HF and new fine-tunes; lists papers with one line each; says clearly "nothing new" per source | First prompt: general news, no commit check. Thorough prompt: same depth as Grok while streaming, but the stored answer keeps only the last pass (bead `chuk_chat-6ze4`) |
| Images to ZIP | Finds variant images across shops, names the shop, price and stock | 4 official images in a ZIP, sources named; one source only |
| Weekly routine | Runs as a routine with its own thread | Set up and deleted on request; first-run date right for the weekly one, wrong weekday for the daily one (bead `chuk_chat-gaep`) |
| Parcel live check | Live check at the carrier | Live status read from dhl.de |

## Findings

- The first four jobs succeed. The thorough research job fails in the end:
  its report is lost. Wall times are good.
- The research answer is shallower than Grok Bot's. It did not check commit
  dates in the repository.
- Tokens per turn grow fast with the history: a one-line follow-up costs
  73k-107k tokens after a few jobs. See bead `cowork-g7oc`.
- The DHL answer contained a Chinese word ("物流") in German text. Bead
  `chuk_chat-l8eg`.
- A read-only browser job showed "2 files changed · Undo". Bead
  `chuk_chat-vo8k`.
- The final answer drops the report text of earlier passes. Bead
  `chuk_chat-6ze4` (P1).
- The agent creates a routine nobody asked for, after a prompt that starts
  with "Daily ... check". Bead `chuk_chat-2l0v` (P1).
- Wrong weekday: "tomorrow, Friday 9 October" on Friday 9 October. Bead
  `chuk_chat-gaep`.
- While streaming, the texts of two passes glue into one huge heading. Bead
  `chuk_chat-qcdt`.
- The Grok Bot jobs "Asterix & Friends login" and "Main budget" are not
  tested. Their prompts are only in Grok Bot's private local data.
