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

### 1.1 Product thesis — a computer you tell what to do

This is meant to be the next way of using a computer: you say "do this", and it
does it. The **product is the chat window.** The agent does everything **in its
own container / on the remote — never directly on the user's system.** The user
installs nothing, ships nothing, sets up no toolchain. They just talk to the
agent, hand it files and links, and get results back.

The agent cannot drive GUI programs — and it does not need to. For 99% of tasks
there is a **CLI, an MCP server, or an API**; the agent reaches for that instead
of clicking a desktop app. That constraint is the whole point, not a limitation.

Direct access to the user's own machine or specific folders is explicitly **not**
this product. That is what Claude Code and similar tools are for. A separate
"give it access to your system" mode may come later, but it is not the goal here.
Here the boundary is clean: a chat window in, work done in a sandbox, files out.

Shape of the tasks (examples, not a fixed list):
- "Summarise this YouTube video" → the `youtube-transcript` skill: pull the
  transcript, read it, answer.
- "Cut this video into a viral YouTube Short" → pull the transcript, find the
  strong moments, cut with ffmpeg, send the clip back.
- "Convert this from format A to format B" → ffmpeg / anydoc / a CLI.
- "Scrape everything from this website into an Excel sheet" → browser or API →
  `openpyxl` → send the `.xlsx` back.
- "Transcribe this voice memo" → the Whisper tool (§9) → text back.

Same loop every time: a plain request in, the agent picks the right tool, the
work happens in the sandbox, the file or answer comes back to the thread.

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
- **Session** — the one permanent conversation with an agent. There are **no
  threads and no "new chat"**: a bot has exactly one session that runs forever,
  kept coherent by compaction + memory, not by the user filing work into threads.
  See `docs/context-compaction-design.md` §0.

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
  (multimodal, via the backend video model — default `qwen/qwen3.6-35b-a3b`, §9)
  and takes the task over. "Show,
  don't tell." A demonstrated task can be distilled into a Skill (§11).
- **Files** — documents/links/context you hand it.
- **Memory** — its own persistent notebook (§12).
- **Skills** — markdown `SKILL.md` procedures it loads on demand (§11).
- **Schedule** — optional recurring triggers (§13).
- **Credentials** — revocable OAuth/API doors, never raw secrets in the box
  (§10).

**One permanent session per agent — no threads** (§16.1;
`docs/context-compaction-design.md` §0). A coworker you have to "start a new
chat" with is not a coworker. The single session grows past any context window;
compaction + memory (§12) keep it coherent, not the user. **Multi-agent
collaboration** stays — several agents in one shared room, talking to each other
like teammates while you assign targeted tasks (§7.6).

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

### 7.7 Git-versioned workspace (time-travel & undo)

Concept: this exists first for **safety / audit** — if the agent does something
wrong, there is a complete, detailed record and a way back. **Every tool call is
written down in detail, every time** (name, arguments, result), alongside the
file edits, memory/skill changes, and generated documents — all **auto-committed
to git**, so any step is **revertible** and the whole run is a browsable, forensic
history. Large binaries are excluded (gitignore / git-lfs boundary).

**Prior art (honest):** a known *pattern*, not a standard protocol. **Aider**
auto-commits every AI code edit to git with generated messages and supports undo;
coding agents (Claude Code, Cursor, Devin) use branches/worktrees; chuk_chat's own
CLAUDE.md already prescribes one git worktree per agent. What is differentiated
here is making it **first-class and total** — not just code edits but the agent's
whole workspace + action log — surfaced as an **undo / time-travel UI** in a
pipeline we own end to end.

**Design:**
- **The agent's workspace (sandbox home) is a git repo.** Auto-commit after each
  mutating action (write_file, mutating run_command, memory/skill writes); commit
  message = the round/action summary the streaming feed already produces.
- **A detailed action journal, not just file diffs.** Every tool call —
  including read-only or external ones that mutate no local file — is recorded as
  a structured entry (name, args, result summary) and committed, so the git log
  is a full forensic trail of *what the agent did*, not only *what files
  changed*.
- **Two layers, not one.** The append-only SQLite session store (§7.5) is the
  *conversation transcript*; git is the *workspace filesystem + action-journal
  history*. Keep both.
- **Encrypted at rest.** The workspace/git repo lives inside the sandbox and is
  encrypted at rest (the sandbox disk is encrypted; may be switched on later).
  So the detailed history is not sitting in plaintext on the host disk. Tentative
  — a "later" hardening, not a v1 blocker.
- **Undo / rollback in the UI:** roll the workspace back to any commit ("undo the
  last 3 actions"). Directly de-risks the passwordless-sudo concern (§6, §17) —
  workspace changes become reversible. A real trust/safety feature and a selling
  point.
- **Subagents on branches:** each subagent (§7.6) works on its own branch/
  worktree, merged back — maps onto chuk_chat's existing worktree model.
- **Versioned memory & skills:** MEMORY.md/USER.md/SKILL.md are markdown → git
  gives revertible, diffable memory, a better version of Hermes's `.bak.<ts>`
  snapshots.
- **Binaries:** gitignore / git-lfs boundary; text is committed, large media is
  not (disk-cost guard).

**Honest boundary (like §14's E2E note):** git undoes the **workspace**, not the
**outside world**. A sent email, an API call, a `sudo` on the host are not
reverted by git. The undo UI must say so rather than imply total rollback.

Open: commit granularity (per-action vs per-round), gitignore-vs-lfs policy, and
how far "undo" is presented given irreversible external side effects. (§20)

### 7.8 Interactive terminal (TUIs, menus, prompts)

**Problem — a known agent limitation, and a current Claude Code limitation.** The
fast path (one-shot `bash -c cmd` + snapshot file, §6) cannot drive
**interactive** terminal programs. A command that opens a menu, a prompt, a TUI,
a REPL, or an installer that asks questions will hang or fail — there is no TTY
the agent can navigate and no way to read the on-screen menu. Hermes has the same
limitation (no long-lived interactive shell); we go beyond it.

**Design — a persistent interactive terminal per agent, alongside the one-shot
tool:**
- Backed by **tmux** inside the sandbox (or a raw PTY + a VT100 screen emulator
  like `pyte`), so a session **persists across tool calls and loop rounds** —
  "stay in the session."
- `terminal_send_keys(keys)` — literal text or named keys (Enter, arrows, Tab,
  Escape, C-c, …), so the agent can navigate a menu, answer a prompt, or type
  into a REPL.
- `terminal_read()` — **capture the current rendered screen** (`tmux
  capture-pane`), so the agent *sees* the menu/prompt/cursor as text and picks
  the next keystroke — the text analogue of looking at the screen.
- optional `terminal_wait` (idle/pattern) to avoid racing a slow redraw.
- Handles: interactive installers, `sudo`/password prompts, ncurses menus,
  `git rebase -i`, package-manager prompts, vim/nano, python/node REPLs, ssh
  sessions, long-running foreground processes.

**Division of labour:** the **one-shot command tool** for scripted work (default,
fast, snapshot-file model, §6); the **interactive terminal** only when a program
needs navigation. The agent chooses. Interactive actions (keystrokes + captured
screens) are journaled to the git action-log (§7.7) too. Open: tmux vs PTY+pyte
as the backing mechanism (§20).

**Token cost & lifecycle — where tmux gets expensive if naive:**
- **Bounded capture:** read only the **visible viewport** (bounded rows × cols),
  never the full scrollback; trim trailing blank lines.
- **Diff reads:** send only the **screen delta** since the last capture (the same
  hash-diff idea as the cron monitor, §13) — "no change" when idle, changed lines
  only when a menu updates. The big saver for redraw-heavy TUIs.
- **Read on demand:** capture only after a keystroke that likely changed the
  screen, not blindly every round.
- **The context ladder does the rest:** captures are tool results, so §7.3's
  deterministic dedup/truncate evicts old and duplicate screens automatically —
  §7.8 and §7.3 compose.
- **Lifecycle = fresh per task, close on done.** Terminals are **named and
  task-scoped** (like the task_id-scoped container/subagent model, §7.6).
  Default: a new task gets a **fresh terminal** (clean slate — no leftover
  processes, no stuck TUI, no stale cwd); the agent **closes it when done** and an
  **idle reaper** kills abandoned ones. Reuse the same terminal only when a task
  **explicitly continues** a prior interactive session. Closing terminals also
  bounds context, since their old captures leave and get compacted.

### 7.9 Token efficiency (cross-cutting)

Token cost is a first-class constraint everywhere, not an afterthought. The levers
in this plan, in one place:
- **Tool Search progressive disclosure** (§7.2) — defer rarely-used/MCP tools
  behind three bridge tools.
- **Cost-tiered context ladder** (§7.3) — deterministic dedup/truncate, then a
  cheap-aux-model summary of the middle. The core long-run lever.
- **Frozen-snapshot memory** (§12) — mid-session writes don't mutate the prompt,
  preserving the prefix cache all session.
- **Skills on demand** (§11) — only name + description in the always-on prompt;
  bodies load when used.
- **Cron cost modes** (§13) — `no_agent` (zero tokens) + hash-diff monitor (wake
  the LLM only on change).
- **Interactive terminal** (§7.8) — bounded viewport, diff-only reads, task-scoped
  teardown.
- **API-first over browser** (§8) — an API call is far fewer/cleaner tokens than
  scraping a rendered page.
- **General discipline:** read on demand, bound every tool output, diff instead of
  re-dumping, defer/evict anything not needed this round.

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
- **Browser — headless Chromium in the container, driven by the agent's own
  loop.** Decisions:
  - **Ships IN the base image, not a separate variant.** The product is "any
    user throws any task at the agent" — the browser must always be there, no
    image choice to get wrong. Chromium plus its libraries is a few hundred MB;
    we pay that on every agent by design. (`Dockerfile.browser` stays as the
    historical split, but the default build folds it in.) It runs **headless**:
    no window opens on anyone's screen, the user installs nothing and ships
    nothing. The agent still "sees" it — it can take screenshots and read the
    page — but that all happens inside the container.
  - **Driver = Playwright, not browser-use.** The agent is *already* the
    autonomous loop (§7, Claude-Code style). browser-use's whole value is a
    *second* agentic loop that drives the browser toward a goal on its own —
    nesting that inside our loop means a second LLM burning tokens and less
    control. We do not want two brains. Instead the agent drives the browser
    **directly**, the same way this very session drives the Playwright MCP
    (navigate / accessibility-tree snapshot / click / type / screenshot /
    evaluate). Playwright is deterministic and the transport the user already
    trusts.
  - **Exposed as a native browser tool set** (a thin Playwright-backed wrapper,
    or the Playwright MCP server running in-container), modeled on the Playwright
    MCP surface — one persistent headless Chromium per agent, called from the
    agent's loop. Chromium is downloaded at **build time** (as `Dockerfile.browser`
    already does via `uvx playwright install chromium --with-deps`), so no agent
    run pays for the download.
  - Still API-first (§8): the browser is the *fallback* for the sites without a
    usable API/CLI/MCP, not the default reach.

  **browser-use vs Playwright — the comparison (researched 2026-09-02):**
  - **Architecture.** browser-use is *itself an agent*: its own observe→plan→act
    →verify loop. Every step it feeds the page state (accessibility tree / DOM,
    optionally a screenshot) to **an LLM**, the LLM picks the action, it runs it
    over CDP, repeat. The LLM is the driver — a second brain. Playwright has **no
    LLM inside**: a deterministic API, and as the Playwright MCP it exposes tools
    (navigate / snapshot / click / type / screenshot / evaluate) that **our**
    agent drives from its own loop.
  - **Tokens.** browser-use ≈ **5,000–15,000 tokens per ~10-step workflow**
    (~$0.05–0.15) because it sends a full observation to an LLM every step — and
    that is a **separate model bill on top of our agent**. Playwright MCP
    snapshot ≈ **1,500–5,000 tokens**, and those are **only our agent's own
    tokens**, spent when it chooses to snapshot; no second model. Accessibility
    tree over screenshots is 20–50× cheaper (≈50k vision → ≈5k text) and both
    approaches get that saving.
  - **What browser-use is for.** Autonomous multi-page workflows on unknown /
    changing layouts, self-recovery from UI changes, "just accomplish this goal",
    structured extraction, custom actions. Its strength is *autonomy* — which our
    agent already is. Adopting it means paying for a capability we have.
  - **Version.** Latest is **0.13.8 (2026-08-16)** — still the 0.13 line, no "2.x"
    library (the `bu-2-0` / `bu-latest` names are browser-use's *cloud model
    tier*, not the pip version). It still pins `mcp==1.26`, which conflicts with
    our `mcp>=2.0` client — adopting it still forces an isolated environment.
  - **Playwright MCP specifically (Microsoft `@playwright/mcp`, Apache-2.0,
    researched 2026-09-02).** Snapshot mode (default) hands the model the
    accessibility tree — a single snapshot ≈ **200–400 tokens** (2–5 KB) vs
    100 KB+ for a screenshot; vision mode exists only for edge cases the AX tree
    misses. So per-step it is cheap. **But the sting is long sessions:** the MCP
    server keeps re-emitting snapshots into the context, which bloats and goes
    **stale** — a benchmarked task ran ~**114k tokens through the MCP** vs ~**27k
    through the Playwright CLI** (agent writes scripts, snapshots to disk, greps
    them), and stale AX trees cause hallucinated locators / flaky runs in long
    sessions. So the MCP is the *convenient* surface but not the *cheapest or
    most reliable* one.
  - **Decision: Playwright MCP server (not browser-use, not the CLI).** The
    token difference between MCP and CLI is **irrelevant at our prices** — the
    models we run are absurdly cheap (≈**$0.15 / M input, $0.50 / M output, and a
    cache hit ≈$0.03 / M**; verify the exact cache price for the current model).
    A whole browser session is cents. So the "CLI is 4× fewer tokens" point does
    not move the decision. We pick the MCP server for the **clean ready-made tool
    surface** the agent drives directly — the same surface that has been reliable
    in practice — over hand-writing Playwright scripts. browser-use stays out: it
    is a second autonomous brain we do not need, and it drags the `mcp==1.26`
    conflict. (The CLI/library remains a valid path if a specific job wants
    snapshot-to-disk + grep, but it is not the default.)

  **Only-GUI-needed = the browser.** ~99% of what users want, and of what our
  automation does, is in the browser. So the browser is essentially the *only*
  GUI program we need — we do not chase other desktop apps. That means we can
  likely use a **ready-made Xvfb/VNC browser image** as the base for the visual
  side rather than assembling the X stack by hand. Open: which image (§20).

  **Interactive login hand-off (the important one, recorded):**
  Some services have no API/MCP and force a login *on the website itself*. That
  is a small minority of tasks — most tasks need no login, and most that do have
  an MCP — but it must work. The mechanism (as decided):
  - The agent hits a login wall and **ends its browser tool loop**. It tells the
    user, in the thread, "please open the login view and sign in".
  - The chat UI shows a **remote-controllable noVNC view** of the container's
    Chromium (running headful under **Xvfb**). The user drives that browser
    directly and types their own credentials. A notice says the view can change.
  - The user finishes, **closes the view, and tells the agent "I'm logged in,
    done"**. Only then does the agent restart its loop and continue, now with an
    authenticated session (cookie) living in the container's browser.
  - **Why this is safe by construction:** because the agent's tool loop is
    *ended* during the login — not merely paused — there is no observation
    running that could capture the password. The risk is absent, not mitigated.
    The agent never sees the login screen or the credentials.
  - **Two modes, deliberately.** Default = **agent-blind** (above): the password
    stays with the user. But sometimes it is useful for the agent **to get the
    credentials on purpose** — so it can reverse-engineer the login flow and
    build a **reusable auto-login script** (see the browser→script skill below),
    so the next run needs no human. That is a per-task choice, not the default.
  - **Transport = the same E2E channel, no open ports.** The VNC stream is
    redirected through the host/Python server to the Flutter client over the
    existing end-to-end-encrypted line — same topology as everything else, no
    inbound port on the sandbox.
  - **HARD CONSTRAINT: no browser / no webview in the Flutter app.** The app is
    deliberately small and there is **no good universal webview across Android /
    Linux / Windows / macOS** — we have hit this before and never shipped a
    bundled browser. So **any noVNC-in-webview path is rejected outright**, on
    every platform. The renderer must be pure Flutter.
  - **Rendering in Flutter — decided approach (researched 2026-09-02).** Two
    browser-free paths; we take **path 2 (host pixels)** as the default:
    1. ~~Webview + noVNC~~ — **REJECTED** (violates the no-webview constraint
       above). Kept only to record why.
    2. **Host grabs the pixels, Flutter just paints (DEFAULT).** Sandbox: Xvfb +
       Chromium. The host **grabs the framebuffer directly** (`ffmpeg -f x11grab`,
       or x11vnc as the source), encodes changed regions as **WebP/JPEG tiles**,
       and streams them over the sealed E2E channel. Flutter receives images and
       **paints them with `Image.memory` on a `CustomPaint`** — no protocol, no
       decoder. Flutter captures pointer/keyboard as normal gestures/key events
       and sends **simple JSON events** (x, y, click, keycode) back; the host
       injects them with **`xdotool`**. Benefits: the Flutter side is tiny and
       rock-solid (a few hundred lines, **no new dependency**, no RFB decoder to
       debug across 5 platforms); we **own the codec and FPS, so we control the
       delay directly**; x11vnc can be dropped entirely (just x11grab + xdotool).
       Cost: we build the mini remote-desktop ourselves — dirty-rect diffing (or
       plain low-FPS full frames for a login) and input mapping (coord scaling,
       keycodes). More host code, but simple host code.
    3. **Native Dart RFB client** (`flutter_rfb` / `dart_vnc`) — the pure-Dart
       alternative. Speaks RFB itself and renders the framebuffer in a Flutter
       widget; runs on every Flutter target with no native lib and no webview.
       Transport: rebind their raw-`Socket` I/O onto our sealed channel (the
       decoder does not care where bytes come from). Benefits: RFB is **naturally
       incremental** (dirty-rects only → less bandwidth for free), input is solved
       by the protocol, and the host stays stock x11vnc (**less host code**). Cost:
       these are weekend-grade packages with **thin encoding coverage** — we must
       pin x11vnc to encodings the Dart client handles (Raw/CopyRect safe, ZRLE/
       Tight maybe to add), and any RFB bug is ours to debug in Dart.
  - **Delay:** for **both** paths the floor is the **relay round-trip** — one hop
    client↔host over the E2E line. Typing feels responsive as long as the input
    RTT is small (event → xdotool/RFB-input → next frame), which is identical for
    both. Frame delay is dirty-rect vs full-frame — both can do incremental
    updates (path 3 natively, path 2 we build it). A login is low-motion, so
    small dirty-rects → low delay. **Delay is effectively equal; the real
    difference is code and robustness, not speed.**
  - **CHOICE: path 3 — least custom code, because both ends are off-the-shelf.**
    The deciding criterion is "do not rebuild the whole stack ourselves." Path 2
    fails it — both ends are bespoke (custom pixel protocol, dirty-rect diffing,
    xdotool input mapping). Path 3 passes: the **server is stock x11vnc** (an apt
    package, zero code) and the **client is a stock pure-Dart RFB library**
    (`flutter_rfb`) that does rendering + keyboard/mouse itself and imports like
    any pub package on all Flutter targets. We write only **two thin byte
    bridges** that reuse the **existing sealed E2E channel** — so E2E is free (the
    RFB bytes ride inside our sealed frames; no new crypto layer).
  - **No fork of the library, via a loopback socket.** The RFB lib wants to
    connect to `host:port` over TCP. Instead of rewriting it, the Flutter app
    opens a **local loopback `ServerSocket` on `127.0.0.1`** (`dart:io`, works on
    Android/Linux/Windows/macOS); the lib connects there; our bridge pipes those
    bytes into the sealed frames. The library stays unmodified. The Python side
    is the mirror: read the x11vnc TCP socket → wrap in a sealed frame → relay →
    and back (~50 lines; the sealed-frame machinery already exists).
  - **Data flow:** Chromium@Xvfb → **x11vnc** (TCP, localhost only) → Python
    bridge → **sealed E2E frames** → relay → Flutter loopback bridge → `127.0.0.1`
    → **flutter_rfb** renders + sends input back the same way. No open port
    anywhere, E2E throughout, both ends standard software.
  - **One thing to verify before committing (a ~1-hour check, not an architecture
    risk):** that `flutter_rfb` (a) handles **keyboard input** and (b) speaks an
    encoding x11vnc serves. The RFB client dictates encodings (SetEncodings); Raw
    + CopyRect is universal and plenty for a low-motion login, and x11vnc serves
    them. If `flutter_rfb` lacks input, `dart_vnc` is the backup candidate (same
    pattern). This is the only login-screen piece; it is for the small minority of
    tasks that need an on-site login.
  - **"Just open a normal browser" — the simple fallback, with a real tradeoff.**
    We could instead give the user a URL they open in their **own system
    browser** (standard noVNC deployment at the backend + websockify). Easiest by
    far, works on any device — **but there is then no E2E line**; it is a public
    web page whose pixels and keystrokes transit our backend under plain TLS, not
    the client-held E2E key. The agent still never sees the password, **but our
    backend theoretically could.** So for a **password login** this is the weaker
    posture; fine for harmless remote control. **Decision: path 1 (in-app, E2E)
    is the default for logins; the external-browser page is an explicit fallback
    for unsupported devices, shown with a note that it is not E2E.**

  Related: we already built a **browser→script skill** — it captures browser
  actions and turns them into a replayable script over a **WebSocket stream**.
  That is the automation-capture path an agent-with-credentials login would feed
  into.

  **Bot fingerprint (low priority).** A Playwright/headless Chromium is sometimes
  detectable vs a normal Chrome and gets flagged by some sites. May want to spoof
  the fingerprint (real UA, headful-like flags, stealth). Separate concern, do
  not couple it to the login work.
- **File → markdown:** **anydoc** (firecrawl, MIT, fully offline, no API key).
  One dependency (`pip install firecrawl-anydoc`) replacing pandoc + python-docx
  + LibreOffice + pypdf for ingestion of doc/docx, ppt/pptx, xls/xlsx, odt, rtf,
  epub, csv, and **text-based** PDF; ~250× faster than LibreOffice. Gap: no OCR,
  no standalone images → route those to a **vision/video model via the backend**
  (no Tesseract). Pattern: try `anydoc.to_markdown(...)`, on `UnsupportedError` →
  vision path.
- **Vision / OCR — through the main model, never a local model.** The main
  agent model is **GLM 5.3**, which already has vision. So image understanding
  and OCR route straight to it: an image the user sent, a scanned PDF, a
  screenshot — hand it to the vision-capable main model. **Running a local OCR
  model is completely inefficient; no Tesseract, no local vision weights.** (IDs
  churn; keep the choice at "the main model does vision, nothing local does.")
  Video input rides the same path where the model accepts it; specifics are TBD
  and tracked in §20.
- **Media:** **`ffmpeg`/`ffprobe`**, and **`jellyfin-ffmpeg`** — Jellyfin's
  full static ffmpeg build with all codecs and the hardware encoders (NVENC/
  VAAPI/QSV) baked in, which the thin Debian ffmpeg lacks. That is the build the
  agent uses for anything heavy. Plus **yt-dlp**. The GPU-accelerated path runs
  on the host (§20 passthrough); the in-container jellyfin-ffmpeg is the always-
  available fallback.
- **Speech-to-text (Whisper) — a tool that calls OUR API, not a local model.**
  We already have Whisper transcription running as a service. The agent gets a
  tool that calls that same speech-input API (WebSocket or plain request, the
  transport we already use) and gets text back. No whisper weights in the
  sandbox — the transcription happens where it already happens, server-side.
- **Docs out:** `python-docx`/`openpyxl`/`python-pptx` where the agent must
  *write* office files (anydoc only reads).
- **Files flow both ways — the core loop.** A user sends a file; it lands as a
  **real file in the agent's workspace filesystem**, not just a reference. The
  agent opens, edits, converts, regenerates it — whatever the task needs — right
  there. Uploaded user files sit in the workspace ready to hand. Then the agent
  **uploads files back to the user** through a tool, and the user sees them in
  the thread. So: user upload → workspace file → agent works on it → agent sends
  the result back. anydoc (above) is the *convert* step inside that loop.
- **send-file-to-user:** the return leg. Push any produced file (CSV/PDF/image/
  generated doc/**browser screenshot**) into the chat thread. Reuse chuk_chat's
  existing `send_file_to_user` → `sandboxArtifact` block (renders as a download/
  preview card).
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
- **Primary path (decided): authenticate in the Flutter client, then pass the
  token into the sandbox.** The simplest model, and the one we build for. Every
  MCP server / service is connected and authenticated **on the client side, in
  the Flutter app, exactly like every other connection**. When the sandbox
  actually needs the credential, the client hands it to the sandbox **over the
  existing end-to-end-encrypted channel** (the same sealed-frame transport as
  everything else — no new ports, no tunnel). Whether the token is ultimately
  used from Python in the sandbox or from Dart in the client makes **no
  difference** — it is the same token doing the same call. The user authenticates
  **once**; if they connected an MCP server on their phone and later the agent
  needs it in a freshly provisioned Python sandbox, the token is simply forwarded
  in. This sidesteps the localhost-callback-in-sandbox problem entirely, because
  the interactive OAuth happens in the client (which already has a browser), and
  only the **result** crosses into the sandbox. The backend-terminated callback
  above stays as the **fallback** for servers whose flow must complete
  server-side. (Nuance to handle: token **refresh** — the client stays the auth
  authority and re-issues; a static token passed in must be refreshable.)
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
- **User-gated skill creation from a demonstration or completed task.** Beyond
  the autonomous fork, the agent turns a task into a skill **with the user in the
  loop** — the flow the xAI/Grok bot popularised, fed by our video onboarding
  (§4). You show or ask for a task; from the recording, or when the task is done,
  the agent **proactively asks "shall I save this as a skill?"**. On yes it writes
  a `SKILL.md` that describes the procedure exactly, which becomes reusable and
  directly executable next time. So there are **two paths to a skill** — autonomous
  (background-review) and explicit user-confirmed — producing the same `SKILL.md`.
  This is table-stakes parity (competitors ship it) and cheap for us because the
  skill machinery already exists.

---

## 12. Memory / notebook

Because a bot has **one infinite session** (§4, no threads), memory *is* the
product. Full design in `docs/context-compaction-design.md`; the layers:

- **(0) mem0 — semantic recall.** Fact extraction → vector store → multi-signal
  retrieval (semantic + keyword + entity, fused), ADD-only, temporal rerank. The
  "remembers everything, even weeks old" front door. Strong on temporal/multi-hop
  (~92–94 on LoCoMo/LongMemEval), weak on open-domain (~72.7) — so it is a layer
  **on top of**, never a replacement for, the exact store below.
- **(0b) Hero-model note-writer.** A cheap background model updates the bot's
  running notes every round (`context-compaction-design.md` §2) — the curated,
  always-shipped summary that never forgets a decision or a value.

Under those, the two exact stores (Hermes `tools/memory_tool.py` +
`hermes_state_search.py`):

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

### 14.1 P2P data plane — the server coordinates, it does not carry (decided 2026-09-02)

**Decision: rewrite the transport so ALL client↔host traffic goes peer-to-peer,
and our API server is only a signaling coordinator — it never carries the data.**
The relay-through-our-server model above becomes a *fallback*, not the path.

Why: the heavy payloads — file uploads, files sent back, the live VNC browser
stream (§9.1), and the text/tool streaming — must not eat our server's bandwidth
(one gigabit) or add a hop. When the host is a small box on the user's LAN and
the client is a laptop next to it, the bytes should never leave the LAN.

**Hard constraint: NO port forwarding, ever. No publicly-open, listening port on
the host — nothing scannable, nothing hackable.** The user's router/firewall
stays fully closed. This is non-negotiable and rules out UPnP/NAT-PMP too (those
open a mapping). We use **outbound-only** connectivity: an outbound UDP packet
creates a temporary NAT hole that ONLY the one negotiated peer can traverse —
not a public door. This is exactly how Zoom/Discord/WhatsApp calls work behind
NAT with zero port-forwarding.

**Mechanism — WebRTC DataChannels + ICE (simple, not WireGuard/Tailscale):**
- **Signaling** over our existing coordinator (the API server / relay): the two
  peers exchange ICE candidates + the pairing keys. Kilobytes per connection
  setup; then the data plane is direct.
- **ICE/STUN** discovers each side's public endpoint and does **UDP hole
  punching** → a direct P2P DataChannel. Outbound only; no listening port.
- **IPv6** kept as an accelerator (often no NAT at all); firewall still stays
  closed, still hole-punched, still no open port.
- **TURN fallback** for the hard-NAT minority (symmetric NAT both ends). Also an
  **outbound** connection, so still no open port, and **blind** (our E2E seal
  stays on top). Prefer a **user-run TURN** (coturn on their own host/VPS) so
  even the fallback never touches our server. Rejected: UPnP (opens a port),
  WireGuard/libp2p/iroh (no good Flutter binding, or overkill for 1 client↔1
  host).
- **Stack:** Flutter **`flutter_webrtc`** ↔ Python **`aiortc`**, **DataChannels
  only** (SCTP/DTLS/ICE) — no media tracks. Our sealed `cowork_frame`s ride as
  DataChannel messages.

**What stays vs what changes:**
- **Only the PIPE changes.** The `cowork_frame*` E2E crypto, the §15 pairing, and
  all app/executor/host logic are pipe-agnostic. The VNC/browser work (§9.1)
  rides sealed frames and is unaffected. We swap the WebSocket-through-relay
  (`RelaySocket` on Dart, the relay endpoint on Python) for a WebRTC transport
  behind the same `Transport`/frame seam.
- **DTLS is transport encryption; our seal is the real E2E** — we never have to
  trust DTLS or a TURN operator. Everything stays end-to-end encrypted with the
  channel key, exactly as today.
- The **model I/O honest boundary is unchanged**: that is host↔backend (the
  agent's uplink to the model), a different hop from client↔host, and not part of
  this P2P data plane. The user's file/stream bytes never touch us.

**Effort:** a transport-layer rewrite on both ends (Dart + Python) plus a small
signaling service, but bounded — the crypto, pairing, and business logic are
untouched. Tracked as its own workstream.

---

## 15. Pairing / `connect` (secure, MITM-resistant)

**Goal:** establish an E2E channel + mutual device trust between the desktop app
(frontend, logged in) and the Python client, using a short human code, such that
even a malicious relay/backend cannot MITM or spoof, and a stolen code cannot
hijack the client.

**Trust anchors already present:** both sides are logged into the **same
account**; the relay routes only within the account (cross-account impossible);
frames are Ed25519-signed + AES-GCM (§14). Pairing bootstraps the initial device
trust **without trusting the relay/backend**.

**Primitive — SAS-authenticated X25519 with a hash commitment** (the ZRTP /
Signal-safety-number pattern), using only X25519 + HKDF-SHA256 + SHA-256 (present
in both `cowork_crypto` (Python) and Dart `cryptography`). A PAKE (SPAKE2) was
considered but has no maintained Dart implementation; SAS + commitment gives
equivalent MITM resistance for a single-use short code and is buildable in both.

**Flow:**
1. **Client (Python)** starts a pairing session: ephemeral X25519 `(a, A)`, a
   single-use **pairing code** `PC` = channel-id + 6–8 digits (or 3 words),
   expiry ~2 min. Publishes a **commitment** `H(A)` to a pairing channel on the
   relay. Displays `PC`.
2. **User enters `PC`** into the desktop (already logged in). Desktop joins the
   channel (by the id in `PC`), generates ephemeral `(b, B)`, sends `B`.
3. Client reveals `A`; desktop checks `H(A) == commitment` — binds `A`, stops a
   MITM from grinding `B` to hit a target SAS.
4. Both derive `K = X25519(priv, peer_pub)` and transcript `T = A‖B` (canonical
   order), then `SAS = trunc(HKDF(K, "cowork/pairing/sas", T ‖ PC))`. Folding
   `PC` in binds the out-of-band human code to the exchange. **The E2E channel
   now exists** (K) — before any confirmation is "sent".
5. **Key confirmation (the "code returned"):** desktop sends
   `MAC_d = HKDF(K, "cowork/pairing/confirm-d", T)`; client verifies
   (constant-time). Client sends `MAC_c = …confirm-c…`; desktop verifies. A MITM
   holds two different `K`s → MACs mismatch → **abort**.
6. On success: `K` becomes the CoWork channel key (§14). Each side sends its
   long-term Ed25519 **device pubkey** authenticated under `K`; each **locally
   approves** the other (§8, default-deny). The pairing session is **single-use**
   and expires.
7. **Then** the desktop provisions the account session **token** (access+refresh,
   from the frontend login, §16 seam) to the client over this now-authenticated
   E2E channel — the client is authenticated in the account's name (token, never
   credentials, revocable).

**Security properties:** relay/backend MITM fails (commitment stops grinding,
SAS/MAC mismatch → abort); a stolen code is single-use + short-lived + useless
without live participation in the exchange; account-scoping blocks other
accounts; constant-time compares throughout; the channel key comes from ECDH, not
from the low-entropy code alone. Implemented in Python (client) + Dart (desktop)
with shared cross-language test vectors and explicit MITM/abort tests.

### 15.1 Persistent trust — one code, then never again

The code is entered **exactly once, ever**. Both sides persist a trust record at
the end of step 6 (host: `paired.json`, `0600`, next to the `0600` device seed;
app: `flutter_secure_storage` — never SharedPreferences, the channel key and the
device seed are key material). Each record holds the stable `channel_id`, the
channel key, and the peer's `device_id` + approved Ed25519 public key. The
records are keyed per peer device, so more than one device can be paired later
without a format change.

**The code is single-use and the host enforces it.** A completed pairing burns
it in-process before anything else can fail; a host that starts with a stored
trust never mints one at all, so there is nothing to print, type, or replay. A
stolen code meets a reconnect challenge it cannot answer. The deliberate way
back is `cowork-host --pair` (or deleting `paired.json`), which drops the trust
and mints **one** fresh code — the previously paired device stops working.

**Reconnect** (`cowork_crypto.reconnect` / `cowork_reconnect.dart`) replaces the
ceremony from then on: a mutual signed-nonce challenge against the *stored*
long-term Ed25519 keys, over `RT = N_i ‖ N_j` bound to the `channel_id`, with a
different label per role. No code, no SAS, no ECDH — the channel key is the
stored one. Identity is what counts, not the address: either side may change IP
and reconnect. An imposter without the peer's private key cannot produce a
proof, so the handshake aborts and **no frame codec is ever built** — sealed
frames from an unauthenticated device are dropped even if the channel key leaked.
Replay (old nonces) and reflection (one role's proof presented as the other's)
both fail, and Python/Dart are byte-identical against shared vectors.

The UI follows: the code form appears only before the first pairing. After that
the app auto-connects on launch and re-dials with capped backoff after a drop —
no status strip, no disconnect button, only a **Forget** action that deletes the
trust and brings the code form back.

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
- **UI = a ChukChat clone.** The chat UI looks exactly like ChukChat. The one
  structural change: **the sidebar lists bots, not chat links** — where ChukChat
  shows conversations, cowork shows the bot roster (§16.1). **No thread list**
  under a bot, because there are no threads (§4). Same MCP servers, same skills,
  bundled and shipped. Minimal for now but built at real scale — these pieces are
  **copied first** from ChukChat, then trimmed.
- **UI:** a messenger — roster of agents, **one permanent session per agent (no
  threads)**, Hermes-style streaming run with collapsible tool lines and
  **Stop**, file/screenshot cards.
- **In-UI control surface:** activate/deactivate skills, connect/disconnect
  integrations, pick/see the model, live **token usage**, **session runtime**,
  and the **cron schedule / next runs** — all in the GUI, not a CLI.
  Slash-commands optional, never the boundary. (Called "the moat" until
  2026-08-20; now table stakes — see §17.)
- **Debug "copy chat" button.** Copies the **exact raw context sent to the model
  this round** (system prompt + verbatim head + compacted tail + injected notes +
  pulled-blob ids) to the clipboard. Because compaction rewrites the context every
  round, this is the only way to see what the model actually saw vs the pretty
  transcript — the debugging surface for the whole memory system
  (`docs/context-compaction-design.md` §8). Cheap; ship early.
- **Self-description is real, not a boast.** "What can you do / what tools do you
  have?" answers with the bot's **loadable skills (name + description)** and its
  **connected MCP servers**, read straight from the always-on prompt inventory —
  not "I can write Python" (`context-compaction-design.md` §9).

### 16.1 Borrowed from Hermes Bot Mode (verified 2026-08-20)

Nous shipped **Bot Mode** bundled and default-on in **Hermes Desktop v0.20.3
(2026-08-16)**, with a `SESSIONS | BOTS` sidebar in **v0.20.4 (2026-08-18)**.
It is the same product shape as §1, and it is MIT, so the design is ours to
take rather than to re-derive. What to copy into `app/`:

- **Roster as a sidebar tab strip, not a list under the sessions** — Hermes
  ships `SESSIONS | BOTS` tabs with per-bot hide/unhide. A roster nested under
  a session list stops scaling at ~10 agents. Our `agent_roster_view` already
  exists; give it the tab strip.
- **One canonical, permanent thread per agent.** In Hermes, `/new` on a bot
  silently becomes `/compact`: a coworker you have to "start a new chat" with
  is not a coworker. Our §7.3 context ladder is exactly the machinery that
  makes this affordable — wire it to compaction, not to a new thread.
- **Roster row = avatar + latest-message preview + timestamp + status**, plus
  an "Active now" strip for agents currently working. The run view already
  streams tool lines; the roster needs the one-line version of the same state.
- **Avatars are identity, cheap to build, carry the whole illusion:**
  name-derived generated face, geometric mark, uploaded image, or an
  AI-generated portrait. Image generation is already in the backend.
- **Creation asks three fields only** (name, title, description), with
  clone-an-existing-agent, per-agent model/provider, per-agent skill toggles,
  and a persona file behind an "advanced" fold. The Workspace entity (§4)
  already holds all of it — the win is the three-field front door.
- **Group rooms with hard caps, not free-for-all.** Hermes caps a room at
  **six** bots, **three** serial rounds per message, **ten** messages per send.
  Those caps are a cost control as much as a UX one, and they answer the §20
  open question ("multi-agent group-thread model") with numbers someone has
  already load-tested. Adopt the shape; keep the caps server-side so they tune
  per plan tier.
- **Scheduled work belongs to an agent, not a global cron page** — Hermes
  namespaces routines `[bot:<name>]`. Same list, same runner (§13); the
  ownership is what makes it legible.
- **Cross-machine handles `@name-device`.** Needed the moment a user runs
  agents on a laptop *and* a server; costs nothing to reserve the shape now.

Deliberately **not** copied: bot-to-bot DMs via temp files (we have the frame
protocol) and `hermes peer` as a CLI-only cross-machine path (our transport is
the relay, §14).

---

## 17. Positioning & moat (vs Hermes Agent)

Hermes Agent (Nous, MIT) validates the stack almost 1:1 — Python, container
sandbox, `SKILL.md` skills, cron, MCP, subagent delegation, agent memory. We are
not inventing an unproven shape; we are **borrowing a proven one under a
permissive licence** (§18).

**Correction, 2026-08-20 — the GUI moat is gone.** This section claimed "a real
GUI control surface, not a CLI/slash-command bot" as the differentiator. Nous
shipped **Bot Mode** in Hermes Desktop v0.20.3 (2026-08-16): agent profiles
become a roster of named bots, each with role, model, memory, skills and avatar,
each with a persistent thread, able to @mention each other, meet in group rooms
and run routines — in a desktop GUI. That is §1, shipped by someone else, in a
plugin reportedly prototyped in a day. **"We have a real app and they have a
CLI" is no longer true and no plan may lean on it again.**

What still differentiates us, hardest-to-copy first:

1. **The phone is the product, not a bridge.** Hermes has **no native mobile
   app** (verified 2026-08-20). Remote access is `hermes dashboard` in a
   browser, or a Telegram/Discord/Slack bot fronting `hermes serve`. Our whole
   premise — message your coworkers from your phone, the work runs on your own
   machine, the run streams into the thread — is the surface they reach through
   someone else's messenger, where the message also crosses that platform's
   servers in the clear.
2. **Nothing to self-host.** Hermes remote means running `hermes serve` on a
   VPS or a home server with provider keys in `~/.hermes/.env`. Ours: one
   install script on the laptop, sign in with the account you already have; one
   bill, model routing included (§7.4). Product vs distribution.
3. **A real device trust model.** Their desktop reaches a remote gateway with a
   URL + username/password or OAuth via the Nous Portal — **no device approval,
   no pairing** (verified 2026-08-20). Ours: E2E frames the relay cannot read,
   per-device Ed25519 identity, client-side approval the server cannot flip
   (§14, §15). Stolen credentials alone do not get code execution on the
   laptop. This is architectural, not cosmetic — they cannot bolt it on without
   redoing their gateway auth.
4. **We own the pipeline front to back** — app, backend, relay, sandbox, model
   routing — so the cost levers (§7.3, §7.9) and margins are ours. Hermes is
   bring-your-own-provider by design.

Stated plainly: the roster/messenger UI is now a **known shape with a free
reference implementation**, so it earns no premium and buys no time. Build it
from their design (§16.1) rather than exploring it, and spend the saved effort
on 1–3, which they cannot answer without shipping a mobile app and redoing
their auth.

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
- **File→md = anydoc**; OCR/images/video = **open-weight** vision/video model via
  backend, default **`qwen/qwen3.6-35b-a3b`** (no Tesseract, no Gemini). §9.
- **Tools built on Python + `uv`.**
- **Git-versioned workspace** (§7.7): the sandbox home is a git repo, mutating
  actions auto-commit, the UI offers undo/time-travel — with the honest limit
  that git undoes files, not external side effects.

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
- Interactive terminal backing (§7.8): tmux vs PTY + a `pyte` screen emulator.
- **Interactive login hand-off over VNC/noVNC (§9 browser).** Mechanism decided:
  the agent **ends its browser loop**, asks the user to open a noVNC view of the
  container Chromium (headful under Xvfb), the user logs in privately, closes it,
  and tells the agent "done" → the agent resumes with the authenticated session.
  Safe by construction (loop ended = no observation to leak the password).
  Renderer chosen (§9): **x11vnc + the pure-Dart `flutter_rfb` library**, bridged
  to the existing sealed E2E channel via an in-app loopback socket (no webview —
  the app stays browser-free — and no fork of the lib). Verify `flutter_rfb`
  keyboard input + a served encoding first (~1h; `dart_vnc` is the backup).
  Open: how the remote-control view is surfaced into the chat thread and torn
  down; the "your turn / done" signalling; the optional agent-gets-credentials
  mode that feeds the browser→script skill; which ready-made Xvfb/VNC image to
  base the sandbox side on. Also: bot-fingerprint spoofing (low priority, kept
  separate).

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
