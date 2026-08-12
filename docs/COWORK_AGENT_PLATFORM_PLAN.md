# CoWork — Agent Platform Plan (fundamentals)

Status: **planning, no code yet.** Captured from a design discussion on
2026-08-12. This supersedes the *shape* of `docs/COWORK_EXECUTION_PLAN.md`
(which described a single-session desktop↔phone mirror). The relay, the crypto
frame primitives, and the client-side approval model from that plan survive;
its "mirror one desktop session" framing does not. This document is the new
north star for what CoWork *is*.

---

## 1. The product, in one picture

The app has **two modes**:

1. **Normal chat** — you talk to a model. Unchanged.
2. **Agent chat (CoWork)** — a **messenger, like Slack**, whose contacts are
   **agents that behave like coworkers**. You have a roster of them. You DM an
   agent a task (with files, links, context). It goes off and *does the work*
   on its own machine — shell, browser, APIs — and streams its run back into
   the thread. It works when triggered and on a schedule, autonomously, like an
   employee.

An agent does not "answer" you like a chatbot. It **works**, and you watch the
work stream into the chat (Hermes / Claude-Code style): collapsible tool-call
lines ("ran `ffmpeg …`"), not every detail, with a **Stop** button to abort the
running task. The output is produced in the sandbox; you see it through the UI.

Example: you onboard an agent — "every week, go fetch all the crypto news and
summarise it." It gets a random name, runs on a weekly cron trigger, and posts
results into its thread. You have several such agents (a crypto-news agent, a
personal assistant agent, whatever), all living on one host.

---

## 2. What an agent is

**An agent = a Workspace bound to a sandbox.** The app already has
`FEATURE_WORKSPACES` = "custom AI personas + files + memory". That *is* the
coworker abstraction. An agent carries:

- **Identity** — an auto-assigned random name.
- **Persona / job** — its onboarding brief: the standing system prompt + what it
  is supposed to do. This is the "onboarding" you write it.
- **Files** — documents, links, context you hand it.
- **Memory** — its own persistent notebook (section 6).
- **Skills** — markdown `SKILL.md` procedures it loads on demand, exactly like
  Claude's Agent Skills (reuse `FEATURE_SKILLS`; see §8a).
- **Schedule** — optional recurring triggers (cron), e.g. weekly.
- **Credentials / access** — revocable OAuth/API doors, never raw secrets in the
  box (see §8b).

Agents are the user's own coworkers, not mutually adversarial — but they hold
*different* credentials, so isolation is about **credential compartmentalisation**,
not defending against a malicious tenant.

**Onboarding by demonstration (video).** Besides writing an agent its brief, you
can **record yourself doing a task and send the agent the video**; it analyses
the recording (multimodal) and can then take the task over. "Show, don't tell."
This fits the API-first stance (§8a): the agent learns *what* you are trying to
achieve and then does it the efficient way (an API call), rather than mimicking
your clicks in a browser. A demonstrated task can also be distilled into a Skill
(§8a) for reuse. Mechanism (how the video is analysed into a repeatable
procedure) is an open item (§13).

---

## 3. Topology: one host, many agents

- **Host** = a machine with Docker/virtualisation — a server (e.g. 64 GB RAM) or
  the user's own laptop. You install the platform on it; it brings the runtime,
  browser, ffmpeg, and everything else.
- **Many agents live on one host.** The host is the office; agents are the people
  in it. **Not** one host per agent.
- Each agent gets its **own container sandbox** on the host (section 4) —
  container-grade isolation, enough because the host is single-user.

The host runs a **Manager / control plane** (installed by the setup script) that:

- holds the agent roster,
- starts / stops / supervises the per-agent sandbox containers,
- runs the **cron scheduler** and fires trigger events (even with no phone
  connected),
- bridges to the relay (section 5),
- sends push notifications when an agent finishes or needs approval.

---

## 4. The sandbox: one container per agent (container-grade, no KVM)

**Decision (settled 2026-08-12): each agent runs in its own container-grade
sandbox — NOT a microVM, NOT native-on-host.**

- A sandbox is a **container** — a Debian-like environment with its **own
  isolated filesystem**, **passwordless sudo**, and the ability to **install
  software** (`apt install`, pip, whatever). The agent treats it like its own
  little Debian box.
- **Not a real VM.** No Firecracker, so **no KVM required** — that is the whole
  reason microVMs were dropped. Plain containers (Docker or an equivalent OCI
  runtime) are the mechanism.
- **Many sandboxes on one host = many agents.** This sandbox layer does not
  exist in the repo yet; it is new.

**Why a sandbox at all, if the host is single-user?** Isolation *between* agents
is not a hard security requirement — everything on the host is one user's. But
each agent still needs a **fresh, disposable Debian environment it can install
into and trash** without wrecking the host base or the other agents. That is
what the container gives: container-grade isolation, which is enough here —
VM-grade (Firecracker) is overkill and costs the KVM dependency.

**Install = one shell script + a `connect`.** The user runs a script on their
host; it sets up the container runtime + the Manager, `connect` does the
device-login/pairing once, and from then on it runs automatically.

**Accepted risk:** the sandbox has passwordless sudo and the host is the user's
own box; a runaway agent can still cost real work. Single-user, self-installed,
opted into — accepted. Worth remembering only because an agent that trashes a
user's environment is a support/reputation cost, not a design driver.

---

## 5. Transport & connection

- **Controller** = the Flutter app (phone or desktop). **UI only.** The
  messenger, the roster, the thread view, the Stop button. The existing "run a
  few basic bash commands in normal chat" capability stays as-is — it is not
  extended into a second agent loop.
- **Executor** = the Python agent, running inside its own container sandbox on
  the host (section 4).
- **Relay** = `cowork_relay` on `api.chuk.chat`. A **blind proxy**: it forwards
  encrypted frames between controller and executor and stores nothing. Already
  live. Still needs the **cross-replica fix** (prod runs 2 replicas with an
  in-RAM presence map; peer-to-peer between replicas over Swarm DNS — see the
  old execution plan's `relay-crossreplica`). This is a careful prod deploy and
  a real prerequisite for connections to land reliably.

**Pairing:** the host/agent connects to `api.chuk.chat`, does a device-login
(code flow, so a headless server is easy), gets an account token, and registers
as an executor on the relay, publishing an Ed25519 identity. It appears in the
user's device list; the phone **approves it locally** (client-side approval —
the server never holds an approval flag).

---

## 6. Crypto

- **Fresh CoWork channel key, established at pairing — NOT the chat account
  key.** Controller and executor each hold an X25519/Ed25519 identity; at
  approval they do an ECDH to derive a shared channel key that only the two
  know. The mirror/control channel is encrypted with this key.
  - Avoids reproducing the `encryption_service` account-key derivation in
    Python, avoids putting the account password on a headless host, and
    decouples CoWork crypto from chat crypto (a leak on one side does not sink
    the other).
  - The Dart `cowork_frame*` primitives (already built) get repointed from the
    account key to this channel key — cheap, since they are not wired anywhere
    yet — and get a **byte-identical Python twin** so Dart controller ↔ Python
    executor interoperate. Shared test vectors across both.
- **Honesty about the E2E boundary:** the model call itself routes **through the
  backend proxy** (section 7), so the backend sees that traffic. E2E here means
  *"the relay/control channel is blind"*, **not** *"the backend sees nothing"*.
  Do not oversell it.
- The host holds the channel key on disk. Whoever roots the host can drive the
  agents — inherent to any executor that can *do* things. It is the user's own
  machine; accepted.

---

## 7. Model routing

**Through `api.chuk.chat` (backend proxy), with the account token.** Billing and
account stay centralised, no provider keys scattered on every host, one auth.
This matches the existing `SandboxService` pattern (client → multiplex → backend
→ sandbox). The Python agent calls the model via the backend rather than holding
provider keys.

---

## 8. The agent runtime (Python)

Written in Python because the tool ecosystem (browser-use, document generation,
research) is far richer there than in Flutter — and the whole point is
capability. Flutter is only the UI.

- **Loop:** a Claude-Code-style agentic loop — system prompt (the agent's
  onboarding brief) + tool loop + tool registry, running many rounds
  autonomously.
- **Tools (preinstalled in the sandbox base image; see section 10 for the
  inside-vs-passthrough split):**
  - shell / process execution (as a normal user with passwordless sudo),
  - **browser** — Chromium + a browser-use driver
    (https://github.com/browser-use/browser-use),
  - filesystem,
  - **document generation** — LibreOffice (Word/Excel), pandoc,
  - **media** — ffmpeg / ffprobe (ffmpeg via host passthrough, section 10),
  - **yt-dlp**, research / web fetch,
  - MCP tools (as the chat client already exposes them),
  - **send-file-to-user** — push any produced file into the chat thread: CSV,
    PDF, image, generated document, or a **browser screenshot** when it opened a
    browser. Reuse the existing `send_file_to_user` → `sandboxArtifact` block, so
    it renders as a download/preview card. (Opening a *desktop* is explicitly
    out — §8a — but a browser screenshot as output is fine.)
  - **search-chats** — cross-session recall: search the user's past chats for a
    topic ("we discussed this last time" — but it is not in this session). Every
    chat is persisted as a **read-only markdown transcript, live-linked**, so the
    agent can find and read prior threads. chuk_chat already has a comparable
    chat-search tool to port.
  - the agent's memory tools (section 6/9).
- **Streaming:** every round streams into the controller thread as encrypted
  frames — text + collapsible tool-activity chips. **Stop** cancels the run.
- **Autonomy + cron:** the host scheduler fires trigger events on schedule; the
  agent runs with no phone attached and notifies on completion / approval. The
  whole app can be closed while a run continues in the sandbox; reopening shows
  the result. (This matches how competing agents-in-a-VM behave; see §8a for
  where we deliberately differ.)

### 8a. Capability model: structured tools, not a full VM to drive

Reference point: recent "agent in a VM" products (xAI/Grok, Cursor background
agents, and similar) hand the agent a **full machine** and, in some demos, hand
the *user* the VM over **VNC** to type credentials into (e.g. logging into
Salesforce), then give the agent the VM back. **We deliberately do not do this.**
Handing a human a remote desktop to paste a password is clumsy and unsafe when
the same platform exposes an API.

Our stance:

- The agent does **not** get "a whole computer to click around in." The
  container sandbox is only the *runtime*. The agent acts through **defined
  tools, Skills, and (fallback) MCP** — the way this very assistant has
  Playwright/MCP.
- **Capability hierarchy, best to worst:**
  1. **First-class API tools** (hand-built, §8c) — the primary path.
  2. **browser-use** (https://github.com/browser-use/browser-use) — the
     *fallback* for services with no usable API, or official scraping.
  3. **Graphical computer-use / VNC control** — essentially never; a possible
     far-later add-on, not the design.
  Most apps people use (LinkedIn, etc.) have an API; an agent over the API is
  ~10× more efficient than driving the same site in a browser. Browser-first is
  what competitors do and it is the wrong default — agents are not built to
  click through UIs when a door exists.
- **Skills = markdown, exactly like Claude's Agent Skills** (`SKILL.md`).
  chuk_chat already has this (`FEATURE_SKILLS`, `assets/skills/`). The Python
  agent reads the relevant skills on demand and executes — reuse the concept
  and, where possible, the same skill files. "Check the crypto data" → it loads
  a crypto skill + a crypto tool and runs.

### 8b. Credentials: revocable API/OAuth doors, never raw secrets in the box

- The agent reaches third-party services (GitHub, Google, Slack, a crypto
  source, …) through **revocable OAuth tokens / API keys obtained via the app's
  existing connection flow** — the same mechanism as chuk_chat's
  `FEATURE_SERVER_TOOLS` GitHub/Gmail/Calendar connections today. The user
  connects the service once on the app/website side; the token lives
  server-side; the agent calls a tool that acts with it.
- **The raw secret never enters the sandbox**, and access is **revocable at any
  time** without touching the agent. No VNC, no pasting passwords into a VM.
- Open item (deferred — "later"): confirm this connect-and-delegate flow works
  when the executor is a sandbox rather than the Flutter client. It likely does,
  because the tokens are already server-side and the agent invokes tools the
  backend executes — but it must be verified. See §13.

### 8c. Integration strategy: hand-built API tools first, MCP as fallback

- **Build our own first-class tools for the top ~100 services**, tailored for
  the open-source agent so they are simpler and better than a generic
  integration. These are API-first (REST/GraphQL/official SDKs), and they are
  where **revocable credential delegation** (§8b) is wired in — a reason to own
  them rather than trust third-party glue.
- **MCP is a fallback, not the primary protocol.** Treat it as "use it if a
  decent server exists and we have not built the native tool yet," and replace
  it with a native tool when the MCP server is poor. The bar is: does the native
  tool serve the agent better?
- **MCP transport problem to solve:** MCP servers commonly use a **localhost
  callback** (OAuth redirect / local port). From inside a per-agent sandbox that
  will not just work — the callback has to be **proxied** back to the right
  sandbox. Auto-connecting an agent to an MCP server therefore needs a
  proxy/broker for the localhost callback. Flagged as an open technical item
  (§13).
- **Base image built on Python + `uv`.** Tooling and dependencies are installed
  with `uv`; a broad default toolset ships preinstalled so the agent has "lots
  of tools it can already use" without a cold install on every task.

### 8d. Multiple chats & multi-agent collaboration

- **Multiple chats per agent.** You can open a **new chat with the same agent in
  the same sandbox** — separate threads, one persistent worker/environment.
- **Agents that collaborate.** Several agents can share **one chat and talk to
  each other**, like people in a group thread — you drop in and give targeted
  tasks, they coordinate. It should feel like messaging human teammates, not
  operating a tool.
- Implication (open): agents addressing/messaging each other needs an
  inter-agent bus (via the relay/backend) and a group-thread model where several
  executors and the user share one conversation. Mechanism TBD (§13).

---

## 9. Memory / notebook (the agent's brain)

Long autonomous runs blow the context window; the agent must externalise state.
This mirrors what this repo already makes Claude do (`tasks/todo.md`,
`tasks/lessons.md`, the `memory/` + `MEMORY.md` index).

- **Session notebook** (task-scoped): `todo.md` (checkboxed plan), `notes.md`,
  intermediate findings. The agent writes to itself and reads back. Lives for
  the task. This is the answer to "the chat gets long."
- **Global memory** (cross-session): learned facts, preferences, project
  knowledge, as markdown files + a `MEMORY.md` index (one line per entry). Only
  the index loads at start; entries load on demand (progressive disclosure).
- **Location:** per agent, on the host — the host is the persistent home, so a
  sync problem does not arise on day one.
- **Sync (later):** global memory *could* sync across a user's hosts, encrypted
  under the channel key. Deferred: an agent must think and remember on one host
  first.

---

## 10. Tools: inside the sandbox vs passed through from the host

Two classes of tools, split by whether running them *inside* the container
sandbox is good enough.

**Inside the sandbox (the default — most tools):** preinstalled in the base
image, and the agent can install more with sudo.

- Chromium + a **browser-use** driver (https://github.com/browser-use/browser-use),
- **yt-dlp** (runs fine inside — CPU/network bound, no reason to pass through),
- LibreOffice (Word/Excel), pandoc, python data libs, research tooling.

**Passed through from the host (the exception — only where in-sandbox is
inefficient):**

- **`ffmpeg` is the example.** Running ffmpeg *inside* the container is
  inefficient — no GPU, CPU-only transcoding is slow. So the agent's ffmpeg work
  uses the **host's** ffmpeg, which is GPU-accelerated because the user set up
  their own NVIDIA/Linux box. The host binary operates on the agent's workspace
  files (shared with the host). This is **not** GPU passthrough into a VM — it is
  a host-side binary acting on the sandbox's files.
- Only heavy/accelerated binaries get this treatment; anything that runs fine
  inside (yt-dlp) stays inside.
- **Open implementation detail:** the exact passthrough mechanism — host-executes
  ffmpeg against a shared workspace mount, vs exposing the GPU device into the
  container (`--gpus` / nvidia-container-toolkit). To be chosen when built; the
  host-executes-on-shared-mount route is the simpler default.

---

## 11. What of the current code survives / dies

- **Survives / gets reused:** the Flutter chat UI and its existing basic
  bash-in-chat commands (kept, not extended); the relay; the `cowork_frame*`
  crypto primitives (repointed to the channel key + given a Python twin); the
  client-side approval model; the laptop-native tools *as a concept* (they move
  to Python); **Agent Skills** (`SKILL.md` / `FEATURE_SKILLS` — the agent's
  skill system); **`FEATURE_SERVER_TOOLS` OAuth connections** (GitHub, Gmail,
  Calendar, Slack, …) as the revocable-credential model (§8b); the
  **`send_file_to_user` → `sandboxArtifact`** mechanism for the agent to send
  files (CSV/PDF/image/doc/browser screenshot) into the chat.
- **Dies:** the local demo `CoworkDemoServer` + the localhost bridge
  (`cowork_executor_bridge.dart`) + the served HTML phone page — wrong transport
  (there is no web UI, ever; remote control is only the official Flutter app).
  The Dart headless-executor idea dies; the executor is the Python sandbox.

---

## 12. Decisions locked (2026-08-12)

- Executor is a **Python** agent running in its **own container sandbox**
  (Debian-like, isolated filesystem, passwordless sudo, installable) — **no
  microVM, no KVM**. Container-grade isolation, enough for a single-user host.
  Install = a shell script + `connect`.
- **One host, many agents; one container sandbox per agent.**
- **Most tools run inside the sandbox** (browser-use, yt-dlp, LibreOffice, …).
  **A few host binaries are passed through** where in-sandbox is inefficient —
  `ffmpeg` uses the host's GPU-accelerated binary on the agent's files.
- **Capability hierarchy: hand-built API tools first → browser-use as fallback →
  computer-use/VNC essentially never.** No VNC credential handoff. Most apps
  have APIs; API beats browser ~10×. (§8a)
- **Own first-class tools for the top ~100 services; MCP is a fallback**, not the
  primary protocol. (§8c)
- **Base image built on Python + `uv`**, broad toolset preinstalled. (§8c)
- **Multiple chats per agent** (same sandbox) and **multi-agent collaboration**
  (several agents in one chat, talking to each other like teammates). (§8d)
- **Onboarding by demonstration**: record a task as video → agent analyses it →
  takes it over. (§2)
- **Skills reuse the existing Agent Skills** (`SKILL.md`, `FEATURE_SKILLS`).
- **Credentials = revocable OAuth/API doors via the app's connection flow**
  (like `FEATURE_SERVER_TOOLS` today); raw secrets never enter the sandbox.
  Detailed flow deferred. (§8b)
- **Agent = Workspace** (persona + files + memory + job + schedule).
- Model routing **through the backend proxy**.
- **Full E2E** on the control channel via a **fresh CoWork channel key** (ECDH
  at pairing), not the chat account key.
- Flutter is **UI only**; existing basic bash-in-chat stays.
- UI is a **messenger/roster**, Hermes-style streaming run + Stop.
- **The moat is the owned pipeline + a real GUI control surface** (skills toggle,
  connect/disconnect, model + token + session + cron all visible in-UI) — not a
  CLI/slash-command bot like Hermes Agent. (§15)

## 13. Open questions (not yet decided)

- Agent = reuse the Workspace entity directly, or a new "Agent" entity that
  *wraps* a Workspace? (reuse vs clean separation)
- Global-memory cross-host sync: when, and exactly how, encrypted.
- Pairing/device-login exact flow and where the channel-key ECDH is stamped.
- Scheduler: host-local cron vs a backend-driven schedule (offline hosts?).
- Credential model (§8b): confirm the connect-and-delegate OAuth flow works with
  a sandbox executor (tokens server-side, agent calls backend-executed tools);
  what, if anything, an agent needs locally; per-agent scoping of connections.
- Relay cross-replica fix: do it before or alongside the first Python executor.
- **MCP localhost-callback proxy** (§8c): how to broker an MCP server's local
  OAuth/callback back into the right per-agent sandbox.
- **Inter-agent bus + group-thread model** (§8d): how agents address and message
  each other, and how several executors + the user share one conversation.
- **Video → repeatable procedure** (§2): how a demonstration recording is
  analysed into something the agent can reproduce (and optionally distil into a
  Skill).
- **Top-~100 API tool catalogue** (§8c): a large workstream — which services
  first, and the shared tool/credential shape they follow.

## 14. Rough build order (to be turned into milestones later)

1. Relay cross-replica fix (prod, careful) — unblocks reliable connect.
2. Repoint crypto to a channel key + Python twin + shared test vectors.
3. Pairing / device-login / local approval for a Python executor.
4. Minimal Python agent runtime (loop + shell + memory) inside one container
   sandbox, driven from the Flutter messenger, streaming back.
5. The setup shell script + `connect` + the Manager (roster, per-agent sandbox
   containers, lifecycle).
6. The tool set — inside the sandbox (browser-use, yt-dlp, documents) + host
   ffmpeg passthrough.
7. Scheduler / cron + push wake + autonomy.
8. Memory sync, GPU, hardening.

---

## 15. Positioning: owned pipeline + GUI control surface (vs Hermes Agent)

Reference: **Hermes Agent** (Nous Research,
https://github.com/nousresearch/hermes-agent) — Python, runs in Docker / SSH /
cloud VMs, with 40+ tools, an autonomous **skills** system, a **memory** layer,
**cron** scheduling, **MCP**, and **subagent delegation** for parallel work.

**This validates our stack almost 1:1** — Python executor, container sandbox,
markdown skills, cron, MCP, multi-agent (their "subagent delegation" ≈ our §8d
collaboration), agent memory. We are not inventing an unproven shape.

Where we deliberately win:

- **We own the whole pipeline, front to back** — the Flutter app, the backend,
  the relay, the sandbox, and model routing through the backend proxy. Hermes is
  a bring-your-own-provider CLI plus messaging gateways. Owning the pipeline
  means one integrated account, billing, and experience, and control over every
  layer.
- **A real GUI control surface, not a CLI / slash-command bot.** Hermes is
  driven from a terminal/TUI and messaging platforms (Telegram/Discord/…),
  configured with CLI commands and slash-commands. Ours is a full app UI where
  the user can, *in the UI*:
  - activate / deactivate **skills**,
  - **connect / disconnect** integrations (the revocable OAuth doors, §8b),
  - pick and see the **model**,
  - watch **live token usage**, **session runtime**, and the **cron schedule /
    next runs**,
  - start, watch, and **Stop** runs.
  Slash-commands can still exist as a shortcut, but the user is never *bound* to
  a command line. This is the "real app" vs "bot bolted onto Telegram"
  difference, and it is the moat.
- **API-first over browser, and no VNC credential handoff** (§8a/§8b) — a
  cleaner, safer, more efficient interaction model than driving UIs or handing a
  user a remote desktop to paste passwords into.
