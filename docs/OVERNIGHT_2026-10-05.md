# Overnight build, 2026-10-05

Owner request (03:40): test everything end to end, measure speed, optimise in
every respect, research comparable agents (Clawdbot/OpenClaw, Grok and the
others), finish the plan, improve the UI, implement what the research shows.
The coordinator only manages subagents. Result expected in the morning.

This file is the log. Each track has a bead; each finished step gets a line
here with the commit.

## Tracks

| # | Track | Bead | State |
|---|-------|------|-------|
| 1 | Voice call without a first message | chuk_chat-bebl | done, not committed yet |
| 2 | Desktop Agents header like mobile, rail "+" menu, Chat-half chips | chuk_chat-98iq | done, not committed yet |
| 3 | VNC / browser fills the virtual display, no black area | chuk_chat-elw7 | done, image rebuilt, host rollout open |
| 4 | Agents turn: 100-180 s in `prepare` before a 3 s model call | chuk_chat-p5xm | fixed (summary cached per session), not committed yet |
| 4b | Compact after the run in the background, cheap aux model, cached_tokens/TTFT columns | cowork-z9mo, chuk_chat-sa7r | in progress |
| 5 | Model/provider/effort settings in one place, clean UI | chuk_chat-2wuc | in progress |
| 6 | Plan vs code gap analysis (speed, context, cost) | — | done (see below) |
| 7 | Competitor research (OpenClaw/Clawdbot, Grok, Manus, Claude Cowork, ChatGPT agent, …) and feature gaps | — | in progress |
| 8 | Repeatable speed test (per-turn timings, before/after) | — | in progress |
| 9 | Implement plan gaps and research findings | — | planned |
| 10 | Full UI audit desktop + mobile with screenshots | — | planned |
| 11 | End-to-end functional tests (chat, agents, browser, voice, files) | — | planned |
| 12 | Host rollout: the host runs from `/home/user/git/agents-merge` (2026-09-23 code); move it to current master | — | planned |

## Measurements

Baseline, session `local:brisk-heron:2:116636868`, prompt "hi" (runs table):

| run | provider | prepare_ms | model_wait_ms | tokens |
|-----|----------|-----------:|--------------:|-------:|
| fdc9da0e | runanywhere/serverless | 105 919 | 3 448 | 33 066 |
| 30000720 | runanywhere/serverless | 177 007 | 3 400 | 33 067 |
| 7b230b50 | fireworks/serverless | 143 354 | 6 013 | 32 718 |

## Plan status (gap analysis, 03:55)

The plan for context and cost is `docs/context-compaction-design.md` (wins on
conflict) plus `docs/AGENTS_AGENT_PLATFORM_PLAN.md` §7.2, §7.3, §7.9, §12.
There is no latency target for Agents turns anywhere. Stale:
`COWORK_AGENT_PLATFORM_PLAN.md` (pre-rename copy); mem0 in the compaction doc
is now Hindsight (`agents/memory/README.md`).

| Plan item | State | Evidence |
|---|---|---|
| Summary does not block the turn (cause of 100-180 s) | in progress | ladder summarises mid-turn with a helper call, `context.py:764-779`; p5xm adds a summary cache |
| Compact after the run while the cache is warm | missing | cowork-z9mo; no post-run hook, `loop.py:590-612` |
| Drop old tool calls/results after ~30 min idle | missing | cowork-z9mo |
| Provider prompt caching | partial | api_server `chat/prompt_cache.py` sets `cache_control` only for Anthropic/Qwen; Agents sets nothing; cowork-g85d |
| Measure cache hits / TTFT per run | missing | no column in `runs` (`state.py:124-130`) |
| Stable prompt head (system prompt frozen per session) | done | `loop.py:27`; stage 2/3 rewrites the middle |
| Ladder stage 1 and 2/3 | done | `context.py:401-402`, fixed 128k, not per model (`runtime.py:382`) |
| Cheap fast helper model for compaction | partial | same model without reasoning, max 512 tokens (`executor.py:3225`) |
| Per-round notes, main model picks full or compact (§2.1) | missing | fixed threshold only |
| Slim tool schemas / tool search | partial | only MCP tools hidden, core tools ~5.6k tokens per call |
| FTS5 history search | done | `search.py:111` |
| Memory recall non-blocking | done | max 250 ms, `memory.py:119` |
| Raw context copy button | done | `loop.py:1254-1276` |

Levers in order: (1) summary out of the turn, (2) host on current code,
(3) prompt caching for real plus cache-hit metrics, (4) smaller prompt
(30-min rule, slim tool schemas), (5) faster helper model.

## Log

- 03:40 plan written; tracks 1-6 running or done.
- 03:55 gap analysis done; research (7) and speed harness (8) started.
- 04:10 p5xm root cause: every task built a new ContextLadder and re-ran a
  synchronous aux summary over a 369k-char slice (~92k tokens). Fix persists the
  summary per session (`context_summaries`). Stub test: prepare 3.1 s -> 40-50 ms
  on runs 2+, same payload. Host has the same bug (agents-merge code identical
  on this path).
- 04:10 rollout plan: point `~/.local/bin/agents-host` at
  `/home/user/git/chuk_chat/agents/host/.venv` (imports this checkout), set
  `AGENTS_SANDBOX_IMAGE=agents-browser:latest` in the unit (it was
  agents-base, so the agent had no browser tools), restart `agents-manager`.
