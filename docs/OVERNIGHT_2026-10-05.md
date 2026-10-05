# Overnight build, 2026-10-05

Owner request (03:40): test everything end to end, measure speed, optimise in
every respect, research comparable agents (Clawdbot/OpenClaw, Grok and the
others), finish the plan, improve the UI, implement what the research shows.
The coordinator only manages subagents. Result expected in the morning.

This file is the log. Each track has a bead; each finished step gets a line
here with the commit.

## Summary for the owner (12:15)

**Speed.** A "hi" to a coworker took 110-185 s and about €0.002. It now
takes **1.4-2.0 s** warm and **€0.00016** (prompt 20k -> 8k tokens, 99 %
of it from the provider cache). The causes were: a context summary re-made before every
turn (100-180 s), a tool list that changed between requests (no cache
hits), five MCP connectors dialed one after another (8.5 s), a memory
recall that waited for its 1.5 s timeout, Chromium and docker work at
every task start, and a summary window that slid every turn (cache misses).
All fixed and measured on the real host.

**Host.** Runs from this checkout now (`~/.local/bin/agents-host` ->
`agents/host/.venv`, unit uses `agents-browser:latest`, `AGENTS_TRACE=1`
in `~/.config/chuk-agents/host.env`). Backups of the old wrapper and unit:
`_scratch/host-rollout/`.

**Built (host + app, tested, reviewed, pushed in batches):**
- Voice call without a first message; desktop header like the phone;
  "+" menu; Chat-half chips.
- VNC/browser fills the display (no black area); takeover card for
  login/2FA/CAPTCHA with auto-resolve; live turn status (Sending, Preparing,
  Thinking, tool, Writing; offline with Retry).
- One place for a coworker's model, provider and reasoning, with prices.
- Per-action approvals (once / always for this agent / per site).
- Cost per answer, totals, weekly budget with warning and stop.
- Automations: watch a page, mail filter, notify only on change.
- Telegram channel per coworker (opt-in, not E2E, pairing code).
- 15 coworker templates in New agent.
- Save a successful task as a skill (only on approval).
- "N files changed · Undo" per answer with conflict handling.
- Own browser via the extension (broker, approvals, Stop, secrets hidden).
- UI audit fixes: readable text on accent fills (your orange theme
  unchanged), German, no truncation at 360 px, icons, DESIGN.md aligned.
- Isolated end-to-end test of the host (13 flows) and a speed bench.

**Needs you:**
- Unlock the screen and look at the app (I tested on a private Xvfb
  display because the screen was locked).
- The own-browser add-on is not tested in a real Chrome yet: steps in
  `docs/RUNBOOK_2026-09-08_USER_BROWSER.md`.
- Telegram is tested only against a fake Bot API; a real bot token test is
  open.
- `chukdoo-web.service` (another project) restarts every 3 s (CHDIR:
  working directory missing). Not touched.

Research: `docs/research/AGENT_COMPETITORS_2026-10.md` ("Grogbot" = Grok
Bot). UI audit: `docs/UI_AUDIT_2026-10-05.md`.

## Tracks

| # | Track | Bead | State |
|---|-------|------|-------|
| 1 | Voice call without a first message | chuk_chat-bebl | done, not committed yet |
| 2 | Desktop Agents header like mobile, rail "+" menu, Chat-half chips | chuk_chat-98iq | done, not committed yet |
| 3 | VNC / browser fills the virtual display, no black area | chuk_chat-elw7 | done, image rebuilt, host rollout open |
| 4 | Agents turn: 100-180 s in `prepare` before a 3 s model call | chuk_chat-p5xm | fixed (summary cached per session), not committed yet |
| 4b | Compact after the run in the background, cheap aux model, cached_tokens/TTFT columns | cowork-z9mo, chuk_chat-sa7r | done, committing |
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

After the rollout (08:36, real host, same session, prompt "hi"):

| run | provider | prepare_ms | model_wait_ms | first_token_ms | tokens | cost | wall |
|-----|----------|-----------:|--------------:|---------------:|-------:|-----:|-----:|
| first after host restart | runanywhere/serverless | 31 | 2 689 | 2 501 | 26 373 | €0.0027 | 13.6 s |
| warm | runanywhere/serverless | 41 | 2 029 | 1 695 | 20 076 | €0.0020 | 3.6 s |

After the caching fix, the lazy box browser and a host restart (09:36,
AGENTS_TRACE=1 in ~/.config/chuk-agents/host.env):

| run | prepare_ms | model_wait_ms | first_token_ms | tokens | cached | cost | wall |
|-----|-----------:|--------------:|---------------:|-------:|-------:|-----:|-----:|
| first after restart | 33 | 1 962 | 1 835 | 20 267 | 20 224 | €0.00041 | 11.4 s |
| warm | 29 | 1 735 | 1 648 | 20 275 | 20 224 | €0.00041 | 3.7 s |

A "hi" went from ~110-185 s to 3.7 s and from ~€0.0020 to €0.0004.

After parallel connectors with a cached tool list and non-blocking recall
(10:30, host log timing lines):

| run | pre-run | mcp | recall | model (first token) | cached | cost | wall |
|-----|--------:|----:|-------:|--------------------:|-------:|-----:|-----:|
| first after restart (tool lists not cached yet) | 4 820 ms | 4 648 ms | 0 | 2 225 (2 141) ms | 0 | €0.0020 | 7.2 s |
| warm | 306 ms | 171 ms | 0 | 2 384 (2 281) ms | 20 224 | €0.0004 | 2.8 s |

At that point a "hi" took 2.8 s, almost all of it the model.

After the docker-free pre-run and the summary-window fix (14:20):

| turn | pre-run | tokens | cached | cost | wall |
|------|--------:|-------:|-------:|-----:|-----:|
| first after restart | 150 ms | 7 967 | 0 | €0.0008 | 3.0 s |
| warm | 39 ms | 7 983 | 7 936 | €0.00016 | 1.4-2.0 s |

The summary-window fix (chuk_chat-b61u) restored the cache hits and cut the
prompt from 20.3k to 8.0k tokens. A warm "hi" now takes 1.4-2.0 s.

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
- 04:25 local commits 060a5633 (header + voice), 49b9a303 (VNC), ddbcd477
  (summary per session), 727c5bd3 (docs), 79444b56 (speed bench). Full
  flutter test: all green; the only failures were the flutter_tester load
  flake ("Invalid WebSocket upgrade request"), every such file passes alone.
  Push waits for the merge with origin/master (agent mail commits overlap the
  settings agent's files) and for CodeRabbit (free quota resets ~04:45).
- 04:25 research done: "Grogbot" = Grok Bot (xAI). Started: baseline prompt
  cut (item 2), instant status line + takeover card (items 4, 6).
- 04:30 baseline prompt cut (chuk_chat-b3g4): fresh coworker 12.7k -> 6.6k
  est. tokens (tools 64 -> 27 declared, Playwright and other non-core tools
  behind search_tools, persona/recall/skills catalogue capped). Long session
  43.7k -> 37.6k; the rest is the ladder tail (~31k). Warning forwarded to the
  z9mo agent: its idle-drop rule raised that history to 48.7k (tier 2 stops);
  it now also drops old recall/automation rows, caps the tail and dispatches
  deferred tools. Commit waits for z9mo (shared memory.py).
- 04:30 started: opt-in Telegram channel per coworker (research item 11).
- 04:50 Telegram channel host side done (chuk_chat-02s5): channels/ subpackage,
  token in its own AES-GCM file (not the sandbox-visible vault), long polling,
  6-digit pairing code, strangers refused, runs in the coworker's one session,
  HTML replies with scrubbing, files as photo/document. Host suite 520 green.
  Pending: executor.py dispatch patch (agent_channel_get/set, MCP for telegram
  origin) after the z9mo agent; app toggle in agent_control_panel.dart after
  the settings agent. Frames are in the bead notes.
- 05:05 z9mo/sa7r done. The turn never waits for a summary (background job
  per session, plan_ahead after each run, one blocking call only above 90 % of
  the budget). Idle rule (30 min) drops old tool rows; old recall/automation
  rows dropped; tail capped at 10k tokens; deferred tools dispatch when the
  model calls them unsearched. Aux model: deepseek-v4-flash, reasoning off
  (`AGENTS_MODEL_AUX*`). runs table: cached_tokens, first_token_ms.
  Stub e2e prepare_ms: old blocking 5188 -> 76 (first turn), 94 (job running),
  56 (after job), 139 (after plan_ahead). Long session input ~54.5k -> 15.2k.
  Executor patch for Telegram frames applied by the coordinator.
- 05:50 local commits since 04:25: e061cab7 (background summaries + half
  prompt), 5fbfa300 (Telegram host side), c127c13e (coworker model page),
  3ce04fab (live status + takeover card, app side), 5a3fa294 (merge
  origin/master: agent mail; conflicts in executor.py/host.py resolved,
  both Telegram and mail kept). Python suites: runtime, executor 278,
  host 550, config 84, sandbox 159, bench green. Verified on screen (Xvfb :77,
  the real screen is locked): desktop header, "+" menu, Chat-half chips,
  profile Model row, coworker model page with provider list.
- 05:50 the screen is locked, so the app now runs on a private Xvfb display
  (:77, same single instance and login). A post-merge test run was killed by
  the low-memory reaper (another session's chukphoto worker at 11.5 GB).
- 05:50 started: host side of takeover + heartbeat.phase. New bug
  chuk_chat-89vl (profile says the coworker does not run on the host).
- 06:40 full flutter test on the committed state: green (78 files hit the
  load flake, all 78 pass alone). d0c28ec3 host side of takeover + phases.
  CodeRabbit on the 11 local commits: 10 findings (1 major: Telegram store
  save race could wipe tokens; takeover URL persisted; no Skip on the card;
  summary CAS; bench copy perms; http for Telegram base; l10n; docs). A fix
  agent works on all 10; push after that. Started: per-action approvals
  (host side).
- 07:20 committed: c54fc394 per-action approvals (host), 720a9e7b takeover
  Skip + no URL in transcript, b6e42e8a Telegram switch + truthful host
  status + stuck-stream fix. CodeRabbit round 2 on the new commits: 7
  findings (major: push text named the browsing site; approved+deny scope
  still approved). Fix agent running.
- 07:20 UI audit done: docs/UI_AUDIT_2026-10-05.md, 62 shots in
  _scratch/ui-audit/shots. Top issues: text on accent fills unreadable in the
  default (pastel) theme, takeover card covers messages on desktop, empty room
  hint looks like a sent message, model page can spin forever, German missing
  on Agents surfaces, truncation at 360 px / 1.3, mixed icon styles, DESIGN.md
  vs AGENTS_UI_UNIFY.md conflicts. Contrast fix uses a < 2:1 threshold so the
  owner's orange theme with white text stays as it is.
- 07:50 committed: db41ad96 (Telegram/takeover review fixes), b5d94164 (cost
  per run + weekly budgets + push texts without site + deny scope never
  approves). Python: executor 319, host 585, config 84, runtime green.
  Flutter full suite on b6e42e8a green (120 load-flake files pass alone).
  CodeRabbit round 3 on the last two commits: 4 minor/trivial (budget check
  before restricted mail, roster reads per budget check, replay N+1 query,
  takeover decision with an unpaired controller) -> fixes running. UI fix
  agents A (contrast, icons, German, DESIGN.md) and B (takeover placement,
  empty room, model page timeout, truncation) running.
- 08:30 committed: 2313f773 (budget review fixes), 299e6893 (UI audit fixes
  A+B), a5e4d232 (automation triggers: watch_url, mail filter, notify
  on_change), 865b3e7d (inbox goldens), f0d70b77 (test fake). Verified in the
  real app on Xvfb: the owner's orange theme keeps white text; host row reads
  "Your computer". Flutter full suite green after the golden update and the
  fake fix. CodeRabbit: rounds 1-4 clean; automations commit had 2 findings
  (SSRF via DNS rebinding in url_watch, automation finish on failure paths)
  -> fix agent. Push waits for that fix.
- 08:30 started: app side F1 (approval card + settings, cost meta line,
  budget notices) and F2 (automations UI, cost totals + weekly budget).
- 08:40 pushed 24 commits (122d5040..f63dd295). Host rollout done:
  ~/.local/bin/agents-host now runs /home/user/git/chuk_chat/agents/host/.venv
  (this checkout), the unit uses AGENTS_SANDBOX_IMAGE=agents-browser:latest
  ("browser ready"). Backups of the old wrapper and unit:
  _scratch/host-rollout/. Measured on the real host (table above).
  Beads closed: p5xm z9mo sa7r b3g4 elw7 oohr bebl 98iq 2wuc 89vl nof4 au9j
  yir9 rx6i 2ucn.
- 09:00 prompt caching (cowork-g85d): the API passes cached_tokens through
  (PostHog shows hits); the breaks were ours: the tool list changed when a
  found tool fell out with the compacted search, and old recall rows were
  dropped mid-conversation. Fixed in 00fba461; expected 60-80 % cache hits
  (was 13 %), ~75 % less prompt cost, 0.6-1 s faster first token. Needs a
  host restart to measure live; waits for the templates agent (host.py is
  mid-edit in the working tree). Unexplained: run 2 at 08:37 had 0 hits
  (bead chuk_chat-h7w6). F2 (automations UI, cost totals, weekly budget)
  done, commits with F1. Running: F1, E2E on an isolated host, coworker
  templates.
- Side note: chukdoo-web.service (another project) restarts every 3 s,
  35,900+ restarts, CHDIR: working directory missing. Not touched.
- 09:45 committed: 12e25478 (isolated e2e flows: 9/9 flows pass, 3 bugs
  filed: wrdv second thread gets no browser, 3oh6 approved unsearched
  deferred tool refused, 0b7i budget_warning agent_id), 85ea8104 (templates
  host), 1578fc49 (app side: approval card + settings, cost line + sheet,
  budget notices, automations editor, cost totals + weekly budget, 15
  coworker templates). Pushed 00fba461/efdb3078 earlier (caching, audit doc).
- 09:45 live (host still on 08:35 code): "hi" 25.9 s wall = prepare 0.8 +
  recall 1.6 + model 4.4 + ~19 s unattributed. The 19 s are the eager
  Playwright connect per task (bug wrdv, fix running: one lazy browser per
  box). Cost line shows live ("< €0.01 · 20.1k tokens").
- Xvfb note: :77 got taken over by another session's Xvfb; a plain Xvfb hung
  in the NVIDIA driver (os_acquire_rwlock_write, GPU busy with other
  sessions' ML workers). Working setup: Xvfb :82 and the app with
  __GLX_VENDOR_LIBRARY_NAME=mesa, __EGL_VENDOR_LIBRARY_FILENAMES=.../50_mesa.json,
  LIBGL_ALWAYS_SOFTWARE=1. A hung Xvfb :78 (state D) is left; it cannot be
  killed until the driver lock frees.
- 09:40 committed 19de324b (one lazy browser per box, approved unsearched
  calls run, budget agent id; e2e 13/13) and ca194d32 (save a task as a
  skill, host side). Host restarted twice; cache hits now 99.8 % of the
  prompt. Trace: warm run spends 1.5 s in memory recall (timeout), cold run
  ~9 s before agent_run in the executor -> profiling agent started.
- 10:30 committed e974a745 (skill save claim, browser tool cache), fa296ba1
  (parallel MCP connectors from a cached tool list, non-blocking recall,
  sidecar warm start, pre-run tracing), 56f597ac (skill proposal card in the
  app + app review fixes). Live: warm "hi" 2.8 s.
- 11:00 pushed efdb3078..69831b3b (12 commits: e2e flows, templates, app
  side for approvals/cost/budget/automations/templates, lazy box browser,
  skill proposals host + app card, parallel connectors + non-blocking
  recall, review fixes, ordered host frames, MCP SDK v2 hints). Flutter
  suite green, CodeRabbit clean on every batch. Beads closed: dsh0 mxxm
  baa3 hn3m al2u 4xc5 s3y2 qcbv 02s5 1pnz b95f g85d (plus 9i41 ev7v cfsd
  h7w6 by the cleanup agent). Running: run timeline with undo (host), app
  polish (cache cost line, phone permissions, WIRE_CONTRACT status).
- 12:20 pushed 69831b3b..8155b997 (timeline host + app, own-browser bridge +
  follow-ups, polish, review fixes, summary). Host restarted on the pushed
  code (broker running). Control: warm "hi" 2.3 s / €0.0004 (cached
  20 288); first after restart 6.0 s, of which mcp 3.0 s (bead filed: the
  tool cache should make this near 0). Running: own-browser app side.
- 12:45 pushed 8155b997..1fa2a447 (own browser in the app). Verified in the
  real app (Xvfb :82): New agent template picker, cost line under every
  answer ("< €0.01 · 20.3k tokens"), profile "Runs on the host: Yes",
  "Your browser: Not set up on this computer", Approvals section. Running:
  MCP cold start after a host restart (bead l16i).
- 13:00 76cb2580: two of the five forwarded MCP connectors fail every
  handshake (which ones is not stored on the host: check them in the app,
  they deliver no tools). The tool cache now remembers failures, so a
  restart no longer waits ~3 s for them; the marks were written at 12:57.
  Remaining first-turn cost ~650 ms is docker work for the box (bead filed
  by the agent).
- 13:30 pushed 1fa2a447..6e3ee000 (failing connectors cached, Allow again
  from the app, per-thread browser target, review fixes). After a host
  restart the first "hi" has pre-run 1.56 s (was 3.4 s); warm 2.3 s.
  Running: docker work out of the pre-run path (bead 5o8j).
- 14:05 47e0c356 (no docker before the first model call) live after a
  restart: pre-run 150 ms first turn, 39 ms warm (was 1.56 s / 0.3 s). But
  cached_tokens fell to 0 on both turns (was 20 224 at 10:30): a prefix
  regression from a later change; an agent is on it. Not pushed yet
  (CodeRabbit quota).
