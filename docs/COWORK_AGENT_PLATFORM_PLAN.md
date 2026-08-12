# CoWork — Agent Platform Plan

**Status:** planning, no product code yet (a throwaway local demo was built and is
being discarded). **Last reworked:** 2026-08-12, after four subagents read the
real source of Hermes Agent (Nous, MIT) and firecrawl/anydoc (MIT).

This document supersedes the *shape* of `docs/COWORK_EXECUTION_PLAN.md` (a
single-session desktop↔phone mirror). What survives from that plan: the relay,
the `cowork_frame*` crypto primitives, and the client-side approval model.

Sections are numbered so feedback can point at them (e.g. "§7.5, change the
trigger threshold").

---

## 1. What this is

chuk_chat gains **two modes**:

1. **Normal chat** — you talk to a model. Unchanged.
2. **Agent chat (CoWork)** — a **messenger, like Slack**, whose contacts are
   **AI agents that behave like coworkers**. You have a roster of them. You
   message an agent a task (with files, links, context, or a screen recording);
   it goes off and *does the work* on its own machine — shell, browser, APIs —
   and streams its run back into the thread. It works when triggered and on a
   schedule, autonomously, and keeps running when the app is closed.

An agent does not "answer" like a chatbot; it **works**, and you watch the work
stream in (Hermes / Claude-Code style): collapsible tool-call lines, a **Stop**
button, files and screenshots delivered as cards. You onboard an agent by
telling it its standing job ("every week, fetch the crypto news and summarise
it"); it gets a random name, runs on a weekly trigger, and posts results.

The essence: **you assemble a team of specialised, always-running AI coworkers,
give them tasks and revocable access, and they do the work autonomously on your
own machine.**

---

## 2. Glossary

- **Host** — a Linux machine (a server or the user's laptop) the user owns and
  sets up, running the platform. Single-user.
- **Manager** — the control-plane process on the host: roster, sandbox
  lifecycle, scheduler, relay bridge.
- **Agent (coworker)** — a Workspace (persona + files + memory + skills + job +
  schedule) bound to a sandbox. Identified by an auto-assigned name.
- **Sandbox** — a per-agent container (Debian-like, isolated FS, sudo,
  installable) where that agent's Python runtime executes.
- **Controller** — the Flutter app (phone or desktop). UI only: the messenger,
  roster, live run view, in-UI controls.
- **Executor** — the Python agent runtime inside a sandbox.
- **Relay** — `cowork_relay` on `api.chuk.chat`; a blind proxy of encrypted
  frames between controller and executor.
- **Session / thread** — one conversation with an agent (an agent can have
  many).

---

## 3. Topology

```
 Flutter app (controller, UI only)          the user's Host (single-user)
 ┌───────────────────────────┐              ┌──────────────────────────────────┐
 │ messenger · roster        │   E2E over   │ Manager (control plane)          │
 │ live run view · Stop      │◄── relay ───►│  roster · lifecycle · scheduler  │
 │ skills/connect/model UI   │   (blind)    │  relay bridge                    │
 └───────────────────────────┘              │   ├─ sandbox: agent "amber"      │
            ▲                                │   │    Python runtime + tools    │
            │ model I/O (not E2E)            │   ├─ sandbox: agent "cobalt"     │
            ▼                                │   └─ sandbox: agent "…"          │
   api.chuk.chat (backend)  ◄───────────────┘  each = a Debian container
   model routing · relay · OAuth token vault    (browser, ffmpeg via host, …)
```

- **The relay carries only encrypted blobs** (§14). **Model I/O routes through
  the backend** (§7.4) and is therefore visible to the backend — E2E covers the
  control/mirror channel, not model calls. This distinction is deliberate and
  must not be oversold.
- **The Flutter app is UI only.** No agent logic runs in Dart. chuk_chat's
  existing "run a few basic bash commands in normal chat" stays as-is, not
  extended.

---

## 4. The agent (coworker) = a Workspace

An agent reuses the existing `FEATURE_WORKSPACES` concept (persona + files +
memory). It carries:

- **Identity** — an auto-assigned random name.
- **Job / persona** — its onboarding brief: the standing system prompt + what it
  should do. Onboarding is by **text** *or* by **video demonstration** — you
  record yourself doing a task, send the clip, the agent analyses it
  (multimodal, via the backend vision model) and takes the task over. "Show,
  don't tell." A demonstrated task can be distilled into a Skill (§11).
- **Files** — documents/links/context you hand it.
- **Memory** — its own persistent notebook (§12).
- **Skills** — markdown `SKILL.md` procedures it loads on demand (§11).
- **Schedule** — optional recurring triggers (§13).
- **Credentials** — revocable OAuth/API doors, never raw secrets in the box
  (§10).

**Multiple chats per agent** (same sandbox, separate threads) and
**multi-agent collaboration** — several agents in one thread, talking to each
other like teammates while you assign targeted tasks (§7.6).

Open decision: reuse the Workspace entity directly, or a thin "Agent" entity
that *wraps* a Workspace. (§20)

---

## 5. Host & Manager

- **One host, many agents.** The host is the office; agents are the people in
  it. On a server (e.g. 64 GB) or the user's own laptop.
- **Single-user.** Everything on the host is one user's. Isolation between
  agents is for **credential compartmentalisation and clean disposable
  environments**, not defending against a hostile tenant.
- **Install = one shell script + `connect`.** The script installs/checks the
  container runtime, pulls the base image, installs the Manager as a **systemd
  service**; `connect` does the device-login/pairing once (§15). From then on it
  runs automatically. The user sets up their own OS, NVIDIA drivers, etc. — not
  the platform's concern.
- **No KVM required** (§6).

The **Manager** (Python) holds the roster (SQLite), starts/stops/supervises the
per-agent sandbox containers, runs the **scheduler** (§13), bridges the
**relay** (§14), and sends push notifications on completion/approval.

---

## 6. Sandbox: one container per agent

- **Container-grade, not a VM.** Each agent runs in its own **container**
  (Debian-like, own isolated filesystem, **passwordless sudo**, can
  `apt install` / install anything — its own little Debian box). **No
  Firecracker, no KVM.** Container-grade isolation is enough for a single-user
  host; VM-grade would only add the KVM dependency for no gain here.
- **Why a sandbox at all, single-user?** Each agent needs a fresh disposable
  Debian it can install into and trash without wrecking the host base or other
  agents.

**Borrowed design — the sandbox abstraction (Hermes, MIT):**

- **`BaseEnvironment` ABC with a 2-method surface** (`tools/environments/base.py`):
  subclasses implement only `_run_bash(cmd, login, timeout, stdin) ->
  ProcessHandle` and `cleanup()`; everything else (execute, timeout, bounded
  output, cwd tracking) lives in the base. Our container is one subclass; local
  / SSH / E2B slot in the same way, chosen by a factory keyed off an env var.
  `ProcessHandle` is a `Protocol` so an async cloud SDK can masquerade as a
  local subprocess.
- **Snapshot-file session persistence instead of a long-lived shell** — the
  single highest-value steal. Every command runs a *fresh* bash wrapped as
  `source <snap>; cd <cwd>; <cmd>; re-dump env to <snap>; emit cwd marker`,
  snapshot rewritten atomically (`mktemp`+`mv`). Env/aliases/functions/cwd
  survive between tool calls with **no PTY to babysit** — backend-agnostic and
  crash-safe.
- **Container lifecycle:** session-scoped container per agent (Hermes keys reuse
  off Docker labels + a `task_id`; `task_id != default` → torn down at session
  close). Orphan reaper for containers left by a killed prior run.

**Tools: inside the sandbox vs passed through from the host (§9).** Most tools
run inside; a few host binaries (ffmpeg) are passed through where in-sandbox is
inefficient.

---

## 7. The Python agent runtime

Written in **Python** because the tool ecosystem (browser-use, document
handling, research) is far richer there than in Flutter. Built on **`uv`**.

### 7.1 The loop

- Claude-Code-style: system prompt (onboarding brief) + tool loop + tool
  registry, many rounds, autonomous.
- **Continue-vs-finish is structural**: did the model emit tool calls? Tool
  calls → execute, append results, continue. Bare text → final answer, break.
  (No text-pattern heuristics — matches chuk_chat's existing rule.)
- **Dual-counter termination** (Hermes `iteration_budget.py`, ~62 lines,
  MIT): a hard `max_iterations` ceiling **plus** a refundable budget —
  housekeeping/preflight rounds `.refund()` so they don't burn the model's real
  thinking budget while termination stays guaranteed.
- **Two-tier kill switch**: a fail-safe **file-sentinel ESTOP** (pauses *new*
  work; a stat error is treated as engaged) + a **thread-flag interrupt**
  polled at loop top (cancels in-flight). Powers the app's **Stop** button.
- **Stop-guard-as-nudge**: pure-policy modules that, when the model narrates
  completion without doing the required terminal action, inject a synthetic
  nudge and loop 1–2 more times.

### 7.2 Tools

- **Self-registering registry** (Hermes `tools/registry.py`): each tool calls
  `register(name, toolset, schema, handler, check_fn, is_async)` at import; a
  `dispatch()` bridges async, normalises results, and **bounds/sanitizes errors**
  (2048-char cap) so a tool can't stack an unbounded error body across retries.
  Schema-driven **arg coercion** (`"42"→42`) because models send stringy args.
  `check_fn` is a per-tool availability probe with a **TTL + grace cache** (a
  flaky `docker version` doesn't strip a whole toolset).
- **Tool Search / progressive disclosure** (Hermes `tools/tool_search.py`):
  when the deferrable tool surface exceeds ~10% of the context window, MCP/plugin
  tools are replaced in the prompt by three bridge tools (`tool_search` /
  `tool_describe` / `tool_call`); core tools are never deferred. Saves tens of
  thousands of prompt tokens once there are many tools. Mirrors chuk_chat's
  existing skills progressive-disclosure instinct.

### 7.3 Context / long-run cost ladder (the money lever)

The whole cost story for long autonomous runs. Borrowed from Hermes
`agent/context_compressor.py` (NOTE: root `trajectory_compressor.py` is a decoy
— an offline training tool, not the runtime compressor).

- **Trigger on a fraction of the *effective* input budget** (`context_length −
  reserved_output`), counting **prompt_tokens only** (so thinking models don't
  over-trigger). Tool-schema tokens count toward pressure.
- **Tiered escalation:**
  1. **Deterministic, no-LLM pre-pass** on a low threshold: dedup byte-identical
     tool results and back-reference them (lossless), truncate oversized
     non-tail tool outputs and bloated tool-call args. Reclaims most waste
     before spending a cent.
  2. **Cheap aux-model summarization of the middle** at ~50%, into a fixed
     template (Goal / Constraints / Completed / Active / Blocked / Decisions /
     Files / Critical), "summarize don't answer" preamble, forced secret
     redaction, **past-tense anchoring** so a resumed run doesn't re-issue
     finished actions.
  3. **Iterative re-summarization**: later passes *update* the prior summary
     rather than regenerate.
- Head verbatim; **tail by token budget, not message count** (never split a
  tool_call/result pair). **Anti-thrashing guard**: skip if the last two passes
  each saved <10%.
- **`think_scrubber`**: a streaming state machine that strips
  `<think>/<reasoning>` from deltas before any consumer sees them, and replays
  only the newest turn's reasoning (older stripped at send).

### 7.4 Model routing & provider abstraction

- **Model calls route through `api.chuk.chat` (backend proxy) with the account
  token.** Centralised billing/account, no provider keys in sandboxes, one auth.
- **Two-axis abstraction** (Hermes): declarative **ProviderProfile**
  (auth/quirks, declares an `api_mode`) × **ProviderTransport** (wire format per
  API family) × the agent (owns client/streaming/retry). For us the **backend is
  the agent layer** and provider profiles are config rows — but the split is
  worth mirroring server-side.

### 7.5 State persistence (survives the app closing)

Borrowed from Hermes `hermes_state.py` (SQLite, MIT):

- **Single WAL SQLite file**, append-only `messages` rows; `sessions` carries
  lineage/token/cost counters; an FTS5 mirror kept synced by triggers.
- **Resume by `WHERE session_id=? ORDER BY id`** — autoincrement id, **never a
  wall-clock timestamp** (mobile clocks jump on sleep/NTP and would reorder
  tool-call/response pairs).
- **`session_key → session_id` routing table** so an app relaunch finds the
  right run with no server state — the piece chuk_chat doesn't have yet.
- `BEGIN IMMEDIATE` + jittered retry on "database is locked"; JSON-in-columns
  (no pickle). A killed process loses at most the last uncommitted turn.

### 7.6 Subagents / multi-agent collaboration

Borrowed from Hermes `tools/delegate_tool.py` + `agent/subagent_lifecycle.py`:

- A `delegate_task` tool spawns isolated child agents, single or **batch/
  parallel**. Each child gets its **own `task_id` → its own sandbox** — so
  parallel subagents = parallel sandboxes for free. We **promote Hermes's
  in-process threads to one child container per subagent** since we already have
  the container layer.
- Serializable **handle + registry** (surface subagents in the Flutter app),
  **live streaming** of child output up to the parent, a **parent-activity
  heartbeat** (so a parent blocked waiting on children isn't timeout-killed),
  **steer/interrupt** of running children, and depth/concurrency/pause caps.
- This is also the substrate for the product's **multi-agent-in-one-thread**
  collaboration (§4): agents addressing each other is delegation + a shared
  group thread. (Group-thread model beyond delegation: open, §20.)

---

## 8. Capability model — structured tools, not a machine to drive

Reference: "agent in a VM" products (xAI/Grok, Cursor background agents) hand the
agent a full machine and, in some demos, hand the *user* the VM over **VNC** to
type credentials into. **We deliberately do not.**

**Capability hierarchy, best to worst:**

1. **First-class API tools** (hand-built, §9) — the primary path.
2. **browser-use** — the *fallback* for services with no usable API (or official
   scraping).
3. **Graphical computer-use / VNC / desktop control** — essentially never; a
   far-later add-on at most. Starting a desktop is explicitly rejected.

Most apps people use (LinkedIn, etc.) have an API; an agent over the API is ~10×
more efficient than driving the same site in a browser. Browser-first is what
competitors do and it is the wrong default.

---

## 9. Tools & the stack

**Runtime:** Python 3.12, deps via **`uv`**. HTTP: `httpx`. A broad default
toolset ships preinstalled so the agent has tools ready without a cold install.

**Inside the sandbox (default):**
- **Browser:** **browser-use** (MIT, self-hosted) + Playwright + Chromium. Free;
  we pay only LLM tokens (which route through the backend). Not the Playwright
  MCP server — a higher-level agent-browser library.
- **File → markdown:** **anydoc** (firecrawl, MIT, fully offline, no API key).
  One dependency (`pip install firecrawl-anydoc`) replacing pandoc + python-docx
  + LibreOffice + pypdf for ingestion of doc/docx, ppt/pptx, xls/xlsx, odt, rtf,
  epub, csv, and **text-based** PDF; ~250× faster than LibreOffice. Gap: no OCR,
  no standalone images → route those to a **vision model via the backend** (no
  Tesseract). Pattern: try `anydoc.to_markdown(...)`, on `UnsupportedError` →
  vision path.
- **Media:** `ffmpeg`/`ffprobe` (ffmpeg via host passthrough, below), **yt-dlp**.
- **Docs out:** `python-docx`/`openpyxl`/`python-pptx` where the agent must
  *write* office files (anydoc only reads).
- **send-file-to-user:** push any produced file (CSV/PDF/image/generated
  doc/**browser screenshot**) into the chat thread. Reuse chuk_chat's existing
  `send_file_to_user` → `sandboxArtifact` block (renders as a download/preview
  card).
- **search-chats:** cross-session recall (§12) — every chat is a read-only,
  live-linked markdown transcript searchable via SQLite FTS5.

**Passed through from the host (the exception):**
- **ffmpeg** — running it inside the container is inefficient (CPU-only). The
  agent's ffmpeg work uses the **host's** GPU-accelerated ffmpeg (the user set up
  their NVIDIA box) operating on the sandbox's workspace files. This is *not* GPU
  passthrough into a VM — a host-side binary acting on the sandbox's files.
  Implementation detail (host-executes-on-shared-mount vs `--gpus` into the
  container): open, §20.

**Integration strategy — hand-built API tools first, MCP as fallback:**
- **Build our own first-class tools for the top ~100 services** (REST/GraphQL/
  official SDKs), tailored for the agent, with **revocable credential delegation
  (§10)** wired in — a reason to own them rather than trust third-party glue.
- **MCP is a fallback, not the primary protocol.** Client = the official `mcp`
  python SDK (all three transports, persistent transport thread). Replace an MCP
  server with a native tool when it serves the agent better.

---

## 10. Credentials — revocable API doors, never raw secrets

- Third-party access (GitHub, Google, Slack, a crypto source, …) goes through
  **revocable OAuth tokens / API keys obtained via the app's existing connection
  flow** — chuk_chat's `FEATURE_SERVER_TOOLS` today. The user connects a service
  once on the app side; the token lives **server-side**; the agent calls a tool
  the backend executes with it. **The raw secret never enters the sandbox** and
  access is revocable anytime. No VNC, no passwords typed into a box.
- **MCP OAuth callback — solved (Hermes dashboard-mediated bridge,
  `tools/mcp_dashboard_oauth.py`).** Our open problem (an MCP server's localhost
  callback is unreachable inside a sandbox) dissolves: **do not proxy into the
  sandbox.** Terminate the OAuth redirect at the **relay/backend public URL**
  (`/oauth/callback/{server}`), correlate the pending flow by a **constant-time
  `state` compare**, and hand only the `code` to the sandboxed agent via an
  Event-gated wait. The sandbox needs no inbound port and no tunnel. Our app +
  blind-relay topology fits this better than Hermes's does.
- Open: verify the connect-and-delegate flow with a sandbox executor; per-agent
  scoping of connections. (§20)

---

## 11. Skills

- **Format = markdown `SKILL.md` + YAML frontmatter**, the same shape as Claude /
  agentskills.io / chuk_chat's `FEATURE_SKILLS`. `name` + `description` sit in
  the always-on prompt; the body loads on demand (progressive disclosure).
  Confirmed identical in Hermes (`skills/**/SKILL.md`).
- **Background-review self-improvement fork** (Hermes `agent/background_review.py`
  — the crown jewel). After a qualifying turn, fork a **whitelisted (memory +
  skill tools only)** agent that replays the transcript, **inherits the parent's
  runtime to reuse the prefix cache** (near-free), and writes/updates
  skills+memory **without touching the live conversation** (prompt cache
  preserved). Steal near-verbatim:
  - the review prompt + its **negative-capture list** (do NOT record
    env-specific failures, "X is broken" claims that harden into refusals,
    transient errors, one-off task narratives, dead-ends dressed as best
    practice),
  - **class-level umbrella skills** (not one-session-one-skill),
  - **provenance / protected-skills** boundary (the curator only edits skills it
    itself created),
  - a **read-before-write guard** (may only patch content it actually read).
  - Trigger: a tool-iteration interval (default 10).

---

## 12. Memory / notebook

Two stores (Hermes `tools/memory_tool.py` + `hermes_state_search.py`):

- **(A) Curated declarative markdown** — `MEMORY.md` (agent's own notes) +
  `USER.md` (about the user). Injected as a **frozen snapshot at session start**;
  mid-session writes persist to disk immediately but **do NOT mutate the system
  prompt**, so the prefix cache survives the whole session (snapshot refreshes
  next session). Single `memory` tool with `add/replace/remove` matching on a
  **short unique substring** (cheap for the model), **character** limits
  (model-independent), and an **injection/exfil scan** before content enters the
  prompt.
- **(B) Full-text session search, no LLM** — SQLite **FTS5** over the message
  store: three virtual tables (main / CJK / trigram), BM25, sanitized MATCH,
  lineage-aware dedup, returning **±5 anchored messages + bookends**. Powers
  **search-chats** (§9) and cross-session recall. (Hermes's README claims "LLM
  summarization" but the code removed it — raw anchored windows beat an
  embeddings/summarizer pipeline for cost and determinism.)
- **Every chat is persisted as a read-only, live-linked markdown transcript**
  the agent can find and read.
- Memory lives **per agent, on the host**. Cross-host sync (encrypted under the
  channel key) is deferred (§20).

---

## 13. Scheduling, cron & autonomy

Borrowed from Hermes `cron/` (MIT):

- **The model emits the schedule string; a tiny deterministic parser** handles
  four forms: `every 30m` (interval), `0 9 * * *` (cron, validated by
  `croniter`), ISO `2026-02-03T14:00` (one-shot, **timezone-anchored** to avoid
  drift), `30m/2h/1d` (one-shot from now). NL understanding is the model's job;
  the parser stays small and deterministic.
- **At-most-once firing:** advance-next-runs **before** execution under a lock,
  plus a claim/heartbeat so a long run isn't re-dispatched. A ticker runs every
  60 s.
- **Unattended run:** a fired job builds a fresh agent with `skip_memory` +
  `skip_background_review` (no human present), an **inactivity (not wall-clock)
  timeout** (a job can work for hours but a hung API call is killed), and
  **auto-delivers its final response to the origin chat**; a `[SILENT]` marker
  suppresses empty deliveries. `attach_to_session` makes a job continuable (you
  can reply into it).
- **Cost levers:** `no_agent` mode runs a bare script on schedule (zero tokens);
  **hash-diff monitor** mode hashes a source each tick and **wakes the LLM only
  when the bytes change** (injects a unified diff) — turning N polling LLM calls
  into ~0.
- **App-closed persistence + push wake:** the run continues in the sandbox with
  the app closed; the Manager pushes a notification on completion or when
  approval is needed; reopening shows the result.
- Open: scheduler on the host vs backend-driven (what fires a weekly job if the
  host is off?). §20.

---

## 14. Transport & crypto

- **Relay = blind proxy** on `api.chuk.chat`; forwards encrypted frames, stores
  nothing. Needs the **cross-replica fix** (prod runs 2 replicas with an in-RAM
  presence map → controller and executor can land on different replicas and
  never meet; fix = peer-to-peer between replicas over Swarm DNS, no DB — see the
  old execution plan's `relay-crossreplica`). A careful prod deploy and a real
  prerequisite.
- **Frame contract & transport patterns** (Hermes `gateway/relay/` +
  `tui_gateway/`): one **JSON-RPC dispatch behind a `Transport(Protocol)` seam**
  — never fork handler logic per transport; **Bearer-token auth on the WS
  upgrade**; **newline-delimited JSON frames** correlated by `requestId`; a
  **capability-descriptor handshake** (the app declares what it can render); a
  **reconnect supervisor** one layer above a dumb read-loop (backoff, re-dial,
  re-handshake). We're already aligned (relay + WebSocket); adopt these
  specifics.
- **E2E** on the control/mirror channel via a **fresh CoWork channel key**
  established at pairing (X25519 ECDH between controller and executor), **not**
  the chat account key — avoids reproducing the account-key derivation in Python
  and putting a password on a headless host, and decouples CoWork crypto from
  chat crypto. The Dart `cowork_frame*` primitives get repointed from the account
  key to this channel key (cheap, not yet wired) and gain a **byte-identical
  Python twin** (`cryptography`: AES-GCM, Ed25519, X25519) with shared test
  vectors.
- **Honest boundary:** model I/O routes through the backend (§7.4), so E2E means
  "relay/control channel is blind," not "backend sees nothing."

---

## 15. Pairing / `connect`

- **The account login is the authentication.** The host/agent connects to
  `api.chuk.chat`, does a **device-login code flow** (so a headless server is
  easy), gets an account token, and registers as an executor on the relay,
  publishing an Ed25519 identity. It appears in the user's device list.
- **The phone approves it locally** — client-side approval, the server never
  holds an approval flag. Approval is also where the **channel-key ECDH** is
  stamped (§14).
- Exact flow and where the ECDH lands: open (§20).

---

## 16. The Flutter app (control surface)

- **A new, separate Flutter app**, not grafted onto chuk_chat — less legacy, a
  clean messenger UI, fewer merge problems; the two codebases merge later.
- **Copy only the basic security stack** from chuk_chat (~28 files; the port
  manifest is Appendix A): Supabase auth/session/token, `encryption_service`,
  the multiplex WebSocket transport, and the `cowork/` crypto primitives. Cut the
  chat UI, workspaces, tools, and the discarded loopback demo; trim
  `AuthService.signOut` so sandbox/cache/chat deps fall out; reimplement the
  auth gate + login minimally.
- **UI:** a messenger — roster of agents, one thread per conversation,
  Hermes-style streaming run with collapsible tool lines and **Stop**, file/
  screenshot cards.
- **In-UI control surface (the moat, §17):** activate/deactivate skills,
  connect/disconnect integrations, pick/see the model, live **token usage**,
  **session runtime**, and the **cron schedule / next runs** — all in the GUI,
  not a CLI. Slash-commands optional, never the boundary.

---

## 17. Positioning & moat (vs Hermes Agent)

Hermes Agent (Nous, MIT) validates the stack almost 1:1 — Python, container
sandbox, `SKILL.md` skills, cron, MCP, subagent delegation, agent memory. We are
not inventing an unproven shape; we are **borrowing a proven one under a
permissive licence** (§18).

Where we win:

- **We own the whole pipeline front to back** — the app, the backend, the relay,
  the sandbox, model routing. Hermes is a bring-your-own-provider CLI plus
  messaging gateways. Owning the pipeline = one integrated account, billing, and
  experience, and control over every layer.
- **A real GUI control surface, not a CLI/slash-command bot** (§16). Hermes is a
  terminal/TUI + messaging platforms configured with CLI commands. Ours is a full
  app. This is the "real app" vs "bot bolted onto Telegram" difference.
- **API-first over browser, and no VNC credential handoff** (§8, §10).

---

## 18. Licensing & provenance

- **Hermes Agent — MIT** (Copyright 2025 Nous Research). We may lift code
  verbatim, modify, and ship closed-source, **provided the MIT notice travels
  with substantial copied portions**. Reimplementing the design from these notes
  carries no obligation. (Two skill bodies under `skills/productivity/pdf|
  powerpoint/` are Anthropic-derived with their own LICENSE — check those
  individually; the engine code is all MIT.)
- **anydoc — MIT** (Sideguide Technologies). Free self-host, commercial use OK.
- **browser-use — MIT.** Free self-host; optional paid cloud we don't use.
- **Discipline:** whether we copy code or reimplement, keep a NOTICE for
  verbatim files. Prefer reimplementing the *design* where the Hermes code is
  tangled with their gateway/kanban/codex specifics.

---

## 19. Decisions locked (2026-08-12)

- Executor = **Python** agent in a **per-agent container** (Debian, sudo,
  installable), **no microVM/KVM**; sandbox modelled on the `BaseEnvironment` ABC
  + snapshot-file persistence.
- **One host, many agents; one container per agent.** Install = shell script +
  `connect`. Single-user; container-grade isolation.
- **Agent = Workspace** (persona + files + memory + skills + job + schedule).
- **Capability hierarchy:** hand-built API tools → browser-use fallback →
  computer-use/VNC never. MCP is a fallback protocol.
- **Model routing through the backend proxy.** **Full E2E** on the control
  channel via a fresh channel key (not the account key).
- **Flutter = UI only**, a **new app** copying the security stack; existing basic
  bash-in-chat stays. The moat is the owned pipeline + GUI control surface.
- **Borrow from Hermes (MIT):** sandbox ABC + snapshot persistence; MCP
  dashboard-OAuth callback bridge; subagents as task_id-scoped containers;
  dual-counter loop + kill switches; self-registering tool registry + Tool
  Search; cost-tiered context ladder; append-only SQLite state (ORDER BY id +
  routing table); frozen-snapshot memory + FTS5 search; background-review
  self-improvement fork; LLM-emits-schedule cron + no_agent/hash-diff cost
  levers; JSON-RPC-over-transport-seam + relay frame contract.
- **File→md = anydoc**; OCR/images = vision model via backend (no Tesseract).
- **Tools built on Python + `uv`.**

---

## 20. Open questions

- Agent = reuse the Workspace entity directly, or a thin "Agent" wrapper?
- Multi-agent group-thread model beyond delegation: how several executors + the
  user share one conversation and address each other.
- Global-memory cross-host sync: when and exactly how (encrypted under the
  channel key).
- Pairing/device-login exact flow and where the channel-key ECDH is stamped.
- Scheduler: host-local vs backend-driven (offline-host case).
- Credential flow: verify connect-and-delegate with a sandbox executor; per-agent
  connection scoping.
- ffmpeg host passthrough mechanism: host-executes-on-shared-mount vs GPU device
  into the container.
- Relay cross-replica fix: before or alongside the first Python executor.
- Top-~100 API tool catalogue: which services first; the shared tool/credential
  shape.
- Own thin loop vs a graph framework for multi-agent (leaning: own thin loop).
- Manager as FastAPI vs a bare async process.

---

## 21. Build order (to become milestones)

1. **Relay cross-replica fix** (prod, careful) — unblocks reliable connect.
2. **Crypto:** repoint the Dart frames to a channel key + Python twin + shared
   test vectors.
3. **Pairing / device-login / local approval** for a Python executor.
4. **Minimal Python runtime** (loop + self-registering tools + shell +
   append-only SQLite state) in one container, driven from a minimal Flutter
   messenger, streaming back — end to end.
5. **Manager**: shell-script install + `connect`, roster, per-agent container
   lifecycle (BaseEnvironment subclass + snapshot persistence).
6. **Memory + skills**: frozen-snapshot MEMORY.md/USER.md, FTS5 search,
   `SKILL.md` loading, then the background-review fork.
7. **Tool set**: browser-use, anydoc, host-ffmpeg passthrough, send-file,
   search-chats; the first native API tools; MCP client + dashboard-OAuth bridge.
8. **Context cost ladder** (dedup pre-pass → aux-model summary).
9. **Scheduler / cron** (LLM-emits-schedule + parser, unattended runner, no_agent
   + hash-diff monitor) + push wake.
10. **Subagents / multi-agent** collaboration (child containers, handles).
11. **New Flutter app UI**: full messenger + the in-UI control surface (skills,
    connect, model/token/session/cron).
12. Hardening, memory cross-host sync, GPU, the wider API-tool catalogue.

---

## Appendix A — security-stack port manifest

The exact `lib/` files to copy from chuk_chat into the new app, leaf-first (from
the inventory pass). Cut the demo/loopback files; trim `signOut`; reimplement the
auth gate + login.

```
lib/web_env.dart
lib/platform_config.dart
lib/utils/io_helper_stub.dart · io_helper_io.dart · io_helper.dart
lib/env_loader.dart
lib/supabase_config.dart
lib/services/api_config_base.dart · api_config_service_io.dart ·
  api_config_service_stub.dart · api_config_service.dart
lib/services/network_status_service.dart
lib/services/supabase_service.dart
lib/utils/certificate_pinning.dart · certificate_pinning_io.dart   (rotate pins)
lib/services/websocket_connector_web.dart · websocket_connector_io.dart ·
  websocket_connector.dart
lib/models/chat_stream_event.dart
lib/services/tool_result_cache_registry.dart
lib/services/multiplex_connection.dart · multiplex_session.dart
lib/services/encryption_service.dart
lib/services/auth_service.dart            (trim signOut → drop sandbox/cache deps)
lib/services/cowork/cowork_frame.dart · cowork_replay_guard.dart ·
  cowork_device_keys.dart · cowork_approved_devices.dart · cowork_frame_codec.dart
```

pubspec subset: `supabase_flutter, cryptography, crypto, flutter_secure_storage,
shared_preferences, web_socket_channel, uuid, http` (+ `dio` only if cert
pinning stays). Required env: `SUPABASE_URL`, `SUPABASE_ANON_KEY` (+ optional API
routing + `FEATURE_LINUX_KEYRING`).

Do NOT copy: `widgets/auth_gate.dart` (drags full app bootstrap),
`pages/login_page.dart` (reference only), `websocket_chat_service.dart` (drags
image storage — port only if wanted, cut the image branch), and all of
`cowork/cowork_executor_bridge.dart` + `cowork_demo_server*.dart` (the discarded
demo).
