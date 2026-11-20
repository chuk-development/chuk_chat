# DuskBot: product features and logic (read-only analysis)

Source: `/home/user/git/chuk_chat/_scratch/duskbot` (shallow clone, v0.2.13 in README, v0.2.15 newest in CHANGELOG).
Licence: PolyForm Noncommercial. Ideas only, no code or text copied.

Paths below are relative to the clone root.

## 1. Feature list

**Bots (agents)**
- One bot = one chat, one folder, one memory, one computer, one engine. Many bots at once.
- Engine choice per bot: sign-in engines (Claude Code, Codex, Gemini, Grok, Cursor, Copilot, DeepSeek, Kimi, Qwen, OpenCode, Hermes, Cline, Droid, ...), API keys (Anthropic, xAI, Mistral, Groq, Cerebras, MiniMax, any OpenAI-compatible endpoint), local models (Ollama, LM Studio), custom ACP agents. Model can be switched any time without losing chat, files or memory.
- Standing instructions (`SOUL.md`), skills (`SKILL.md`), playbooks, voice, colour, mascot, picture.
- Preset bots ("Starting role") from a shared file, the org shelf, or built-in roles.
- Bot API: per-bot switch and key so an outside app or script can message a bot (`docs/bot-api.md`).

**Chat and rooms**
- Chat with tables, code, files. Questions shown as cards (one tap to answer).
- Rooms (groups): several bots in one thread (see section 2).
- Task threads: a room has independent tasks, newest first.
- Stop button, model chip shows the model actually answering, failure messages in plain words.
- Voice typing and voice mode (`docs/voice-mode.md`, `docs/bot-voice.md`).

**Computer**
- Browser per bot (watchable). Full desktop per bot on dusk cloud, a container on your server, a Linux VM in Docker on this computer, or the user's own screen (macOS, Ubuntu Xorg).
- "Take control": the person pauses the bot's hands for a sign-in or captcha, then hands back. Bot never sees the password.

**Routines and triggers**
- Natural-language scheduling ("every weekday at 8"), turned into cron/interval/once/daily with preview of next 3 dates (`docs/routine-schedules.md`).
- Checks: plain code that runs on each tick before any AI turn, so quiet ticks cost nothing (`docs/proactive-routines.md`).
- App-event triggers (new email, GitHub issue), webhooks with their own listener.
- "Keep an eye on my day" built-in routine, offered as a card with Turn it on / Not now.

**Memory**
- General memory (about the user, shared by all bots) and per-bot memory (`MEMORY.md` + topic files).
- Every line carries date and "learned by <bot>". Supersession: new fact replaces old, old kept as history.
- Save triggers: explicit "remember", background extraction after chat goes quiet, nightly tidy-up (merge duplicates), daily log, full journal with undo.
- Import of memory and instructions from other AI tools on the computer (`docs/memory.md`).

**Approvals and permissions**
- Per-bot approval level: Ask, Auto-accept edits, Approve for me (provider auto-review), Full access, Custom (Codex only).
- Reading own files and reading connected apps never asks. Writes, sends and deletes ask.
- Separate setting "sending on your behalf": Ask every time, or a daily amount cap.
- Level can be changed while a bot is working.

**Vault**
- Saved logins that the bot uses but never sees. Value typed in or passed to a tool, never reaches the AI. 1Password works too.

**Connectors**
- One-click vendor MCP servers with the person's own account (dynamic client registration).
- Paste-a-token apps (GitHub, Notion, Linear, Airtable, Todoist, Trello, ClickUp, HubSpot, Jira, Shopify, Stripe, Cloudflare). Token checked live before save.
- Gmail with app password. Google Drive, Dropbox via native sign-in rows.
- Composio (user's own account) for hundreds more. Hosted Composio broker closed to new installs.
- Any MCP server by URL or command; paste a `claude mcp add` line and it parses it. `duskbot mcp` exposes dusk bot itself as an MCP server.
- Reuse of Claude Code MCP servers and skills on the same computer.

**Sharing, teams, migration**
- Share a department as one file (`.dusk.json`): bots, skills (text only), playbooks, group chats, routines (paused on import), connection names (values never included), starter notes. Secrets scrubbed before write.
- Import is additive and rolls back fully on failure. Skills arrive off, routines paused, connections switched off with empty values.
- Org library shelf for an organisation (Admin > Packages).
- Move-in from Grok Bot, ChatGPT, Claude, OpenClaw, Hermes. Encrypted full backup file.

**Platforms and deployment**
- Desktop: macOS 12+ (Apple silicon and Intel), Windows 10/11 x64, Ubuntu 24.04 beta (.deb, AppImage).
- Phone: web app for now, iPhone link by QR code. Push notifications with suppression rules (`docs/phone-push.md`).
- Where bots run: This computer (free), dusk cloud (hosted), own server (one install line on Ubuntu/Debian, Cloudflare tunnel option).
- Mac notch presence (bot status in the notch).
- Sentinel: out-of-process health scanner for the data dir, no model calls (`docs/sentinel.md`).
- Built-in decision model ("Jev" or OpenRouter) for room routing only (`docs/decision-model.md`).

**Team Cloud (shared machine for a company)**
- Roles Owner, Admin, Member. Team bots are shared chats with an audience (everyone, admins, or only people added).
- "New conversation" is private to its owner, even from admins.
- Per-person unread state. Admin controls engines, computers, MCP servers allowed.
- Connected apps belong to the team by default.
- Invite flow and pairing signed by Admin (`docs/team-cloud.md`, `docs/team-sharing.md`).

## 2. Groups (rooms): how they work

Short answer: yes, they have group chats with multiple bots in one thread. They have no human-to-human group chat in the same sense. Humans share bots (team cloud), and a room is one thread that holds several bots plus the person.

**Data model** (`shared/wire.ts` WireGroup, `server/store.ts` GroupRecord, `server/routes/groups.ts`)
- `id`, `threadId` (active task thread), `tasks[]` (independent threads, newest first), `name`, `memberIds[]`, `bulletin` (shared instructions, max 12 000 chars), `description`, `cwd` (shared working folder, or per-member default), `section` (sidebar heading), `dm` flag (auto-created bot-to-bot channels), `audienceFloor` (narrowest audience ever, so a bot leaving never widens who sees the transcript), `defaultResponder`, `setupCompletedAt` / `setupSkippedAt`.
- Room setup is a wizard that must finish before the first message: folder, bulletin, default responder. Route: `PATCH /api/groups/:id/setup`.
- Per-member hold: `POST /api/groups/:id/holds {botId, held}` stops one member's turn only (`server/routes/room-holds.ts`).

**Who answers: `defaultResponder`** (`src/lib/group-routing.ts`, `server/room-leader.ts`)
Message routing order in `roomRouteForComposer`:
1. `@everyone` anywhere in the line: every visible member answers.
2. `@name` mentions, resolved against members. If a name is shared by several members and none was picked from the @ list, the room refuses and nobody answers (`ambiguous`).
3. No mention: the room's default responder decides:
   - `everyone`: all members answer.
   - `mentions`: nobody answers unless @-tagged.
   - `auto`: a decision model (Jev or OpenRouter) picks one bot with probability >= 0.6, or "several members" at >= 0.6. Otherwise falls back to a fallback bot (`fallbackBotId`) or the first member. It fails open (timeout 1.5 s, any error = fallback). Each auto-picked reply shows "Picked by Jev · 94%".
   - `member` with optional `leader: true`: the lead answers. A leader can delegate.

**Leader / delegation mode** (`server/room-leader.ts`)
- A leader member gets a system note with the team roster (name, id, title) and a `coordinate_bots` tool.
- It plans, does small things itself, and hands tasks to members (one self-contained task each; independent tasks sent in one call to run in parallel), then ends its turn.
- Each hand-off shows in the room. The leader is woken once with the members' results.
- Hard caps per person message: `LEADER_MAX_ROUNDS = 3`, `LEADER_MAX_TASKS = 8`. Over-cap calls are refused with a message to the model.
- Members get a note: do the task alone, report in 1-2 plain lines, ask the leader if blocked, do not pass the task on.
- Team goals / Chief of Staff: a bot that plans team setup (`server/routes/internal-chief-team.ts`, only an active Chief may plan).

**Bot-to-bot**
- Bots reach each other only inside the same audience (`sameAudience`). A restricted bot's words never reach people who cannot see it.
- Bot-to-bot channels are `dm: true` rooms created automatically. They have no room setup and members cannot be held.

**Permissions in rooms**
- A member sees a room only if they can see every bot in it (`server/bot-visibility.ts`).
- Work handed by `coordinate_bots` uses the receiving bot's approval level, never the sender's, except a Chief's level flows down.
- Bot visibility: everyone, admins, or a list of email addresses.

**Provenance tags** (`docs/team-cloud.md`)
- Every line a bot reads from someone else is prefixed by the Cloud, not the sender: `[From <who> · <what> · <authority>]`. Authority is one of: their own request, on their behalf at your level, or information only. A bot cannot forge who said it.

**Humans in groups**
- Team Cloud: teammates are in the @ list; a bot's shared chat is visible to whoever sees the bot; unread state is per person.
- A group chat is seen by whoever sees it. Reads clear unread for that person only (`room-reads.json`).

**Limits we can compare**
- No documented cap on members per room in the files I read.
- Rooms are not a multi-user human chat room: no human-to-human messaging channel was found in the clone.

## 3. Agents model

- **Create:** New bot (default approval Full access on personal installs; Ask on hosted company workspace), from a preset, from a team file, from onboarding, or via API. First install's first bot is Dusk, also the Chief.
- **Identity:** name, title, description, standing instructions (`SOUL.md`), colour, mascot, picture.
- **Memory:** general memory (`Settings > General > About me`) plus per-bot `MEMORY.md` and `memory/<topic>.md`. Daily logs `memory/log/<day>.md` (never loaded into chat). Journal of all memory changes with undo. Secrets are redacted before write (`«redacted»`).
- **Skills:** `SKILL.md` per skill with saved revisions. Shared as text only. Limit 30 per bot, 60 per team file.
- **Model:** per bot, switchable. Not "no model": the bot must have an engine. Fallback free model exists for first messages.
- **Routines:** schedules (once, daily, interval, cron with Croner, timezone required), checks (code, no AI on quiet tick), app-event triggers, webhooks. Pause/resume per row. Imported routines always paused.
- **Notifications:** phone push for unread replies, questions, approvals, with 4-second suppression if read elsewhere and retries at 10 s and 60 s.
- **Approvals:** described in section 1. Questions come as cards.
- **Computer:** per bot, optional.

## 4. Connectors

- **Scope:** global connected-app pool per install. Each bot gets a permitted subset ("choose which bots may use each one"). Team Cloud: connections belong to the team by default, with an admin option to make them per member.
- **Auth flows:**
  1. Vendor hosted MCP, sign-in in browser, dynamic client registration.
  2. Device code (GitHub, Google Drive).
  3. Code + PKCE via a fixed callback at `link.dusk.bot/oauth/app-tokens` that redirects to the local port; stores nothing (`docs/composio.md`).
  4. Pasted token, checked live against the vendor's "who am I" endpoint, sealed in `app-tokens.json.enc`. Either the vendor MCP with bearer, or a local `api_request` endpoint that keeps the token server-side.
- **Which:** GitHub, Google Drive, Notion, Linear, Airtable, Todoist, ClickUp, Dropbox, Trello, Gmail (app password), HubSpot, Jira, Shopify, Stripe, Cloudflare, Figma and more via Composio and MCP.
- **Cost:** DuskBot pays nothing per tool call. Composio costs are on the user's own Composio plan.
- **Read vs write:** read-only tools never ask (MCP readOnlyHint, but a tool whose name says write is never trusted as read-only).

## 5. Onboarding and defaults

From `docs/onboarding-funnel.md` (before/after) and `AGENTS.md`:
- Removed: account gate before the app; a separate welcome screen; a second "welcome to dusk cloud" after the cloud is made; the in-app purchase sheet (replaced by "Continue in your browser").
- Kept: connect AI; bring memory from other apps (called a real differentiator); phone pairing hidden behind a flag.
- Order on "This Mac": where bots live (first screen, with price) > account (Skip for now) > connect an AI > bring what you use > chat with the first reply.
- Chat opens with message box focused and two tap-able first jobs ("Keep an eye on my day", "Set up a bot for my inbox").
- Dev install seeds eight invented test bots once per workspace.
- Defaults: approval Full access (personal) or Ask (hosted company); new bots greet with a fixed line so no tokens are spent before the first message; free backup model for first messages.
- Phone pairing: QR code plus a short letters-only code (0.2.15).

## 6. Pricing, plans, limits

Sources: `apps/dashboard/server/billing/plans.ts`, `docs/limits.md`, CHANGELOG.

| Plan | Price (code) | Notes |
|---|---|---|
| This Mac / own server | Free | personal use free forever per README |
| Work license (solo) | $12/mo (1200) | `plans.ts`; `DUSK_FREE_WORK_UNTIL` 2026-12-01 in limits |
| Team license | $30/mo base, +$20 per extra seat, max 50 | `plans.ts`, 2 included |
| dusk cloud Plus (shared_s) | $20/mo, 2 vCPU 4 GB 20 GB disk | upload soft caps 30/40/55/70/90/100 GB per month, bot computers 2 |
| dusk cloud Pro (shared_m) | $38/mo in code (`3800`) but docs say $50 with license | 4 vCPU 8 GB 60 GB, 5 bot computers, priority |
| Dedicated (Team cloud machine) | quoted (null in code); `limits.md` says $119 | 8 vCPU 16 GB 160 GB |

Discrepancies to note, not verified: Pro price differs between code and doc; CHANGELOG 0.2.15 says dusk cloud "starts with 3 days free", while `limits.md` says "Free trial: none (trial: null)" (checked 2026-11-13). Payment processor Dodo, 6% + $0.40 fee noted.

Hard limits that matter for us:
- Clouds per account 5; computers per account 50 (local).
- Sign-in mail: 6/hour and 12/day per address; 250/day global (Brevo free tier).
- Published pages 50 per account.
- Bot API and relay: 3 MiB/s per tunnel, 25 GiB per tunnel per day, 20 tunnels per account.
- Cloud auto-sleep 15 min after last input; backups daily, 3 kept.

Money levers they name: cloud machine compute (InstaBox), egress, sign-in email. They say "we pay for no one's AI".

## 7. CHANGELOG order (what they shipped, oldest to newest)

- 0.2.0 "first light": bots with jobs, memory, routines, rooms, computer, phone (preview), 60+ connectors, dusk cloud plans, privacy.
- 0.2.3: first answer guaranteed for new people (free model hand-off after 25 s), sign-up in browser with plan checkout, own-server install line with IPv4 retry.
- 0.2.4-0.2.5: free-model quota messaging, connected AI always first.
- 0.2.6: server bots move to a new dusk cloud automatically.
- 0.2.7: Windows x64 and Linux x64 builds, less first-run asking, Copilot/Cursor sign-in in background.
- 0.2.8: Mac self-update in the sidebar, stop ends turn at the press.
- 0.2.9: browser signup returns signed in, no code paste, connected apps sync.
- 0.2.10: model chip shows the active AI after fallback, voice problem card.
- 0.2.11: welcome flow and "what this Mac holds" first.
- 0.2.12: memory quality (dated facts, merge duplicates), setup imports from other apps, encrypted Vault move to cloud, smoother motion.
- 0.2.13: chat without tool receipts, feedback from sidebar, permission step, rooms answer in own chat, Mac-only permissions asked once.
- 0.2.14: fresh install starts clean, no keychain prompts from other apps, AI never signed in without button press.
- 0.2.15: free model first in picker, iPhone QR pairing, plain-words error messages, 3-day free cloud trial, sign-in via browser for Codex.

Priority pattern: (a) first-run friction and sign-in, (b) reliability of the first reply, (c) cross-platform, (d) memory quality, (e) import from competitors, (f) plain-language errors, (g) cleanup of chat UI. Almost no new agent-capability items in the last 6 releases; the work is on onboarding, trust and polish.

## 8. Ten product ideas worth taking (ranked by user value)

1. **Room responder modes per room** (everyone / mentions-only / auto-pick / lead). Users choose how a multi-bot thread behaves. Evidence: `src/lib/group-routing.ts` (`roomRouteForComposer`, `effectiveDefaultResponder`), `server/routes/groups.ts` (`checkedGroupResponder`), `docs/decision-model.md`. For us: start with mentions and lead; auto-pick can be a cheap classifier later. Refuse ambiguous @names instead of guessing.
2. **Leader bot with hand-off caps.** One bot plans and delegates with a roster and caps (3 rounds, 8 tasks per message), members report back in 1-2 lines and must not re-delegate. Evidence: `server/room-leader.ts` (`leaderSystemNote`, `memberSystemNote`, `leaderCapRefusal`). This is the closest thing to "groups with teams" and it is cheap to build on our existing coordination.
3. **Per-bot approval levels with a clear rule: reads never ask, writes/sends/deletes ask, plus a separate "sending on your behalf" daily cap.** Evidence: `docs/approval-levels.md`. Good model for our Agents risk UI; the daily cap is a money-safe default.
4. **Provenance tag on every line a bot reads** (`[From <who> · <what> · <authority>]`), written by the server, not the sender. Stops prompt-injection via shared rooms. Evidence: `docs/team-cloud.md` ("Who is speaking"). Strong for multi-human agents.
5. **Routine checks as plain code before any AI turn** so quiet ticks cost nothing; natural-language to cron with a preview of next 3 dates and Edit/Pause/Undo. Evidence: `docs/routine-schedules.md`, `docs/proactive-routines.md`. Direct cost saver for our routines.
6. **Memory with provenance and reversibility**: each line carries date and "learned by <bot>", superseded facts kept as history, "Replaced or merged" list with Restore, nightly tidy, journal with undo. Evidence: `docs/memory.md`. Users can audit what the agent knows.
7. **Vault: secrets filled into tools without the AI ever seeing them.** Evidence: README "Keep secrets" and "Vault and moving in"; `docs/approval-levels.md` for the related rule. Pair with our connector scope.
8. **Share a team as a file, scrubbed and inert on import.** Import is additive, rolls back fully on failure, skills arrive off, routines arrive paused, connections arrive switched off with empty values, and secrets are removed before save. Evidence: `docs/team-sharing.md`. Good template for our "share an agent" feature.
9. **Connector tiers: one-click vendor MCP > pasted token checked live > own Composio account.** No per-call cost for us; each app uses the person's own account. Evidence: `docs/composio.md`, `docs/custom-mcp-servers.md` (paste any `claude mcp add` line and it parses it; placeholders like `YOUR_API_KEY` are never saved).
10. **First run that asks the price-and-place question first, no account wall, and a single "Use this Mac instead" escape.** First reply is the goal; two tap-able first jobs in the empty chat. Evidence: `docs/onboarding-funnel.md`, `AGENTS.md` (seeded test bots). Also note "Skip for now" sits at full strength.

Honourable mentions (not in top 10): per-bot Bot API with key shown once and hashed (`docs/bot-api.md`); Sentinel out-of-process health scanner (`docs/sentinel.md`); "Take control" of the bot's computer for sign-ins (README); tokens shown in chat as "reads only" chips per tool (`docs/approval-levels.md`).

## Not verified / gaps

- Did not read `server/routes/internal-tools.ts` to confirm the exact `coordinate_bots` schema.
- Did not verify member caps for rooms, or whether human-to-human chat exists outside Team Cloud.
- Pricing: code vs docs disagree (Pro price, free trial). Treat both as unconfirmed.
- Did not run the app.
