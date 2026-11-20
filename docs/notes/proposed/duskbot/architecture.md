# DuskBot: architecture and infrastructure analysis

Read-only analysis. Clone: `/home/user/git/chuk_chat/_scratch/duskbot` (v0.2.25, shallow).
All paths below are relative to that clone root unless they are absolute.

License: PolyForm Noncommercial 1.0.0 (`LICENSE`). Use the ideas only. Do not copy code.

## 0. Summary of the product shape

- Desktop app (Electron + React) plus a Node "harness" server (`server/`, port 8799).
- The harness runs next to the bot. It can be: this computer, a dusk cloud "My Cloud" machine, or the user's own VPS.
- The app talks to the harness directly (same machine, SSH, HTTPS, Tailscale), through a Cloudflare tunnel, or through a relay.
- Relay = "link service" (`apps/link-service`), a small Node app on two or three cheap VPSes.
- Bots run "engines" = existing agent CLIs (Claude Code, Codex, Grok, Gemini, Qwen, Kimi, Cursor, Copilot, ...) plus an own OpenAI-compatible loop.
- Each bot can have a "computer": a browser (own CDP client on Chrome) and/or a desktop (Cua Driver over VNC/X11).
- Scale: 3,173 test files in the clone (find count). CI uses sharded vitest.

The most reusable ideas are in the security layer (bot-box, credential broker, egress gate, self-check) and in the runtime contract (one task record, explicit restart policy, invariant tests).

## 1. Process and component architecture

### 1.1 Where agents run

| Place | What runs | Source |
|---|---|---|
| This computer (Mac, Windows, Linux) | Electron app embeds the harness (`ELECTRON_RUN_AS_NODE`, asar, compiled `server/` in Resources) | `build/electron-builder.yml`, `docs/linux-desktop.md` |
| dusk cloud "My Cloud" | One InstaBox Firecracker microVM per paid customer (Debian 13, Docker in the image). Public URL is the Fly app. | `apps/cloud-service/docs/provider.md`, `docs/cloud-pro.md` |
| Own server (VPS) | Docker image or install script. `duskbot.service`. Bots reach it through a Cloudflare tunnel, Tailscale, SSH, or the relay. | `deploy/docker-compose.yml`, `deploy/Caddyfile`, `docs/self-hosting.md`, `docs/byo-vps.md` |
| Bot desktop (per bot) | One Docker container per bot: Debian trixie, TigerVNC Xvnc :1, Openbox, Chromium, Cua Driver, noVNC on :6901 | `deploy/bot-desktop/Dockerfile`, `deploy/bot-desktop/README.md` |

Note: `docs/cloud-pro.md` says "Fly app". `apps/cloud-service/docs/provider.md` says "InstaBox". The two docs disagree on the provider name. The provider doc is newer (2026-11-11). Treat InstaBox as current, Fly as legacy text. Check this before using either in our plan.

### 1.2 Harness internals (server/)

- `server/index.ts` is the composition root. `server/host/` holds about 218 host modules (policy, approvals, cards, rooms, routines, wait states).
- `server/runtime/` implements the job runtime contract (see 2.1). `docs/runtime-contract.md` is the spec.
- `server/routes/` holds about 193 HTTP/SSE routes. A table file (`server/routes/table.ts`) maps them. VNC/RFB and desktop viewer are upgraded WebSockets (`rfb-handshake.ts`, `desktop-viewer.ts`).
- `server/drivers/` holds one file per engine (see section 2).
- `server/bot-box/` holds the sandbox, egress gate, harness gate, credential broker.
- `server/browser/` holds the browser stack (own CDP client, Chrome launch, SOCKS egress gate, viewers).
- Persistence: SQLite (`node:sqlite`) for runtime and messages (`DATA_DIR/runtime.db`, `messages.db`). AGENTS.md says new server data goes to MongoDB (`docs/mongodb.md`). The code therefore mixes SQLite and Mongo. This is a known transition.

### 1.3 How the app talks to the server

- Local: loopback. The server trusts loopback as owner. Browsers never get that trust.
- Remote: "the link" tries in order: direct, Cloudflare tunnel on your server, dusk bot relay. Frames are sealed with AES-256-GCM. Only app and server hold the key (README "How it fits together").
- Live screens: WebRTC (node-datachannel, UDP range 30000-30063). Fallbacks: Cloudflare TURN, then the relay.
- Events: SSE (`flush_interval -1` in Caddy so streams are not buffered).

### 1.4 Relay and sync (apps/link-service)

- Plain Node, no npm dependencies (`apps/link-service/README.md`). Modules in `apps/link-service/src/`: `relay-limits.mjs`, `fair-use.mjs`, `turn.mjs`, `push-relay.mjs`, `packages.mjs`, `grant.mjs`, `nodes.mjs`.
- The relay is "blind": it passes sealed blobs. It keeps hashed verifiers and public keys.
- Pairing codes: 7 characters, one setup, works only while the setup waits. Rate limits: 30 wrong codes an hour per address, 2000 an hour total.
- Own-server agent (`apps/link-service/agent.mjs`) is signed (`agent.mjs.sig`). Servers pin release keys (`RELEASE_KEYS`). `apps/link-service/release.mjs` signs it. CI signs it in `.github/workflows/link-agent-sign.yml`.
- Capacity (`docs/capacity.md`, measured 2026-11-14): one node process (one core) carries about 1000 servers with 3000 sockets at 33% CPU on Contabo. Caps are set in `relay-limits.json`. Two nodes (Contabo, Oracle A1) are the current fleet. A Hetzner CX22 (about 5 EUR/month, 20 TB EU egress) is the planned third node.

### 1.5 Offline and reconnect

- Chats and runtime state survive restart. The runtime replays from its SQLite event log (`docs/runtime-contract.md` §5).
- The app keeps a last-seen clock per computer (`shared/seen-clock.ts`, `electron/cloud-last-seen.mjs`).
- Sleep handling: a laptop sleep is not a stall. Timers use the monotonic clock (`turnStallMs`, runtime contract §6).
- The desktop keeps a sleeping computer awake for an hour before a due routine (README "Routines").

## 2. Drivers and ACP

### 2.1 What a "driver" is

A driver is one adapter per engine. The contract is `ProviderDriver` / `ProviderInstance` in `server/contracts.ts`. The registry is `server/drivers/builtIn.ts` (`BUILT_IN_DRIVERS`, 25 entries). A driver:

- spawns or connects to the engine (CLI child process, JSON-RPC, or HTTP),
- lists models and runs a model catalog probe,
- starts and resumes sessions,
- maps the engine's events to the common `RuntimeEvent` stream,
- declares capability flags.

Capability flags are the important part. `server/runtime/capabilities.ts` declares `resume`, `nativeReviewer`, `full`, `edits`, `stepCap`, `subagents`. The runtime reads these flags and never checks driver names (runtime contract §8). This is a good pattern. Copy it.

### 2.2 Engine list

Native, one protocol each:

- `claude.ts`: Claude Code over `stream-json` in both directions, one retained CLI process per thread.
- `codex.ts` + `codex-app-server-pool.ts`: Codex app-server. Warm pool, idle close after 5 min (`CODEX_IDLE_MS`).
- `pi.ts`: pi coding agent over its own stdio JSON-RPC (`pi --mode rpc`), not ACP.
- `grok.ts`: Grok CLI (native mode).
- `openai-compat.ts`, `openai-chat.ts`, `openai-responses.ts`: OpenAI-compatible endpoints. These run dusk's own tool loop.
- `mistral.ts`, `cerebras.ts`, `groq.ts`, `minimax.ts`, `greenference.ts`, `meta.ts`, `muse-code.ts`: API-key providers, mostly on the OpenAI-compatible path.
- `antigravity.ts` / `antigravity-acp.ts`: Antigravity runtime.
- `local-inject.ts`: local models (Ollama, LM Studio).

ACP (Agent Client Protocol, JSON-RPC 2.0 over stdio, see `agentclientprotocol.com`):

- `server/drivers/acp/core.ts` is one shared ACP driver. Per-CLI quirks sit in an `AcpSupport` object.
- Engines on ACP: Grok agent, Gemini, Kimi, Droid, Cursor, OpenCode, Qwen, Hermes, Cline, Copilot, DeepSeek, and a `customAcp` driver for any user CLI (`acp/custom.ts`, `docs/custom-engines.md`).
- `acp/host.ts` is one ACP process with many sessions. One host, many threads. This is a good design for a single process serving many agents.
- Permissions fail closed: only an `allow`-kind option approves; option order is never a security contract (`acp/core.ts` header).
- Foreign provider keys are stripped from custom CLI environments, so a custom CLI cannot bill against another login (`docs/custom-engines.md`).

### 2.3 Own loop vs. CLI engines

- Sign-in engines (Claude Code, Codex, ...) run their own tool loop. dusk gives them its tools through an MCP server mounted per turn (README "Apps and AI").
- API-key and local engines run dusk's own loop.
- Long tool lists are slow. `docs/agents-tool-bridge.md` tests a `find_tool` / `use_tool` bridge (65-74% smaller tool list). It is off by default because the measured cost did not drop.

### 2.4 Approval mapping

`docs/approval-levels.md` maps four dusk levels (Ask, Edits, Auto, Full) onto each engine's native modes, with the engine's own reviewer where it has one. Table at lines 268-290. Useful reference for our approval design.

## 3. Computer control, remote desktop, browser automation

### 3.1 Browser

- Own CDP client in TypeScript (`server/browser/cdp/`). No Playwright dependency.
- Chrome launched directly (`server/browser/chrome/launch.ts`). Profiles per workspace (`chrome/profile.ts`).
- Backends (`server/browser/backends.ts`): `local`, `my-chrome`, `cdp-url`.
- Egress: SOCKS gate with the same address policy as the engine egress gate (`server/browser/egress/`).
- Human check handoff: `server/browser/human-check.e2e.test.ts`, "Take control" in the UI (README).
- `agent-browser.json` at the root is only the Chromium launch args (`--use-mock-keychain,--password-store=basic`). It is not the agent-browser library.
- Desktop-app browser: `WebContentsView` with `webContents.debugger` (CDP). Zero extra install (`docs/computer-use-integration.md`).

### 3.2 Desktop control

- Local: `cua-driver` (trycua/cua, Rust binary). Packaged for macOS and Ubuntu x64. Only provider for local control. Linux Xorg only. Wayland fails closed (`docs/linux-desktop.md`).
- Remote per-bot desktop: Docker container, Xvnc :1 (TigerVNC) + noVNC v1.6.0 + Cua Driver 0.47.24. Wheel is pinned and SHA-256 checked (`deploy/bot-desktop/Dockerfile`).
- Viewer: the harness answers the RFB handshake itself and sends the whole opening at once (`server/routes/rfb-handshake.ts`). DES challenge is isolated in `vnc-des.ts`.
- The app draws the bot pointer over the live view from Cua Driver's reported coordinates. The real cursor is blank (`omb-hidden` theme). Good idea for clean screenshots.
- Human takeover: "Take control" pauses bot input. Only a person can take or release control. The bot never sees passwords.

### 3.3 Version drift to watch

- `package.json` has `@trycua/cua-driver` 0.28.2.
- `deploy/bot-desktop/Dockerfile` pins 0.47.24.
- `docs/computer-use-integration.md` and `docs/linux-desktop.md` talk about 0.19.3.
This is docs drift. Check the current pin before copying any number.

## 4. Cloud VMs: provider, provisioning, isolation, cost

### 4.1 Provider

- Per-customer microVM: InstaBox (`apps/cloud-service/docs/provider.md`). Firecracker, Debian 13, AWS us-west-2. Their API has create, start, stop, suspend, resume, delete, snapshot, exec, and ports.
- Public ports are HTTPS proxy (`http`) or raw TCP admin-only. No inbound UDP, so WebRTC falls back to TURN or relay.
- Older docs also name Fly Machines (`docs/cloud-pro.md`, `deploy/docker/Dockerfile` comment).
- Sub-processors list: Contabo (relay), Cloudflare, InstaBox, Dodo (billing), Brevo (mail), Composio (apps). See `docs/LAUNCH.md` line 234.

### 4.2 Provisioning

- The account service (`apps/dashboard/server/`) creates one machine per paid cloud with an idempotent name (`dusk-<cloud>-<attempt>-<scope>`) and `Idempotency-Key`.
- Machine boots, installs the home package (`server/cloud-home-start.ts`, `apps/cloud-service/deploy/Caddyfile`), runs under systemd.
- Self-check at boot, then a signed health report to the Admin.
- Updates: signed home package, rolled out to a chosen cloud list first (canary), then wider (`docs/releases-auto-update.md`).

### 4.3 Isolation

- Inside the VM, each bot turn runs in a bubblewrap "box" (`docs/bot-box.md`). Mount, PID, network namespaces, seccomp (34 syscalls blocked), env allow-list.
- The box does not give a separate Linux user per bot. They say this is not built.
- The bot desktop is a Docker container. "Free" mode allows passwordless sudo. Free mode is not used on plain runc without user-namespace remapping or gVisor (`deploy/bot-desktop/README.md`).

### 4.4 Cost hints (from their docs, currency not stated in source)

- InstaBox (`docs/limits.md` line 90): vCPU 0.4 c/h, memory 0.225 c/GiB-h, disk beyond 200 GiB 0.008 c/GiB-h, paused machine pays disk only. 2 vCPU / 4 GiB = 1.7 c/h, about 12 per month if always on.
- InstaBox includes 1 TiB/month egress (`docs/limits.md` line 98). Overage rules are in that file.
- Relay: Oracle A1 and Contabo for the fleet. Hetzner CX22 about 5 EUR/month, 20 TB/month EU (`docs/capacity.md`).
- Brevo free tier for sign-in mail, 300/day (`docs/capacity.md`).
- Budget rules: 30 machine starts per minute per workspace, per-machine idle pause 5-30 min, activity lease 30 s to 1 h (`apps/cloud-service/docs/provider.md`).

## 5. Security

### 5.1 Auth and pairing

- Loopback owner trust. Browsers never get it (README "Security").
- `duskbot pair`: single-use code, 5 min. Sessions last 30 days, renew on use. Five wrong codes lock an address 10 min.
- Caddy in front: optional basic auth. Webhook path is public by design (own per-hook secrets).
- Sign-in by email code allowed only for listed addresses (`DUSK_SIGNIN_EMAILS`).

### 5.2 Secrets

- AI sign-ins and API keys: OS keychain on desktop (`electron/secure-credentials.mjs`), `0600` key file elsewhere.
- Vault logins: encrypted files in data folder with `0600` keys beside them. Harness types them into the browser, or hands them to a tool. The model never sees the value (README "Vault").
- Card secrets from the app: HPKE (`@hpke/core`, `server/card-seal.ts`). Per-start ephemeral key, signed by the server's long-term identity key, which the app pins. The relay cannot swap keys (`server/card-seal.ts` header).
- Credential broker (`server/bot-box/broker.ts`, `docs/bot-box.md` "The credential broker"): provider keys never enter the box. Each process gets a per-process token (24 h max, revoked on exit). Base URL points to a local broker over a unix socket. The broker drops the client credential, adds the real key, and forwards to a fixed upstream. The box cannot choose the upstream.
- Gap they admit: keys for engines that take no base URL stay raw in the box. The report names them under `broker.unbrokered`.
- Subscription logins (`~/.claude`, `~/.codex`) sit inside the box because the engine needs them.

### 5.3 Sandboxing

- Local Mac/Windows: no box. Trust rests on approvals.
- dusk cloud and own VPS: bubblewrap box per turn when `DUSK_BOT_BOX=1` or cloud home (`server/bot-box/detect.ts`). Off if unprivileged bwrap is missing.
- Egress gate (`server/bot-box/egress-gate.ts`): HTTP CONNECT proxy in the box. The gate resolves DNS itself and connects only to public addresses. It refuses this machine, LAN, link-local, cloud metadata, and Fly private network by address. Redirects do not bypass it.
- Harness gate (`server/bot-box/harness-gate.ts`): inside the box, the server port only answers `/api/internal/*` with a per-turn capability bearer.
- Self-check (`server/bot-box/self-check.ts`, `box-probe.ts`): at boot, runs a probe in a real box with a canary and counts 29 checks. Mutation mode (`--mutate=bind-data,share-pid,share-net,env-all,tmp-shared`) removes one protection and must fail exactly the checks it guards.

### 5.4 Approvals

- Four levels: Ask, Edits, Auto, Full (`docs/approval-levels.md`). Each bot has one. Inherited level is capped by what the engine can really do (`shared/approval-mode.ts`).
- Real questions and missing sign-ins always reach the person.
- Full access "Just do it": the requester answers, not the person, but only for work the person or a routine started. Outside webhooks still ask the person.
- Restart rule: a cut turn that already did something outward (sent, posted, pushed, paid) is not rerun. The runtime asks the host via `outward(a)` (runtime contract §5).

### 5.5 Known open risks (from their docs)

- No per-bot Linux UID. All bots share the box user `maus`, separated by namespaces only.
- Egress gate covers the engine, shell and MCP helpers. The browser has its own SOCKS gate. Two code paths to keep correct.
- Some engines keep raw keys (see 5.2).
- Webhooks are public by design.
- Anonymous usage counts and crash reports are on by default, opt-out (`docs/analytics.md`).

## 6. Updates and distribution

### 6.1 Desktop

- Electron, electron-builder (`build/electron-builder.yml`). `publish: null`, so builder does not upload. Releases go out by script.
- macOS: DMG and ZIP, arm64 and x64 separately (not universal). Squirrel.Mac via a 127.0.0.1 feed (`electron/app-update.mjs`). Only a same-Developer-ID app can be replaced.
- Windows: NSIS installer, `electron/app-update-windows.mjs`.
- Linux AppImage replaces its own file (`electron/app-update-linux.mjs`). `.deb` shows a link to its installer.
- Manifest: `https://dusk.bot/releases/latest.json`, fallback to a GitHub downloads repo. Signed with an Ed25519 release key (`RELEASE_KEYS`, `kid: rel-2026-11`). SHA256SUMS hash must match the signed manifest.
- Check schedule: 20 s after launch, every 30 min with jitter, 30 s after wake. Install on quit or at a quiet moment (locked or 10 min idle, no turn or call running).

### 6.2 Linux packages

- `.deb` (APT installs dependencies, sets Chromium sandbox) and AppImage (static runtime, no libfuse2). `docs/linux-desktop.md`.
- Built by `.github/workflows/package-linux.yml` on `ubuntu-24.04`, with a smoke test that installs the `.deb` on a clean Ubuntu and checks the handed-over command.
- No APT repository in the clone. Install is a `.deb` download from GitHub Releases. No `apt` source list is shipped.
- Windows: `.github/workflows/package-win.yml`, `windows-defender-check.yml`.

### 6.3 Server and home

- Docker image `ghcr.io/duskbotai/duskbot:latest`, multi-arch (`deploy/docker/Dockerfile`, comments mention Raspberry Pi and ARM). Built by `.github/workflows/server-image.yml`.
- Bot desktop image `ghcr.io/duskbotai/dusk-desktop:v6`, built by `bot-desktop-image.yml`.
- Own-server install: `curl -fsSL https://dusk.bot/s/<code> | sh` (install script, systemd unit). Four ways: Cloudflare, relay, Tailscale, SSH.
- Own-server updates: signed VPS package, agent asks link service every 10-15 min, root timer installs when no bot works. Self-test plus rollback (`docs/releases-auto-update.md`).
- Release orchestration: `scripts/release-all.ts`. Steps: preflight, desktop rollout 10 then 50 then 100 percent, cloud package canary, watch with halt rules, own servers, link agent. A halt signs a block policy.

### 6.4 Mobile

- Phone app: Capacitor 8 (`apps/mobile`, `@capacitor/android`, `ios`). Push via `@capacitor/push-notifications`. Secure storage via `@aparajita/capacitor-secure-storage`.
- iOS companion is native (`docs/ios-companion.md`). It pairs with the Mac by QR and stores nothing itself.
- Phone never runs agents. It is a window onto a computer.

### 6.5 Update policy (signed)

`{ serial, floor, blocked, paused?, rollout? }`, signed with `apps/cloud-service/scripts/sign-update-policy.ts`. Serial only grows. Rollout bucket 0-99 drawn once per install and kept. Desktop reads policy from two URLs.

## 7. Testing

- Unit and integration: vitest (`pnpm test` runs vitest, broker tests, electron node tests, packaged-server test). About 3,173 test files.
- Real Electron tests: `test:electron` runs `electron/*.node-test.mjs` under node test runner.
- E2E: `*.e2e.test.ts` (393 files). Real harness with fake engines. Fake CLIs live in `server/testing/` (`fake-claude-cli.ts`, `fake-codex-app-server.ts`, `fake-acp-cli.ts`, `fake-pi-cli.ts`, ...). Good pattern: real protocol, scripted fake engine.
- Invariants: runtime suite asserts I1-I10 after every scenario (`server/runtime/invariants.ts`, runtime contract §7).
- Scenario and chaos: `server/testing/*-clock-hooks.mjs` inject clocks (wait, stall, resume, power). `apps/link-service/chaos`, `link-chaos.yml` CI workflow.
- Visual baseline: `scripts/testing/visual-baseline.ts` captures approved screenshots (light and dark, desktop and smallest window). A shot passes when under 0.2% of pixels move beyond a small tolerance. Diff picture written beside each capture. Approved set in `scripts/testing/visual-baseline/`.
- Verification recipes: `docs/verification/README.md`. Launch an isolated fixture with `pnpm control:dusk launch`. Never verify against the user's live data. This is a strong rule.
- Benchmarks: `scripts/bench-*.ts` (switching, desktop, persistence, observation, browser stream). `docs/capacity.md` has measured numbers.
- CI: `.github/workflows/ci.yml` (lint, typecheck, shards, electron smoke, packaged-server, Windows CUA smoke, broker tests, evals). `ci-retry-list.json` lists known flaky tests with automatic retry.
- Gap: CI references `pnpm eval` and an `evals/` folder, but `evals/` is not in this clone (shallow or excluded). Cannot verify the eval suite here.
- Gap: no test of the public relay under load in CI. Load was measured by hand (`docs/capacity.md`).

## 8. Ten most worth-taking ideas for Chuk Chat Agents

Ranked by value for us. Our stack: Python host on the user's machine, blind WebSocket relay, Flutter app, rented cloud VMs planned.
Effort: S = under 1 week, M = 1-3 weeks, L = more than 3 weeks for one person (rough guess).

1. **Credential broker: keys never enter the agent process or the VM.**
   Evidence: `server/bot-box/broker.ts`, `docs/bot-box.md` "The credential broker".
   Why for us: rented VMs are where a leaked key hurts most. Per-process tokens, revoked on exit, fixed upstream, dropped client credential. Add an "unbrokered" report, as they do.
   Effort: L (needs every provider base-URL path). Start with the two providers that take a base URL.

2. **Explicit restart policy: never rerun a cut turn that already acted outward.**
   Evidence: `docs/runtime-contract.md` §5 table; `outward(a)` port in §8.
   Why: a crash after "send email" or "pay" must not send or pay twice. Our Python host needs one rule and one test.
   Effort: M.

3. **One task record, append-only event log, invariant checks in tests.**
   Evidence: `docs/runtime-contract.md` §1-2 (record, lifecycle), §7 (I1-I10), `server/runtime/invariants.ts`.
   Why: every state change is one transaction with its event. The row can be rebuilt from events (I7). Invariants run after every scenario test.
   Effort: L for the full model; M for the log plus invariant check on a subset.

4. **Egress gate: resolve names in the gate, refuse private and metadata addresses, no redirect bypass.**
   Evidence: `docs/bot-box.md` "The two gates", `server/bot-box/egress-gate.ts`.
   Why: a cloud VM with metadata service at 169.254.169.254 is a classic SSRF target. Our VM agents need this in front of all outbound traffic.
   Effort: M (a small CONNECT proxy in Python or Go, plus a test list of addresses).

5. **Boot-time self-check with mutation mode.**
   Evidence: `server/bot-box/self-check.ts`, `box-probe.ts`, `docs/bot-box.md` "The self-check and the report".
   Why: proves each protection works on this machine, and proves the test catches its removal. Report goes to the health endpoint. Cheap insurance on VM images.
   Effort: S-M.

6. **Sealed relay frames, per-start secret key, pinned identity key.**
   Evidence: `server/card-seal.ts` header (HPKE seal, per-start key, signed by long-term identity key pinned by the app), README "How it fits together" (AES-256-GCM frames), `apps/link-service/README.md` (blind relay, hashed verifiers).
   Why: our relay is already blind. Adding pinned server identity stops a relay from swapping keys. Secrets typed on the phone are opened only by the host.
   Effort: M.

7. **Sandbox each agent process on Linux VMs (namespaces plus seccomp), with a private data folder and an env allow-list.**
   Evidence: `docs/bot-box.md` "What a boxed process sees", "What each layer stops", `server/bot-box/seccomp.ts`, `server/bot-box/env.ts`.
   Why: our VM agents run as one user with everything visible. Mount and PID namespaces plus an env allow-list cut the blast radius cheaply. Note their own gap: no per-bot UID.
   Effort: M (bubblewrap wrapper, env list, seccomp list copied as an idea from the doc, not the code).

8. **Capability flags per engine, one ACP core, fail-closed permission rule.**
   Evidence: `server/runtime/capabilities.ts`, `server/drivers/acp/core.ts` header, `server/drivers/acp/custom.ts`, `docs/custom-engines.md`.
   Why: the runtime never branches on engine name. Adding an engine is one support object. Permission option matching: only an allow-kind approves.
   Effort: S-M.

9. **Signed update policy with rollout buckets, pause, floor, and a canary watch that halts.**
   Evidence: `docs/releases-auto-update.md` (policy, steps, halt rule), `electron/app-update.mjs` (pinned RELEASE_KEYS, sums check), `apps/link-service/release.mjs`.
   Why: rented VM agent images need the same: serial numbers, staged rollout, a kill switch that stops new starts. Our Flutter app update path can reuse the manifest and key pin.
   Effort: M-L.

10. **Bot desktop as a per-task container with noVNC, human takeover, and a cursor drawn in the app.**
    Evidence: `deploy/bot-desktop/README.md`, `deploy/bot-desktop/Dockerfile` (SHA-pinned downloads), `server/routes/rfb-handshake.ts` (first picture one round trip), `docs/byo-vps.md` (Take control, noVNC on random loopback port, no VNC published).
    Why: a visible, takeover-able desktop for logins and captchas is a real product gap. Their design is a good reference for our VM-side desktop.
    Effort: L (image, viewer, takeover state).

Honorable mentions (not in the top 10):

- Visual baseline with a pixel-diff threshold (`scripts/testing/visual-baseline.ts`). S. Good for the Flutter app. Use golden images with the same 0.2% rule.
- Vault that types secrets so the model never sees them (README "Vault", `fill_login`). M.
- Capacity doc with measured numbers and explicit add-a-node rules (`docs/capacity.md`). S, process idea only.
- Tool bridge with `find_tool` / `use_tool` (`docs/agents-tool-bridge.md`). Their own measured result: no cost saving. Skip unless our tool list gets large.
- Scratch cleanup for bot desktop (`deploy/bot-desktop/README.md` "Temporary files"): clear only scratch, never user files. S.

## 9. Things to avoid (their open issues and our lessons)

- Two persistence layers (SQLite and Mongo) in one codebase. Pick one per data class and write it down.
- Provider naming drift in docs (InstaBox vs Fly). Keep one current source.
- Cua driver version drift across docs and package.json.
- Keys for some engines kept raw in the box (`broker.unbrokered`). Say so in the product, as they do in their report.

## 10. Open questions for the team

- Do we want a separate Linux user per agent VM first, or namespaces first? Their answer: namespaces first, UID later.
- Is our relay blind enough that a pinned server identity key is worth the work now?
- Which engines need a base-URL path for the credential broker? Start with those; list the rest in a report.
- Confirm current pinned Cua driver version before any copy.
