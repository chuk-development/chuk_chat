# Agent competitors, October 2026

Status: 2026-10-05. Research for track 7 of `docs/OVERNIGHT_2026-10-05.md`.
Web sources were read on 2026-10-05. Our own column comes only from the repo
(file paths given). "(2nd)" marks a claim that rests only on a secondary or
vendor-biased source (SEO review blogs, hosting vendors, competitor blogs).
Check those before you quote them outside this repo.

"Grogbot" from the owner's request is **Grok Bot** (xAI/SpaceXAI + Anysphere/Cursor,
codename `sand`). Our mobile design already copies it
(`docs/MOBILE_GROKBOT_STRUCTURE.md`), and we have reverse-engineered its desktop
app (`docs/research/grok-bot-0.16-vs-0.47-diff.md`,
`docs/research/grok-bot-0.47-credentials.md`). Clawdbot/OpenClaw is covered too.

---

## 1. Kurzfassung

1. Die Besten antworten sofort: Manus hat die Aufgabenzeit von ~15 auf <4 min gedrueckt und 2.0 spart nochmal 28 % Zeit; wir brauchen fuer "hi" 100-180 s `prepare` vor einem 3-s-Modellaufruf und 33k Tokens.
2. Prompt-Cache ist bei Manus "die wichtigste Kennzahl" (stabiler Prefix, nur anhaengen, Tools maskieren statt entfernen); Hermes friert Memory pro Session ein. Wir messen unsere Cache-Trefferquote nicht und schreiben den Tail jede Runde neu.
3. Grok Bot, ChatGPT, Gemini und Claude zeigen klar, was der Agent gerade tut, und haben eine Uebernahme (Takeover) fuer Login/2FA/CAPTCHA. Wir haben VNC, aber keinen eigenen Takeover-Ablauf.
4. Freigaben pro Aktion (einmal / immer / pro Seite, Auto-Review) sind Standard. Bei uns fragt nur `herenow_publish`.
5. Kanaele: OpenClaw (20+), Hermes, Genspark Claw, Lindy, Poke laufen in WhatsApp/Telegram/iMessage/Slack. Wir nur in der eigenen App (plus Push).
6. Automationen haben Ereignis-Trigger (neue Mail, GitHub-PR, Kalender, Webhook) und "nur melden wenn sich was aendert". Wir haben Zeitplaene und Watcher-Prozesse.
7. Fertige Vorlagen: Grok Bot liefert 42 Preset-Bots plus Marktplatz, Lindy lebt von Templates. Wir starten leer.
8. Onboarding: Grok Bot/Manus/Claude brauchen kein Setup (Cloud-VM oder Mac/Win). Unser Host laeuft nur auf Linux mit Docker.
9. Groesste Beschwerde ueberall: Kosten/Kontingent (Grok Bot 99 % Wochenkontingent in 3 Tagen, OpenClaw 18,75 $ ueber Nacht). Sichtbare Kosten und Budgets sind ein Verkaufsargument.
10. Wo wir vorne liegen: echtes Handy-App plus eigener Rechner, Docker pro Agent (Grok Bot: eine VM pro Nutzer, Bots nicht isoliert), E2E-Relay, Rooms, Voice, FTS5 + semantisches Memory.

---

## 2. Products

### 2.1 Grok Bot (xAI/SpaceXAI + Cursor, "sand")

- **What:** beta since 2026-08-11. Named, always-on Bots with a cloud computer.
  They sign in to your tools and come back for approval.
  [runtimewire](https://runtimewire.com/article/cursor-spacexai-launch-grok-bot-general-purpose-agents),
  [x.ai/bot](https://x.ai/bot), [changelog](https://x.ai/changelog/bot).
  Model: Grok 4.5 at launch, 4.6 now.
- **Computer:** one persistent Debian VM **per user, not per Bot** (Chrome,
  terminal; ~16 GB RAM). Bots share files, cookies and logins. FAQ: "Isolation is
  per user, not per Grok Bot." Each Bot gets its own screen on the VM.
  [x.ai/bot](https://x.ai/bot), [eesel (2nd)](https://www.eesel.ai/de/blog/grok-bot-test).
  The 0.47 desktop app also drives the user's own machine through a local exec
  daemon with per-tool permission ("Allow Once"), auto-review and an audit trail
  (`docs/research/grok-bot-0.16-vs-0.47-diff.md` section 7).
- **Feel:** onboarding is name + job + description, then chat. Template onboarding
  since 0.44. iMessage-style UI. Live view and remote control on macOS, Windows,
  iOS; Linux download now exists. Takeover flow for passwords, passkeys, 2FA,
  CAPTCHA; secrets stay out of the transcript; 1Password autofill.
  [dailydoseofds](https://blog.dailydoseofds.com/p/grok-bot-masterclass).
  Complaints: "black-box output", unclear status, users read a working Bot as
  frozen [80aj](https://www.80aj.com/2026/08/19/grok-bot-review-cloud-vm/).
- **Approvals:** prose boundaries plus optional model "Auto Review"; Slack "Review
  an action" card (2026-09-29); no dry run; Stop does not undo. Audit logs and
  action recording (redacted) added in September. [changelog](https://x.ai/changelog/bot).
- **Memory/context:** per-Bot memory (preferences, facts, summaries). Every turn
  re-reads the full thread; routines re-send context; 84 % of one user's tokens
  were cache reads. Support advice: "start a fresh conversation per task" - so no
  real compaction story.
  [forum](https://forum.cursor.com/t/why-does-grok-bot-chat-use-so-many-sand-tokens/169581),
  [forum](https://forum.cursor.com/t/grok-bot-ultra-users-how-do-you-make-the-weekly-allowance-last-mine-reached-99-in-three-days/171221).
  Changelog fix: Bots "with a lot of saved memory or skills reply without a
  several-second pause".
- **Multi-agent, channels, voice:** rooms with 2-6 Bots; Team Bots in Slack
  (2026-09-26), Teams in setup checklist; voice mode 2026-09-17/18, team voice
  2026-09-30. iMessage bridge exists in the 0.47 bundle (our RE doc section 6), no
  public source.
- **Automations:** up to 50 routines per Bot, last 20 logs kept; scheduled,
  one-time, GitHub-PR triggers. "Teach Task" records 10 min of browser work into a
  skill or routine. 42 preset bots + template marketplace (RE doc section 9).
- **Pricing:** included in Cursor Pro $20 / Pro+ / Ultra, SuperGrok $30 / Plus /
  Heavy, Cursor Teams; weekly allowance, then token cost; no spend cap.
- **Complaints:** quota burn (Ultra 99 % in 3 days, ~284M tokens; $27 in 10 min
  [forum](https://forum.cursor.com/t/anyone-used-grokbot-on-the-api-very-high-costs/169551));
  outages 2026-09-19..23
  [forum](https://forum.cursor.com/t/grok-bots-not-responding-yet-again/172371);
  no SOC 2.
- **Speed:** no measurements. Progress bar only if a send takes >2 s; "shorter
  waits for pages to settle".

### 2.2 Grok (xAI) itself

- Automations since 2026-07-16 (web, iOS, Android): plain-language job + schedule;
  email triggers on SuperGrok; each run is a fresh chat.
  [blockchain.news](https://blockchain.news/news/grok-automations-scheduled-tasks).
- No persistent computer or browser; that is what Grok Bot adds.
- Plans: Free, Lite $10, SuperGrok $30, Plus $100, Heavy $300 (up to 8 agents).
  API Grok 4.5/4.6: $2 in / $6 out per MTok, 500K context
  [ai-toolbox (2nd)](https://www.ai-toolbox.co/grok-models/grok-pricing-plans-api-2026).

### 2.3 OpenClaw (Warelay -> Clawdbot -> Moltbot -> OpenClaw)

- **What:** self-hosted Node gateway, MIT, ~391k stars, `curl | bash` install.
  Steinberger joined OpenAI 2026-02; project in a foundation. v2.0 on 2026-08-30.
  [GitHub](https://github.com/openclaw/openclaw), [Wikipedia](https://en.wikipedia.org/wiki/OpenClaw).
- **Channels:** 20+ (WhatsApp, Telegram, iMessage, Discord, Signal, Slack, Teams,
  Google Chat); native apps on all desktop OSes and phones; DM pairing.
- **Memory:** workspace files injected every turn (AGENTS.md, SOUL.md, IDENTITY.md,
  USER.md; 20k chars/file, 60k total); MEMORY.md in private session; daily notes
  (today + yesterday auto-load); hybrid vector + keyword search; silent "memory
  flush" turn before compaction; background "dreaming" promotes notes into MEMORY.md.
  [docs](https://docs.openclaw.ai/concepts/memory).
- **Heartbeat/cron:** heartbeat every 30 min with `activeHours`; `isolatedSession`
  cuts a heartbeat from ~100K to ~2-5K tokens.
  [docs](https://docs.openclaw.ai/gateway/heartbeat).
- **Browser:** own Chrome profile over CDP or attach to the user's Chrome via
  DevTools MCP; no live view and no approval gates in the docs.
  [docs](https://docs.openclaw.ai/tools/browser).
- **Sandbox:** optional; tools run on the host by default; no secret encryption at rest.
- **Security:** 341 then >1,184 malicious ClawHub skills (stealers, reverse
  shells); 135k exposed instances, 63 % without auth.
  [barrack.ai (2nd)](https://blog.barrack.ai/openclaw-security-vulnerabilities-2026/).
- **Cost:** a heartbeat re-sends ~120K tokens; $18.75 overnight
  [notebookcheck](https://www.notebookcheck.net/18-75-overnight-to-ask-Is-it-daytime-yet-The-absurd-economics-of-OpenClaw-s-token-use.1219925.0.html).
- **Praise:** flexibility, channels, ecosystem. **Complaint:** setup, forgetting.

### 2.4 Hermes Agent (Nous Research)

- **What:** MIT, ~251k stars, released 2026-02. Learning loop: writes a skill by
  itself after a hard task, improves skills, nudges itself to save memory,
  searches past sessions. agentskills.io skills.
  [GitHub](https://github.com/NousResearch/hermes-agent).
- **Memory:** MEMORY.md capped at 2,200 chars, USER.md at 1,375; over-limit writes
  fail (no silent truncation). Memory is a **frozen snapshot per session to keep
  the prefix cache warm**. FTS5 `session_search`. Plugins: Mem0, Honcho and others.
  [docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory).
- **Channels:** Telegram, Discord, Slack, WhatsApp, Signal, email, CLI; v0.20 adds
  WeChat, LINE and others plus a desktop app; no iMessage; no native mobile app
  (our plan section 17). Bot Mode with rooms (6 bots / 3 rounds / 10 messages).
- **Execution:** local, Docker, SSH, Modal, Daytona, Vercel Sandbox; cron to any
  channel; v0.20 streaming voice with wake word and barge-in, A2A.
  [runtimewire](https://runtimewire.com/article/nous-research-hermes-agent-v0200-voice-a2a).
- **Pricing:** free code; Nous Portal for models.
- **Complaints:** prompt bloat (40-token prompt -> 20,538-token request: all tool
  schemas + memory + skills each time); loops on non-Claude models
  [betterclaw (2nd)](https://www.betterclaw.io/blog/hermes-agent-bugs-fixes);
  astroturfing suspicion.

### 2.5 Manus

- **What:** cloud agent, one VM per task; research, apps, slides, data, media.
  Manus 2.0 (2026-09-28): "Cascade" harness, Manus Studio desktop app, "Cue"
  personal agent, one Cloud Computer per project, control from the phone.
  [blog](https://manus.im/blog/introducing-manus-2-0).
  Wide Research: 100+ isolated sub-agents. Browser Operator extension runs in the
  user's own browser with their logins
  [feature](https://manus.im/features/manus-browser-operator).
- **Context engineering** ([blog](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)):
  KV-cache hit rate is "the single most important metric"; stable prefix,
  append-only; input:output ~100:1; mask tools by logits, do not remove them;
  file system as restorable memory (drop page, keep path); `todo.md` recitation;
  keep errors in context; vary serialization against few-shot ruts.
- **Speed:** 1.5: ~15 min -> <4 min per task
  [blog](https://manus.im/en/blog/manus-1.5-release). 2.0: -23.2 % tokens,
  -28.2 % time, -32 % cost.
- **Channels/automations:** web, desktop, mobile; Mail Manus, Slack, API,
  Telegram, WhatsApp (2nd); 20 scheduled + 20 concurrent tasks; 2.0 event
  triggers (email, calendar, Slack, Notion, ad metrics).
- **Pricing:** 300 free credits/day; 4k / 8k / 40k credits per month (~$20 / $40 /
  $200, 2nd); tasks 200-900 credits (2nd).
- **Complaints:** credit burn ("computer stayed on all night"), loops, "announces
  done with little evidence"
  [Trustpilot](https://www.trustpilot.com/review/manus.im?page=1). Meta deal
  unwound by China in 2026-04; data from the Meta period deleted.

### 2.6 Anthropic: Claude Cowork, Dispatch, Claude Code, Claude in Chrome

- **Cowork:** desktop agent, isolated VM, a folder you choose, documents and
  sheets out; GA macOS/Windows 2026-04-09; web/mobile beta 2026-07-13; scheduled
  tasks run with no device online.
  [support](https://support.claude.com/en/articles/12138966).
- **Dispatch:** one persistent thread phone <-> desktop; push when done or when it
  "needs your go-ahead"; desktop must stay awake; no computer use on Linux.
  [support](https://support.claude.com/en/articles/13947068).
- **Claude Code:** auto prompt caching, auto-compaction, `/compact <focus>`,
  subagents keep output out of main context, skills load on demand, **MCP tool
  definitions deferred by default**; `/usage` shows cache share ("91 % of input
  tokens from cache"). Cloud sessions keep running after the laptop closes;
  routines on schedule/API/GitHub; @Claude in Slack.
  [costs](https://code.claude.com/docs/en/costs),
  [web](https://code.claude.com/docs/en/claude-code-on-the-web).
- **Claude in Chrome:** GA 2026-08-26; per-site permissions; reads free, clicks
  and typing ask. Complaint: a new dialog for every site that times out as
  "denied" [issue](https://github.com/anthropics/claude-code/issues/66125).
- **API:** cache read 0.1x (0.05x on Opus 5.5), 5-min and 1-h TTL, auto
  breakpoint; context editing clears old tool uses at 100k; server-side
  compaction. [caching](https://platform.claude.com/docs/en/docs/build-with-claude/prompt-caching).
- **Pricing:** Pro $20, Max $100 / $200, Team $25 / $125.
- **Complaints:** Cowork drains limits (Pro cap in ~10 min), compaction bugs
  [coworkhow (2nd)](https://www.coworkhow.com/guides/user-feedback-summary).

### 2.7 OpenAI: ChatGPT Work, Codex, Atlas, Scheduled Tasks

- **ChatGPT agent** (Operator + deep research, 2025-07; visual browser, terminal,
  takeover mode, confirmations, watch mode) is **retired**; replaced by **ChatGPT
  Work** (2026-07-09, GPT-5.6): hours-long projects across apps, files and web,
  progress view, redirect, approve important actions; desktop app merges Chat,
  Work and Codex; works in Slack and Teams.
  [help](https://help.openai.com/en/articles/11752874-chatgpt-agent),
  [blog](https://openai.com/index/chatgpt-for-your-most-ambitious-work/).
- **Scheduled Tasks** replaced Pulse: once, schedule or event; monitors notify only
  on change and remember earlier runs; "Scheduled" hub.
  [itbrief](https://itbrief.co.nz/story/openai-expands-chatgpt-scheduled-tasks-with-new-hub).
- **Codex compaction:** `POST /v1/responses/compact` returns an encrypted blob.
  [docs](https://developers.openai.com/api/reference/cli/resources/responses/methods/compact).
- **Atlas:** browser agent, "6-to-9-minute errand runner" (2nd); merged into the
  desktop app 2026-08 ([Wikipedia](https://en.wikipedia.org/wiki/ChatGPT_Atlas)).
- **Pricing:** Free, Go $8, Plus $20, Pro $100 / $200 (2nd).
- **Complaints:** GPT-5.6 burned caps
  [bleepingcomputer](https://bleepingcomputer.com/news/artificial-intelligence/openai-temporarily-relaxes-gpt-56-sol-usage-limits);
  old agent froze, failed on cookie banners and 2FA.

### 2.8 Perplexity: Comet, Computer

- Comet browser free since 2025-10-02; Max $200 adds a background assistant with a
  task dashboard and notifications
  [TechCrunch](https://techcrunch.com/2025/10/02/perplexitys-comet-ai-browser-now-free-max-users-get-new-background-assistant/).
- Perplexity Computer (2026-02-25): cloud agent, sub-agents, ~19 models. One
  research task: 7 min 59 s, 225.71 credits; cost unknown before the run
  [DataCamp](https://www.datacamp.com/tutorial/perplexity-computer).
- Brave showed prompt injection via page text (Gmail OTP exfiltrated)
  [Brave](https://brave.com/blog/comet-prompt-injection/).
- Complaints: RAM/CPU, loops, wrong bookings, "slower than doing it by hand" (2nd).

### 2.9 Genspark

- Super Agent (150+ tools: slides, sheets, sites, "Call for Me" phone calls).
  **Claw** (2026-03-12): "AI employee" on its own cloud computer, tasks over
  WhatsApp, Telegram, Teams, Slack; meeting bots
  [SiliconANGLE](https://siliconangle.com/2026/03/12/genspark-launches-claw-ai-assistant-secure-alternative-open-agent-platforms-openclaw/).
- ARR $100M (2026-01) -> ~$250M (~2026-06) [Sacra](https://sacra.com/c/genspark/).
- Pricing: Plus $24.99 / 10k credits, Pro $249.99 (2nd). Trustpilot ~1.5-1.9:
  charges for failed tasks, "burned 10K credits on one command" (2nd).

### 2.10 Lindy

- Lindy 3.0: Agent Builder from a prompt, Autopilot (own cloud computer), teams
  [blog](https://www.lindy.ai/blog/lindy-3-0). Lindy Assistant (2026-02):
  executive assistant whose main interface is **iMessage**; drafts reviewed before
  sending; "setup in ~2 minutes".
- Pricing: $29.99 / $99.99 / $199.99 per month, credits; approvals, routines, MCP
  on all plans [pricing](https://www.lindy.ai/pricing).
- G2 4.9 (templates, ease); Trustpilot 1.7 (support, credit black box) (2nd).

### 2.11 Google: Gemini Agent, Spark, Chrome auto browse

- Project Mariner shut down 2026-05-04; tech moved to Gemini Agent (2025-11,
  Ultra US; confirms before purchases and sends).
- **Gemini Spark** (beta 2026-05-29, US Ultra): 24/7 cloud agent, up to 15 parallel
  tasks, remote browser, code execution, MCP partners, approval before mail or
  money [techlicious](https://www.techlicious.com/blog/google-gemini-spark-agent-io-2026/).
- **Chrome auto browse** (2026-01-28): active tab glows, side panel shows each
  step, "Take over task" anytime; user presses buy/post
  [9to5google](https://9to5google.com/2026/01/28/chrome-gemini-auto-browse/).
- Scheduled Actions: up to 10, run within 1 h of schedule.
- Ultra $100 (new) / $200. Gemini 2.5 Computer Use: ~225 s per task on
  Online-Mind2Web (2nd reading of the chart).

### 2.12 Devin / Cursor (coding agents, for patterns)

- Windsurf became "Devin Desktop" (2026-06) with a Kanban "Agent Command Center"
  (Running / Waiting for Review / Done) (2nd). Pro $20, Max $200
  [pricing](https://devin.ai/pricing). SWE-1.6 at ~950 tok/s on Cerebras
  [Cerebras](https://www.cerebras.ai/blog/case-study-cognition-x-cerebras).
  Cognition bought Poke (2026-07).
- Cursor cloud agents: VM + browser + recorded video; start from Slack, web, iOS,
  Android.

### 2.13 Newcomers worth knowing

- **Poke:** lives in iMessage/SMS/WhatsApp/Telegram, no app; first agent on Apple
  Messages for Business; 100M+ messages in 3 months; $0 / $19 / $199. Complaint:
  email checks "15+ minutes" [saner (2nd)](https://blog.saner.ai/poke-reviews/).
- **Zo Computer:** personal Linux server with AI, texted via iMessage/SMS/
  Telegram; scheduled agents (2nd).
- **Edge "Browse with Copilot"**, **Opera Neon** ($19.90, MCP), **Amazon Nova Act**
  (GA, >90 % reliability claim).

### Cross-cutting patterns

- Cost/quota is the top complaint for every product (Grok Bot, OpenClaw, Manus,
  Claude, ChatGPT, Genspark, Lindy, Perplexity). Nobody shows the cost before a run.
- Messenger channels are standard (iMessage, WhatsApp, Telegram, Slack, Teams).
- Background cloud agents with approval gates and push "needs you" are the norm.
- Hard speed numbers are rare. Only Manus publishes them. Atlas 6-9 min per
  errand, Perplexity Computer 8 min per research task, Gemini CU ~225 s per task.

---

## 3. Feature matrix

Legend: **Y** yes, **~** partial or limited, **-** no, **?** not found.
Columns: GB = Grok Bot, OC = OpenClaw, HE = Hermes, MA = Manus, CL = Claude
(Cowork/Code/Chrome), OA = OpenAI (Work/Codex/Tasks), PX = Perplexity, GS =
Genspark, LI = Lindy, GO = Google (Gemini Agent/Spark/Chrome), DV = Devin/Cursor.

| Capability | GB | OC | HE | MA | CL | OA | PX | GS | LI | GO | DV | Agents (us) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Live browser view | Y (VNC, takeover) | - | ? | Y | Y (own Chrome) | Y (takeover) | Y | ? | ~ | Y (take over) | ~ (video) | **Y** watch + control over sealed VNC: `lib/widgets/browser_view_page.dart`, `agents/sandbox/docker/vnc-up.sh` |
| Approvals | ~ (auto-review, Allow Once, Slack card) | ~ (DM pairing) | ? | ~ | Y (per site / action) | Y (confirm, watch mode) | ~ | ? | Y (drafts) | Y (buy/send) | ~ (review column) | **~** only `herenow_publish` asks: `agents/runtime/src/chuk_agents_runtime/pai/approvals.py`; per-agent switches: `agents/host/src/chuk_agents_host/agent_permissions.py` |
| Memory | Y per bot | Y files + hybrid search + dreaming | Y capped files + FTS5 | ~ files | ~ CLAUDE.md, memory tool | Y | ? | ? | Y | Y | ~ | **Y** Mem0/Hindsight + soul.md/agents.md + FTS5: `.../runtime/memory.py`, `memory_hindsight.py`, `search.py` |
| Compaction | - ("start a fresh chat") | Y (flush first) | Y `/compress` | Y restorable | Y auto + server | Y Codex compact | ? | ? | ? | ? | ? | **Y** 3-tier ladder: `.../runtime/context.py` (`ContextLadder`), but slow (see latency) |
| Prompt caching | Y (cache reads billed) | ~ provider | Y frozen snapshot | Y core metric | Y, visible in `/usage` | Y | ? | ? | ? | ? | ? | **~** breakpoints in `api_server/chat/prompt_cache.py`; hit rate not measured; ladder rewrites the tail |
| Channels | Slack, Teams, (iMessage in bundle) | 20+ | 7+ (no iMessage) | Mail, Slack, Telegram | Slack, phone | Slack, Teams | - | WhatsApp, Telegram, Slack, Teams | iMessage, mail, Slack | - | Slack | **-** own app + FCM push only: `agents/host/src/chuk_agents_host/notify.py` |
| Scheduling | Y 50/bot, PR trigger | Y heartbeat + cron | Y cron | Y 20 + events | Y + GitHub/API | Y + monitors | ~ | Y | Y | Y (10) | ~ | **Y** schedules, watchers, trigger file: `agents/host/src/chuk_agents_host/automations.py` |
| Multi-agent rooms | Y 2-6 | ~ | Y 6/3/10 | ~ (Wide Research) | ~ subagents | ~ subagents | ~ | ? | - | ~ (15 parallel) | ~ | **Y** rooms 6/3/10: `agents/manager/src/chuk_agents_manager/group_room.py`; subagents: `.../runtime/subagents.py` |
| Voice | Y | ? | Y (wake word) | ? | Y | Y | ? | Y (outbound calls) | ? | Y | - | **Y** LiveKit, owner flag: `agents/voice/`, `lib/voice/` |
| Mobile app | Y iOS | Y | - | Y | Y | Y | Y | Y | iMessage | Y | Y (Cursor) | **Y** Flutter Android: `scripts/build_apk.sh` |
| Local execution | ~ (cloud VM + local daemon) | Y host | Y | - (browser ext.) | Y | Y | ~ | - | - | - | Y | **Y** own Linux machine only: `scripts/agents-bootstrap.sh:145` |
| Sandboxing | ~ VM per user, bots share | ~ optional | Y Docker default | Y VM per task | Y VM | Y | - | Y | Y | Y | Y | **Y** Docker per agent: `agents/sandbox/src/chuk_agents_sandbox/docker.py`, `policy.py` |
| Skills / plugins | Y + Teach Task + templates | Y ClawHub (malware) | Y self-written | ? | Y | Y apps | - | Y tools | Y templates | ~ | ~ | **~** 6 built-in + workspace skills, no learning loop, no templates: `agents/skills/builtin/`, `.../runtime/skills.py` |
| MCP | Y | Y | Y | ? | Y | Y | ? | ? | Y | Y | ? | **Y** `.../runtime/mcp_client.py`, `lib/services/mcp/` |
| File / document output | Y | ~ | ~ | Y | Y | Y | ~ | Y | ~ | ~ | ~ | **Y** `.../runtime/files_out.py`, `documents.py`, skill `document-authoring` |
| Latency / streaming feel | ~ stalls, unclear status | ? | ~ prompt bloat | Y <4 min, -28 % | Y | ~ 6-9 min errands | ~ | ? | ? | ~ | Y fast models | **-** "hi": 100-180 s `prepare`, 3 s model, 33k tokens (`docs/OVERNIGHT_2026-10-05.md`); token stream via `delta` frames (`docs/WIRE_CONTRACT.md`) |
| Onboarding | Y no setup, templates | ~ ("nightmare") | Y wizard | Y web | Y | Y | Y | Y | Y 2 min | Y | Y | **~** one `curl` line + automatic re-pairing (`lib/pages/agents_install_page.dart`, `lib/services/agents/agents_pairing_restore.dart`); Linux + Docker only |

Extra things we have that most do not: git-journaled workspace with restore
(`agents/runtime/src/chuk_agents_runtime/workspace_git.py`), debug export of the
raw model context (`lib/services/agents/chat_debug_export.dart`), secret request
dialog with scrubbing (`agents/runtime/src/chuk_agents_runtime/secrets.py`), E2E
relay with device pairing (`lib/services/agents/agents_cloud_relay.dart`).

---

## 4. Was wir bauen sollten (priorisiert)

Speed and UX first, then features. Effort: S = days, M = 1-2 weeks, L = more.

1. **Remove the `prepare` stall (100-180 s before a 3 s model call).**
   Why: our baseline in `docs/OVERNIGHT_2026-10-05.md`; Manus sells speed
   (<4 min, -28 %); Grok Bot had to fix "several-second pause" with big memory.
   How: run the aux summary after the turn, in the background (as
   `docs/context-compaction-design.md` section 2.1 already says), never on the
   request path; cache the prepared history per session. Effort M.
   Where: `agents/runtime/src/chuk_agents_runtime/loop.py` (`_outbound_messages`),
   `context.py` (`ContextLadder.prepare`). Bead `chuk_chat-p5xm`.

2. **Cut the baseline prompt (33k tokens for "hi").**
   Why: Hermes is criticised for 40 -> 20,538 tokens; Claude Code defers MCP tool
   definitions and loads skills on demand. How: defer every non-core tool behind
   `tool_search` from token 0, keep the skill catalog to name + description, cap
   persona/memory files like Hermes (2,200 chars). Effort M.
   Where: `.../runtime/prompt.py` (`build_system_prompt`), `tool_search.py`,
   `runtime.py` (`enable_tool_search`, threshold), `skills.py`.

3. **Cache-stable prefix and a measured cache hit rate.**
   Why: Manus "single most important metric", 10x price gap; Hermes freezes
   memory per session; Claude Code shows "% from cache". How: freeze system prompt
   + memory snapshot per session, append-only history; rewrite the tail only at a
   threshold, in batches, not every round (this revises the per-round rewrite in
   `docs/context-compaction-design.md` section 2.1); store `cached_tokens` per run
   and show it. Effort M. Where: `.../runtime/prompt.py`, `context.py`,
   `telemetry.py`, runs table; `api_server/chat/prompt_cache.py`.

4. **Instant acknowledgement and an honest live status line.**
   Why: Grok Bot users read a working Bot as frozen; Grok Bot shows progress after
   2 s; Chrome and ChatGPT show each step. How: the host emits phase frames
   (queued, preparing, thinking, tool X, waiting for you) within 300 ms of send;
   the app shows phase + elapsed time. Effort S.
   Where: `lib/widgets/agent_activity/turn_status.dart`,
   `agent_activity_timeline.dart`; frames in `docs/WIRE_CONTRACT.md`.

5. **A repeatable speed test with per-turn timings.**
   Why: without numbers, items 1-3 cannot be proven; Manus publishes before/after.
   How: script that sends fixed prompts and reads `prepare_ms`, `model_wait_ms`,
   tool time, tokens, cached tokens from the runs table. Effort S.
   Where: `agents/runtime/src/chuk_agents_runtime/telemetry_report.py`, new script
   under `scripts/`. (Overnight track 8.)

6. **Takeover card for logins, 2FA and CAPTCHA.**
   Why: Grok Bot, ChatGPT agent and Chrome auto browse all hand control to the user;
   failures on 2FA are a top ChatGPT complaint. How: a typed "needs you" card with
   one button that opens the VNC view in control mode, a push notification, and
   resume on "done". We already have VNC control and `request_secrets`. Effort S-M.
   Where: `lib/widgets/browser_view_page.dart`, `ask_user_card.dart`,
   `agents/host/src/chuk_agents_host/notify.py`, executor browser tools.

7. **Per-action approvals: allow once / always for this agent / per site.**
   Why: standard everywhere (Grok Bot "Allow Once", Claude per site, Gemini before
   buy/send, Lindy drafts). Avoid Claude's flaw (dialog per site that times out as
   deny): keep pending approvals in the thread and in push. How: add categories
   send message/mail, payment, delete outside workspace, first login on a new site.
   Effort M. Where: `.../runtime/pai/approvals.py` (`ApprovalPolicy`),
   `lib/widgets/ask_user_card.dart`, `lib/widgets/agents_permissions/`.

8. **Visible cost and budgets per agent and per run.**
   Why: the number one complaint for every competitor (Grok Bot 99 % in 3 days,
   OpenClaw $18.75 overnight, Manus credits overnight). How: tokens and euro per
   run in the thread footer, weekly budget per agent with a hard stop (Pydantic AI
   usage limits), light isolated context for scheduled runs (OpenClaw
   `isolatedSession`: ~100K -> 2-5K). Effort M.
   Where: runs table, `.../runtime/telemetry.py`, `loop.py`,
   `lib/widgets/agent_control_panel.dart`, `agents/host/.../automations.py`.

9. **Coworker templates (preset agents) in onboarding.**
   Why: Grok Bot ships 42 presets + marketplace; Lindy's G2 praise is templates;
   our roster starts empty. How: 10-15 presets (inbox triage, news digest, price
   watcher, research, video clipper) = name + job + schedule + skills, picked in
   the add-agent sheet. Effort S-M.
   Where: `agents/host/src/chuk_agents_host/seed_skills.py`, `coworker_names.py`,
   `lib/pages/agent_profile_edit_page.dart`, mobile add sheet.

10. **Event triggers and "notify only on change".**
    Why: Manus 2.0 (email, calendar, Slack), Grok Bot (GitHub PR), ChatGPT
    monitors. We have schedules + watcher processes, no inbound webhook. How: a
    webhook URL per automation through the relay, mail/calendar triggers via MCP
    connectors, a change-only mode that diffs the last result. Effort M.
    Where: `agents/host/src/chuk_agents_host/automations.py`,
    `agents/runtime/src/chuk_agents_runtime/automations.py`,
    `lib/pages/automations_page.dart`.

11. **Telegram channel per agent (opt-in), Slack later.**
    Why: OpenClaw, Hermes, Genspark Claw, Lindy, Poke all live in messengers; Poke
    did 100M messages without an app. Our app stays the main surface; a channel is
    for people who will not install it. Mark clearly that it is not E2E. Effort M.
    Where: new `agents/host/src/chuk_agents_host/channels/` feeding
    `Executor.submit_task`; toggle in `lib/widgets/agent_control_panel.dart`.

12. **Finish "use my own browser and logins".**
    Why: Grok Bot imports Chrome cookies and 1Password; Manus Browser Operator and
    Claude in Chrome run in the user's browser. The extension bridge is half built
    (`docs/RUNBOOK_2026-09-08_USER_BROWSER.md`). Effort M.
    Where: executor browser target selection, browser extension, `browser_presence.dart`.

13. **Self-written skills (learning loop).**
    Why: Hermes' main selling point; Grok Bot "Teach Task" turns recorded work into
    a skill. How: after a long successful task, offer "save as skill" (card with
    the draft SKILL.md, user approves). Recording comes later. Effort M.
    Where: `.../runtime/skills.py` (new write tool), `agents/skills/workspace/`.

14. **"What did it do" timeline with undo.**
    Why: Grok Bot added audit logs and action recording; "Stop does not undo" is a
    Grok Bot complaint. We already journal every tool call in git. How: show the
    journal per run in the app with "restore to here". Effort S-M.
    Where: `agents/runtime/src/chuk_agents_runtime/workspace_git.py`,
    `lib/widgets/agent_run_views.dart`.

15. **Host on macOS (then Windows/WSL), or a hosted host.**
    Why: Grok Bot, Manus and Claude need no Linux box; our bootstrap stops on
    anything but Linux (`scripts/agents-bootstrap.sh:145`) and needs Docker. This
    caps the market. Effort L.
    Where: `scripts/agents-bootstrap.sh`, `agents/sandbox/`, host service install.
