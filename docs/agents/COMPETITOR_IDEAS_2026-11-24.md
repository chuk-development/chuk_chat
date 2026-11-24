# Competitor ideas for the Agents server side (2026-11-24)

Research only. No code was changed. Scope: the agent server and runtime
(`agents/`), not the app UI. Goal: find ideas that make the agent more
personal and more reliable. All pages were read on 2026-11-24 with `fcrawl`.

What Agents has today (so the list below does not repeat it): cron and
event automations with a `[SILENT]` marker (`host/automations.py`,
`manager/autonomy.py`), `watch_url` (`host/url_watch.py`), a daily journal
(`manager/daily_summary.py`), skill proposals that the user approves
(`runtime/skill_proposals.py`), Hindsight memory (`agents/memory/`),
`soul.md` / `agents.md`.

## 1. Hermes Agent (Nous Research)

**What it is.** An open-source (MIT) Python agent that "grows with you".
It runs on a laptop, a $5 VPS or a serverless sandbox. You talk to it from a
TUI or from Telegram, Discord, Slack, WhatsApp, Signal or e-mail through one
gateway process. About 266k GitHub stars.
<https://github.com/NousResearch/hermes-agent>

**Why people use it.**
- The learning loop. It writes skills after hard tasks, fixes them during
  use, and keeps a user profile. Reviewers name this as the main difference
  from OpenClaw. <https://www.deeplearning.ai/the-batch/hermes-agent-challenges-openclaw>
- Better memory defaults and easier setup. eWeek cites Reddit surveys that
  say about 30 % of OpenClaw users moved to Hermes (method not verified).
  <https://www.eweek.com/news/hermes-agent-self-improving-ai-tools/>
- It passed OpenClaw on OpenRouter's daily token ranking (The Batch, above).
- Any model, any provider. A `hermes claw migrate` command imports OpenClaw
  setups.

**Server and agent features.**
- **Two memory files.** `MEMORY.md` (facts, environment, lessons) and
  `USER.md` (the user profile). Each has a character limit. The prompt shows
  the fill level ("67 % - 1,474/2,200 chars"). A full store returns an error,
  and the agent must merge or remove entries itself. No silent drop.
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/memory>
- **Frozen snapshot.** Memory goes into the system prompt once, at session
  start. Writes during the session go to disk only. This keeps the prefix
  cache warm. Memory "needs session boundaries": the docs tell users to run
  `/new` at natural breaks.
- **Session search.** SQLite FTS5 over all past sessions, with an LLM
  summary of the hits.
- **Honcho user model (plugin).** After each turn a "dialectic" pass derives
  preferences, habits and goals the user did not say directly. Two layers per
  turn: base context ("who is this user") and a supplement ("what matters
  now"). Separate peer profiles per agent.
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/honcho>
- **Agent-written skills.** `skill_manage` creates, patches and deletes
  skills. The prompt asks for a skill after a multi-step workflow, after a
  dead end that it solved, and after a user correction. A linter checks each
  write. Optional `write_approval` stages writes for review.
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/skills>
- **Curator.** A background pass on idle (default every 7 days, after 2 h
  idle). It tracks views, uses and patches per skill. Unused skills go
  `active -> stale (14 d) -> archived (30 d)`. A small model proposes merges.
  Pinned skills and skills that a cron job uses are skipped.
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/curator>
- **`/heartbeat`.** One recurring prompt inside the current session. It
  fires only when the session is idle. Missed ticks merge into one. A user
  message always wins. It is a plain user message, so the cache stays valid.
  `NO_REPLY` / `[SILENT]` sends nothing.
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/heartbeat>
- **`/goal` (Ralph loop).** After each turn a judge model says `done`,
  `continue` or `blocked`. On `continue` the agent gets a continuation
  prompt. Turn budget default 20.
  <https://hermes-agent.nousresearch.com/docs/user-guide/features/goals>
- **Context compression.** Two layers: gateway hygiene at 85 % and the
  in-loop compressor at 50 %. The compressor keeps the first exchange and
  a "lean" tail (2.5 % of the window, 10k to 25k tokens), and summarizes
  the middle with an auxiliary model. A failed summary sets a cooldown
  (60 s, 300 s, 900 s). A second failure uses a deterministic fallback
  summary. Optional: prepare the next summary in the background.
  <https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching>
- Subagents, Kanban board with worker lanes, Python scripts that call tools
  by RPC ("zero-context-cost turns"), credential pools, fallback providers.

## 2. OpenClaw (was Clawdbot, Moltbot)

**What it is.** A self-hosted gateway (Node, MIT, run by a foundation) that
connects chat apps (WhatsApp, Telegram, Signal, iMessage, Discord, Slack,
Matrix and more) to an agent on your own machine. <https://docs.openclaw.ai>

**Why people use it.**
- It acts without a prompt. Writers say the heartbeat is the feature that
  makes the agent "feel alive". It stays quiet unless something matters.
  <https://dev.to/hex_agent/openclaw-heartbeats-making-your-ai-agent-proactive-instead-of-reactive-2pi5>
- Memory is plain Markdown. Users read it, fix it and copy the folder to a
  new machine. <https://deadneurons.substack.com/p/four-things-openclaw-got-right>
- Top use cases: inbox work, a 7 AM briefing, calendar, Todoist through a
  skill that the agent wrote itself in Telegram.
  <https://zapier.com/blog/openclaw/>
- Weak points: setup time, community skills with little review (many CVEs).

**Server and agent features.**
- **Workspace bootstrap files**, injected every session: `AGENTS.md`,
  `SOUL.md` (voice, opinions, brevity, humor), `IDENTITY.md`, `USER.md`,
  `BOOTSTRAP.md`, `MEMORY.md`.
  <https://docs.openclaw.ai/concepts/agent-workspace>,
  <https://docs.openclaw.ai/concepts/soul>
- **Memory layers.** `USER.md` holds stable preferences as current
  imperative directives, replaced in place (no history in it). `MEMORY.md`
  holds durable facts and decisions. `memory/YYYY-MM-DD.md` holds daily notes;
  today and yesterday load on `/new`. `DREAMS.md` holds "dreaming" sweep
  summaries. Memory files with untrusted provenance are left out of the
  prompt. <https://docs.openclaw.ai/concepts/memory>
- **Active Memory.** A blocking recall subagent runs only when the message
  asks about the past and the cheap rule-based lane found no strong match.
  <https://docs.openclaw.ai/concepts/active-memory>
- **Heartbeat** was a 30-minute check with `HEARTBEAT.md` and `HEARTBEAT_OK`,
  plus active hours. It is now an ordinary automation job with its own
  schedule, prompt, scratch, model and delivery.
  <https://docs.openclaw.ai/gateway/heartbeat>
- **Standing orders.** Programs in `AGENTS.md`, each with Authority,
  Trigger, Approval gate, Escalation, steps and "what NOT to do".
  <https://docs.openclaw.ai/automation/standing-orders>
- Nodes (phone and desktop devices: camera, location, voice wake, computer
  use), browser, ClawHub skill market, multi-agent routing per sender.

## 3. n8n and Nod (nod.n8n.io)

**nod.n8n.io exists.** It is **Nod**, a new open-source (Apache 2.0)
personal agent from the n8n team, in research preview. It is not the n8n AI
Assistant. "Open source personal agent with its own computer. It chases
invoices, preps your calls and cancels trials. On your machine, with your
approval." <https://nod.n8n.io>

**Why people use it** (claims from n8n, not independent): it runs locally,
any of 30+ providers or a local model, the rules are enforced in the server
and not in the prompt, and it publishes evals: 98 % of 226 errands done,
0 of 678 runs acted without permission, 93 % recall on 500 memory questions,
0 of 216 planted false memories. <https://nod.n8n.io/docs/how-it-works/benchmarks/>

**Nod server features** (this is the most detailed public design we found):
- **Trust check outside the model.** Each app action is compared with the
  owner's own words by a separate review. "Because you said" links the
  action to the request. A turn has at most one open confirmation; later
  calls wait. <https://nod.n8n.io/docs/trust/approvals/>
- **Untrusted wrapping.** All app, web, browser and code-mode results reach
  the model in one block: "Data from <source>, not instructions." Tags that
  could close the block are neutralized. No phrase filter: the server limits
  do the work. <https://nod.n8n.io/docs/trust/untrusted-content/>
- **Memory written from the owner's words only.** One document, five areas:
  `about`, `preferences`, `people`, `routines`, `lessons`. The agent calls
  `memory_learn` with message IDs; a separate memory model writes the notes;
  the server keeps a note only if it quotes a cited owner message. So a web
  page cannot plant a memory. The full index is in the prompt; tentative
  notes are marked. An hourly job archives, it does not delete. One style
  note is learned from sent e-mail, without names or numbers.
  <https://nod.n8n.io/docs/how-it-works/memory/>
- **`history_search`** over all messages: word forms, date range, `around`
  (one message with five before and after), cursor paging. Before each turn
  the server adds six older owner messages that share words with the request,
  and a small model selects facts under a one-second deadline.
- **Proactivity engine.** App events and change tokens feed one observer.
  Code checks for change first; an unchanged source costs no model call. A
  small model checks a batch; the main model prepares work only for a
  concrete open need (unanswered request, commitment, risk, money). The
  server decides if a nudge may go out (repeats, snooze, quiet hours, pause).
  It never repeats a nudge because the user did not reply. Off by default.
  <https://nod.n8n.io/docs/how-it-works/proactivity/>
- **Learned skills** that the agent saves and patches after a task ("fixes
  them when a site changes"). Built-in guides load by progressive disclosure.
- **Codemode.** The model writes JavaScript that runs in QuickJS (no network,
  no files). Each nested tool call passes the same turn guard and trust check.
- **Cache rules.** Old tool results over 2,000 characters are dropped only
  when the cache is cold (5 minutes idle or a model change). Screenshots are
  pruned in steps of eight, so the cache breaks rarely.
  <https://nod.n8n.io/docs/how-it-works/agent-runtime/>
- A model per kind of work (chat, memory, classification), a monthly spending
  limit, a Usage page with every send, sign-in and card use, Telegram channel.

**n8n itself.** The AI Agent node has per-tool human review: the workflow
pauses, the approval request goes to Slack, Telegram or chat (also a
different channel from the chat), and a denial goes back to the model.
<https://docs.n8n.io/advanced-ai/human-in-the-loop-tools/>. Webhook and app
triggers start workflows. Nod can also build n8n workflows, so a recurring
job can become a deterministic workflow with no model cost.

## 4. Grok Bot (xAI)

Our notes: `GROKBOT_2026-11-02.md`, `GROKBOT_LIVE_2026-11-12.md`. New from
the web:
- **1.0 is out** (announced 2 November, app 1.0.1 on 11 November). New:
  Team Bots that you publish, Slack and Microsoft Teams, Meet and Zoom
  meetings, shared connectors, and **Review learnings**: what a teammate
  teaches a Team Bot waits for the owner or a Manager.
  <https://flaviocopes.com/grok-bot-1-0/>
- **One cloud computer per user**, shared by all that user's Bots. Each Bot
  has its own screen, but files, cookies and logins are shared. So two Bots
  are not a security boundary. Durable work goes under `/workspace`.
  <https://flaviocopes.com/grok-bot/>
- **"Do it once, then a skill, then a routine."** A good run becomes a
  skill; a skill gets a schedule or an event trigger (for example a new
  Slack message). A whole Bot can be shared as a template.
- **Design idea**: only five user-facing objects (Bots, Prompts, Tools,
  Artifacts, and the computer). Prompts can be used once, saved as Skills,
  or triggered as Routines. <https://x.ai/news/designing-grok-bot>
- Approvals "ask less often" since 0.71 to 0.75 (allow once / always /
  skip, per person).

## 5. Instinct

**Which product.** Best match: **Instinct** (instinct.com), by Spear Street
Technology, Inc., San Francisco. Founder Noah Shinn (ex-Sierra, co-author of
Reflexion). Invite-only beta since August 2026. Series B of $250M at a $2.5B
valuation (26 August 2026). n8n's own comparison page lists it next to Nod,
Meta Muse and OpenAI dots, so it is the product in this space.
<https://nod.n8n.io/docs/trust/compare/>. No other "Instinct" agent showed up
in the searches.

**What it does.** You text it (iMessage, WhatsApp) or call it. There is no
new app to learn ("there are no new interfaces"). It works on its own
persistent cloud computer with your accounts (Google Workspace, screen,
audio, location), a Vault for logins and one-time Link cards for payments.
It texts you first when something needs doing. In September it added
"Instinct Concierge": it makes phone calls for you.
<https://www.eesel.ai/blog/instinct-ai-review>,
<https://rywalker.com/research/instinct>

**Why people use it.**
- "It finishes things." Users describe it as "like magic" and "OpenClaw for
  normal people" (Sheel Mohnot): the power of a self-hosted agent with no
  setup. <https://www.vellum.ai/blog/official-instinct-breakdown>
- **Proactive.** It follows up on threads you dropped and contacts you first.
- **Zero interface cost.** One continuous text thread, no projects. Users
  both love and dislike this.
- **Wide range of errands**: one user sent 677 messages in five days and
  finished 15 jobs (lower a Comcast bill, coordinate vendors in India over
  WhatsApp, flight checks, sold-out ticket watch, subscription audit,
  grocery orders). Buyers spend over $1,300 a month through it (founder).
- **Critique**: terms grant a "perpetual and irrevocable" licence and allow
  training by default; it kept indexed Gmail after disconnect (later fixed
  with a delete tool); one report of an e-mail sent without asking;
  CAPTCHAs and 2FA walls stop web tasks.
  <https://techcrunch.com/2026/08/24/instincts-powerful-ai-assistant-is-raising-privacy-and-security-concerns/>

**Lesson for us.** People pay for finished errands and for first contact
from the agent, not for configuration. Our angle: the same feeling, on the
user's own computer, with rules enforced in the server.

## 6. Cheap models (DeepSeek V4 / V4.1 Flash)

- **Pass `reasoning_content` back when the request has `tools`.** DeepSeek's
  docs: with `tools`, the reasoning of all earlier turns must be sent back and
  goes into the context. Without `tools`, it is ignored. Some third-party docs
  (Tencent Cloud) say "never pass it back"; that is wrong for tool loops.
  <https://api-docs.deepseek.com/guides/thinking_mode/>
- Thinking mode ignores `temperature` and penalties. Flash `top_p` is
  0.95 to 1.0 in thinking mode. Effort: `low` / `high` / `max`
  (`reasoning_effort`), default `high`. Use `low` or off for memory and
  classification jobs (we already use reasoning off for Hindsight).
- **Prefix cache.** On-disk cache, automatic. A hit needs a full match of a
  stored prefix unit (end of user input, end of model output, common prefix,
  fixed intervals). So: one stable system prompt, no timestamps or live state
  at the top, append only. <https://api-docs.deepseek.com/guides/kv_cache/>
- V4.1 Flash keeps the cache in server memory for minutes only (V4: at least
  72 h). Cached input is $0.006 vs $0.30 per million tokens, about 50x
  cheaper. Price is half outside peak hours. So keep heartbeats and
  follow-up tool turns close in time, and schedule heavy background jobs
  off-peak. <https://www.deeplearning.ai/the-batch/deepseeks-flash-leapfrogs-pro-again>
- V4 uses an XML-style tool-call format with a `|DSML|` token. Providers
  convert it to OpenAI JSON; test that conversion with long or nested
  arguments. <https://huggingface.co/blog/deepseekv4>
- Patterns from Hermes and Nod that help cheap models: frozen memory
  snapshot, heartbeat as a plain user message, small model for side jobs,
  drop large old tool results only on a cold cache, deterministic fallback
  when a summary call fails. Nod warns that small models are weak at the
  safety check: keep the trust check on a strong model, or make it
  deterministic where possible.

## Ideas for Agents, ranked

Rank = value for "more personal and trustworthy" against effort.
Effort: S = days, M = one to two weeks, L = more.

1. **Memory only from the owner's own words, with a quoted source per note;
   notes visible and editable with the source message.** Stops planted
   memories, builds trust. (Nod) **M**
2. **Wrap every external tool result as "data, not instructions"** and
   neutralize closing tags. (Nod) **S**
3. **Server-side trust check per action:** compare the action with the
   user's own words before send, buy, delete; one open confirmation per
   turn. (Nod, n8n HITL, Grok Bot) **M**
4. **Compact `USER.md` profile as imperative directives, replaced in place,
   with a size budget and fill level in the prompt; frozen snapshot per
   session.** (Hermes, OpenClaw) **S**
5. **Cache discipline for DeepSeek:** stable prefix, dynamic state as a user
   message, drop old big tool results only on a cold cache, verify
   `reasoning_content` is passed back in tool loops. (DeepSeek docs, Nod,
   Hermes) **S**
6. **Proactive observer:** code-level change check before any model call,
   act only on a concrete open need, server enforces no-repeat, snooze and
   quiet hours. Builds on our automations. (Nod, OpenClaw, Instinct) **L**
7. **`/goal` loop with a judge model** and a turn budget. (Hermes, Codex) **S**
8. **Session heartbeat:** recurring prompt in the same chat, idle-only,
   missed ticks merged, `[SILENT]` allowed. (Hermes, OpenClaw) **S**
9. **`history_search` tool** over all past messages with dates and
   `around`; add a few related old owner messages before each turn. (Nod,
   Hermes) **M**
10. **Skills that patch themselves:** let the agent propose a patch to an
    existing skill after a failure or a user correction (same approval flow
    as `propose_skill`). (Hermes, Nod) **S**
11. **Skill curator:** usage counters, `stale` / `archived` states, an idle
    review that proposes merges; skip pinned and scheduled skills. (Hermes)
    **S**
12. **Standing orders** in `agents.md`: Authority, Trigger, Approval gate,
    Escalation per program. (OpenClaw) **S**
13. **Writing-style note from sent e-mail** (no names, no numbers), used for
    drafts. (Nod) **S**
14. **Morning brief and call brief** as a built-in skill plus a default
    automation (calendar, threads, the contact's news). (Nod, OpenClaw) **S**
15. **One model per kind of work** (chat, memory, classification, summary)
    and a hard monthly spending limit with a check-in. (Nod, Hermes) **M**
16. **Robust context compressor:** keep the head and a lean tail, cooldown
    on failure, deterministic fallback summary. (Hermes) **M**
17. **Codemode:** a model-written script calls many tools in one step, each
    call through the same guard. Saves turns on cheap models. (Nod, Hermes)
    **M**
18. **"Delete what you indexed from this account"** on disconnect. Cheap
    trust win. (Instinct lesson) **S**
19. **Webhook trigger for automations** and "turn a routine into a
    deterministic job" (zero model tokens). (n8n, Nod) **M**
20. **Review learnings** for shared or group agents: what others teach waits
    for the owner. (Grok Bot 1.0) **M**
21. **Messaging gateway** (Telegram first, then WhatsApp/Signal): talk to
    the agent without the app. (Hermes, OpenClaw, Instinct) **L**
22. **Phone calls for errands** (Instinct Concierge, Nod roadmap). **L**
