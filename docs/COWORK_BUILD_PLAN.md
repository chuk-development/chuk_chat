# CoWork — Master Build Plan

**Product definition.** CoWork is a Claude-Cowork-style personal agent (general knowledge/office work, not coding-only) that the user drives *from their phone* while it runs *on their own laptop* with real filesystem/CLI/app access. The laptop runs a persistent, tray-resident daemon that IS the agent (it runs chuk_chat's existing tool loop headlessly, calling OpenRouter directly and executing tools locally inside an OS-level sandbox). The phone is a thin remote control that dispatches tasks, streams back progress, and approves risky steps. Everything routes through api.chuk.chat as a zero-trust, store-and-forward relay that only ever sees signed, E2E-encrypted opaque blobs — so it can delay or drop traffic but can never read, forge, or replay a command. The product's three differentiators vs. Anthropic's Claude Cowork: it runs on the user's *real* machine/toolchain (not a rented VM), the relay is *cryptographically incapable* of reading commands, and the whole thing reuses ~90% of chuk_chat/api_server infra.

---

## System architecture

```
  ┌─────────────────────────┐                                   ┌──────────────────────────────────────────────┐
  │  PHONE (controller)      │                                   │  LAPTOP (executor / agent daemon)            │
  │  chuk_chat mobile        │                                   │  chuk_chat desktop, headless tray mode       │
  │                          │                                   │                                              │
  │  • dispatch task turns   │      outbound WSS (both ends)     │  RemoteAgentService (NEW, headless while-loop)│
  │  • approve / deny        │  ┌────────────────────────────┐  │   └─ ToolCallHandler / ToolPromptBuilder /   │
  │  • view progress stream  │──┤   RELAY  api.chuk.chat      ├──│      tool_parser / ToolEnforcer  (UNCHANGED) │
  │  • FCM/APNs wake target  │  │   /v2/ws multiplex          │  │   └─ ToolExecutor + tool_registry (UNCHANGED)│
  └───────────┬──────────────┘  │   role-tagged, JWT-auth     │  │        ├─ cloud tools → api_server (unchanged)│
              │                  │   pairs controller⇄executor │  │        ├─ MCP tools (mcp_dart, Tier-2)        │
        FCM/APNs push            │   by (user_id, device_id)   │  │        └─ laptop_system tools (NEW):          │
   (firebase-admin, server)◄─────┤   opaque-blob forwarding    │  │             run_command/read_file/write_file │
                                 │   presence map (in-mem)     │  │             process_exec/list_directory      │
                                 │   paired_devices (Supabase) │  │                    │                         │
                                 └─────────────────────────────┘  │                    ▼ policy gate (allow/deny/ │
              every frame = {seq, ts, nonce, ciphertext, sig}     │                      ask→phone) + cwd jail    │
              AES-256-GCM (account key) + Ed25519 (per-device)    │                    ▼ OS SANDBOX               │
                                                                  │             bwrap (Linux/WSL2) /             │
                                 ┌────────────────────────────────┤             sandbox-exec (macOS) /          │
        OpenRouter               │  laptop daemon calls directly  │             ask-every-cmd (native Windows)   │
   deepseek/deepseek-v4-pro ◄────┤  POST /v1/ai/chat (unchanged)  │                    │                         │
   (provider.zdr=true)           │  E2B cloud sandbox = Tier-3    │                    ▼ real FS / CLI / apps     │
                                 └────────────────────────────────┴──────────────────────────────────────────┘
```

**One-line invariants:** the loop lives on the laptop (never re-implemented in Python); the relay is blind store-and-forward; every side-effecting command passes a local policy gate + kernel sandbox before it runs; irreversible actions are draft-then-gate; a backgrounded phone is woken by real push.

---

## 1. Transport: phone ↔ relay ↔ laptop

**Chosen approach: extend the existing `api_server/routers/multiplex.py` `/v2/ws` protocol** with a device-relay mode. Reject WebRTC/TURN (you already run the relay), raw SSH/ngrok/cloudflared (NAT + cost + worse posture), and Supabase Realtime as the command bus (256 KB–1 MB message caps, shared connection quota, and you'd hand-roll the req_id/cancel correlation that `/v2/ws` already has). This resolves the conflict with the MVP/desktop-daemon dossiers, which proposed a `cowork:{userId}` Supabase Realtime channel: Realtime is kept **only** for what it already does well (small Postgres change-feed sync, `user_model_prefs_realtime_service.dart`) and for firing "pairing confirmed / device online" UI events — never for streaming stdout or carrying commands.

**Handshake extension** — add `role` + `device_id` to the existing `auth` frame:
```jsonc
// laptop tray daemon: {"type":"auth","token":"<jwt>","role":"executor","device_id":"<uuid>","device_name":"…"}
// phone:              {"type":"auth","token":"<jwt>","role":"controller"}
```
Server keeps an in-memory `executors: Dict[user_id, Dict[device_id, WebSocket]]` alongside `active_websocket_connections`; presence is free (entry vanishes in the existing `finally` on socket close → emit `executor_status` to controllers). Relay function is ~20 lines: on a `cowork_relay` frame from a controller, look up `executors[user_id][target_device_id]` and forward the opaque blob verbatim; reverse for executor→controller. Backend parses **nothing** inside the payload — same trust boundary chuk_chat already uses for cross-device sync (validated Supabase JWT = same `user_id`). Reuse the `req_id`/`kind`/cancel envelope verbatim.

**Dart client:** add `executorListen()` / `sendCommand()` modes (or a role flag) to `MultiplexConnection` — reuse its `ensureReady()`, reconnect/backoff, heartbeat ping/pong verbatim; that already solves "phone backgrounds / laptop sleeps / Wi-Fi→cellular."

**Offline queueing:** mirror `offline_send_executor.dart` — queue controller commands client-side (or in a small `pending_commands` Postgres table with TTL) and flush on `executor_status: online`. Do **not** promise delivery through laptop sleep/shutdown; surface "laptop offline" honestly (`feedback_silent_failure.md`).

**Wake-the-phone push is genuinely new infra, on the critical path.** `flutter_local_notifications` cannot wake a backgrounded/killed app. Add `firebase_messaging` (client) + drive sends from api_server via `firebase-admin` (Python). Store FCM/APNs tokens in `paired_devices`. Firebase project setup (new GCP project, APNs certs) is a discrete pre-CoWork ops task.

Latency cost of the extra relay hop is +20–80 ms — irrelevant for a command/response UI (dominant latency is model think-time per `project_chat_latency_profile.md`).

---

## 2. Persistent desktop daemon + system tray

**Keep chuk_chat's hardened `SystemTrayService` (`tray_manager` + `window_manager`, hide-not-close, Linux retry/backoff) unchanged; layer daemon behavior on top.** The Dart isolate/event loop already survives window close, so the agent loop keeps running when hidden — no new mechanism needed for "alive while backgrounded."

**New/changed:**
- Bump `tray_manager ^0.5.1→^0.5.3` (fixes tray-icon-vanishes-after-`explorer.exe`-restart — a long-lived-daemon issue) and `window_manager ^0.5.1→^0.5.2`.
- Add `launch_at_startup ^0.5.1` — login-item on Win (Run key) / macOS (LaunchAgent/`SMAppService`) / Linux (XDG `~/.config/autostart/`). Register with `args:['--hidden']`.
- Add `flutter_single_instance ^1.7.0` (built on `window_manager`) — call **before** `runApp`; prevents two daemons racing the same sandbox/tool state after login-launch + manual double-click.
- **Start-hidden-into-tray:** branch on `args.contains('--hidden')` before the first `windowManager.show()` (use `waitUntilReadyToShow` so no window ever flashes on login).
- **Turn on the already-wired-but-disabled desktop notifications:** in `notification_service_io.dart`, remove the `if (!Platform.isAndroid && !Platform.isIOS) return;` gate, add `WindowsInitializationSettings` (AUMID + icon), widen `main.dart`'s notification-init gate to desktop when `FEATURE_COWORK`, and add an `agent_needs_input` category alongside `ai_completion`.
- **Linux packaging gap:** add `libayatana-appindicator3-1` (Ubuntu ≥22.04; `libappindicator3-1` elsewhere) as a runtime dependency in the Flatpak manifest, DEB control, RPM spec — CoWork defaults tray **on**, so it will bite minimal installs otherwise.
- **macOS LSUIElement** (menu-bar-only, no Dock/Cmd-Tab) is an Info.plist, build-time switch read before Dart runs → **separate build target/scheme** (`Runner-CoWork`), not a runtime flag. Decision below.
- **App Nap (macOS):** verify empirically once the hidden daemon does network I/O; an open socket usually prevents it, else a small `NSProcessInfo.beginActivity` native shim.

**Flag:** clone the `kFeatureSystemTray` pattern into a new `kFeatureCowork = bool.fromEnvironment('FEATURE_COWORK', default:false)` gating launch-at-login + single-instance + start-hidden + desktop notifications + all laptop-native tools. Keep `FEATURE_SYSTEM_TRAY` as the narrower "tray icon while window open." `FEATURE_COWORK` defaults `true` only in the CoWork build target. Launch-at-login is default-on in the first-run wizard but a visible opt-out toggle — never silent.

---

## 3. CLI / system access from Dart

**Default path: `dart:io Process.start` (stdlib, no dependency)** — one subprocess per command, explicit `workingDirectory`/`environment`, streamed `stdout`/`stderr` back through the existing tool-loop streaming machinery so the phone sees output incrementally. This matches how Claude Code's Bash tool actually works. Use `Process.run` only for trivial short commands.

- **`runInShell: false` by default** (avoid `/bin/sh -c` injection from model-generated arg strings). A shell-features variant (pipes/globs) is a separate, higher-risk, approval-gated tool.
- Build a **curated env map** (`Platform.environment` snapshot → strip secret-like vars) rather than passing the full shell env; `includeParentEnvironment:true` only where needed (git/npm PATH).
- Kill = SIGTERM then SIGKILL after grace (Windows: hard `TerminateProcess`, documented limitation).

**Interactive path (secondary): `flutter_pty ^0.4.2` + `xterm ^3.2.6`.** Needed for `sudo` prompts, REPLs, TUI installers, anything checking `isatty()`. Use `xterm`'s `Terminal()` **headlessly** to strip ANSI before sending clean text to the phone; only mount `TerminalView` for an optional desktop-side live-terminal panel. Do **not** use the older unstable `pty` package.

**Handle registry:** the tray daemon owns `Map<String,Process>` / `Map<String,Pty>` keyed by an id the tool loop hands the model, so a long build/watch started in one tool call can be polled/killed later (Claude Code's `run_in_background`/`BashOutput`/`KillShell` shape). No new package.

Filesystem/env/cwd use `dart:io` `File`/`Directory`/`Directory.watch()` + `path`/`path_provider` (already deps). Per-tool-call cwd is explicit session state on `ToolLoopSession`, never process-global `Directory.current`.

**Do NOT reuse `api_server/sandbox_client.py` (E2B) for local execution** — opposite venue. Do read it as a reference for retry/timeout/error-classification patterns.

---

## 4. Sandboxing agent execution ("Shells")

**Three-tier, local-first — the strongest cross-dossier consensus.**

**Tier 1 — OS-native sandbox (default), shelled out from the Dart daemon via `Process.start`:**
- **Linux / WSL2:** `bubblewrap` (`bwrap`) + seccomp. Do **not** hand-roll the flag set — adopt Anthropic's OSS **`@anthropic-ai/sandbox-runtime` ("srt")** (`srt run --fs-allow … --net-allow … -- <cmd>`), which already solves Ubuntu 24.04 AppArmor userns, seccomp UDS blocking, `$TMPDIR` wiring, nested-container fallback. Deps: `bubblewrap` + `socat`; detect at daemon start and show a "dependencies missing" state (Claude Code's `/sandbox` UX) rather than silently degrading.
- **macOS:** `sandbox-exec -f <profile>.sb -- <cmd>` with a deny-by-default SBPL profile (writable = workspace + session temp). Ship the `.sbpl` as a bundled asset; a good starting point is Claude Code's open-source profile. Abstract behind a `SandboxBackend` interface — `sandbox-exec` is deprecated with no replacement, so isolate call sites.
- **Native Windows (no WSL2):** **no OS sandbox in v1** (matches Claude Code's shipped limitation). Mandatory **ask-before-every-command**, disclosed in UI as reduced isolation. Recommend WSL2 in onboarding (reuses the Linux bwrap path 1:1). Track Microsoft MXC; don't build on it while it's "not a security boundary."

**Filesystem policy (all platforms):** default write = the Shell's workspace dir (or a git worktree, Tier 2) + private temp; default read = broad **but ship a pre-populated credential denylist** (`~/.ssh`, `~/.aws`, `~/.config/gcloud`, browser cookie stores, chuk_chat's own keyring/`encryption_service` key) — this must be default-on (Claude Code leaving it as opt-in is a documented footgun). **Network:** default-deny via local proxy over a Unix domain socket enforcing a domain allowlist; first new host → "ask" (routed to phone); approved hosts persist for the Shell's lifetime. Document the TLS-not-inspected caveat honestly.

**Tier 2 — git worktree as the workspace unit** for any repo task: `git worktree add ../<repo>-shell-<id> -b agent/shell-<id> <base>`, copy `.env`, root the sandbox there, offer `git merge --no-ff` as an explicit user-approved step at completion (never auto-merge the branch the user has checked out). Reuses chuk_chat's own `CLAUDE.md` multi-agent worktree protocol verbatim → free second isolation layer + a natural mobile diff/approve UX.

**Tier 3 — E2B/Firecracker cloud microVM (reuse `api_server/sandbox_client.py`, zero new backend)** as an escape hatch when (a) the laptop is offline and the user is mobile-only, or (b) a command is classified high-risk (untrusted script, unpinned package). A small Dart-side classifier picks the backend; both share the existing `ExecuteRequest`/`ExecuteResponse` contract.

**Permission model = allow / deny / ask** (Claude Code's three lists, but "ask" pushed to the phone):
- **Deny** (hard, first, defense-in-depth only): `rm -rf /|~|.`, `mkfs*`, `dd of=/dev/*`, fork bombs, `sudo`/`su`, `chmod -R 777 /`, force-push to main/master, `cat ~/.ssh/*`, `curl … | sh` from non-allowlisted hosts.
- **Allow** (auto-run in sandbox, no prompt): read-only/inspection (`ls`, `cat` non-secret, `git status/diff/log`, `rg`, test/lint/build with no network). This is what makes CoWork async-usable, not prompt-per-command.
- **Ask** (default bucket): new network domain, `git push`, installs, anything outside workspace, anything the classifier can't confidently bucket → push to phone with exact command + cwd + shell id; **timeout resolves to DENY**, never auto-approve, never block forever.

**Load-bearing:** command-string pattern matching is **UX/defense-in-depth, never the boundary** — 2026 GuardFall research bypassed 10/11 popular agent guards via shell rewriting. The kernel-enforced OS sandbox on the running process is the actual boundary. Document this in code and to the user.

**Resource limits:** Linux `systemd-run --scope --property=CPUQuota/MemoryMax` wrapping `bwrap` (fallback: `--unshare-cgroup`); macOS `setrlimit` + a hard wall-clock kill from the Dart supervisor. Reuse the E2B `SANDBOX_EXEC_TIMEOUT` (300 s/cmd) / `SANDBOX_DEFAULT_TIMEOUT` (1800 s idle) conventions so local and cloud shells share one mental model. **Containers (Docker/Podman) are an explicit opt-in "stronger isolation" mode, not the default** — VM cold-start on macOS/Windows undercuts the "your real toolchain" value prop.

---

## 5. Securing the channel & local agent

**The relay is permanently untrusted store-and-forward** (new `routers/cowork_relay.py`, or the extended `multiplex.py` from §1): holds a Supabase-RLS `paired_devices` table, fans out opaque encrypted blobs, logs metadata only (device-id pair, byte size, timestamp, type). It never sees plaintext, never holds a key, cannot author or replay a new valid command. Authorization hangs off the **verified** `verify_token()` path (`main.py:2023`) — explicitly **not** the unsigned-JWT `parse_jwt_scopes` shortcut (`main.py:904`).

**Message envelope (designed for signatures from day one):** `{seq, ts, nonce, ciphertext, sig}`.
- `ciphertext` = AES-256-GCM over the command, reusing `encryption_service.dart`'s existing per-user key and versioned-payload machinery (`cryptography` package, `AesGcm.with256bits()`, `Hkdf`, `Ed25519()`, `Ecdh.x25519()`) — **zero new Dart crypto deps**. This resolves the privacy/mvp dossiers' "reuse the account AES-GCM key" proposal.
- `sig` = **per-device Ed25519** signature over `(seq,ts,nonce,ciphertext)`, **verified before decryption** (cheap fail-closed gate) and before the payload reaches the executor. Per-device keys (generated at pairing, stored via `FlutterSecureStorage`/`_usePrefsBackend`) are what give real per-device revocation and mean a compromised relay still can't forge — this is the security dossier's load-bearing decision, kept even though it's slightly more than "account key only."
- `seq` strictly monotonic per pair (persisted on laptop; `seq ≤ last_seen` dropped) and `ts` in AEAD AD (>60 s rejected) together defeat relay replay.
- Payload session key optionally re-derived every ~500 msgs / 24 h via HKDF for lightweight forward secrecy. Full Noise/Double-Ratchet is an explicit later upgrade, not v1.

Net: a fully attacker-controlled relay can only drop/delay/reorder (bounded DoS — the laptop just executes nothing) and observe metadata. It cannot forge or replay.

**Pairing (Signal-linked-device shape, laptop = device being linked):** laptop generates long-term Ed25519+X25519 keys → renders a QR (`pretty_qr_code`, already a dep) encoding a **short-lived (~2 min) single-use `pairing_code`, never a JWT** → phone (already Supabase-authed, `mobile_scanner`) does ephemeral ECDH→HKDF, encrypts its pubkeys + confirmation to the relay keyed by the code → laptop retrieves, verifies the bound `user_id` server-side, and requires a **local physical "Approve (fingerprint 4F2A…)" click on the laptop** before finalizing. That local Approve is the anchor that stops a compromised relay from pairing a rogue phone. 6-digit numeric entry is the no-camera fallback. The laptop's local trust store is authoritative; the relay's `paired_devices` copy is only for UX/revocation.

**Least-privilege execution — the LLM tool loop is never the trust boundary** (defends against prompt injection making the model *request* `rm -rf`). Every command goes through §4's local policy gate + srt sandbox; destructive/credential/egress classes require the interactive approval round-trip.

**Three kill switches:** (1) **local/instant** tray "panic" — wipe local trust store + device keys, kill all srt children, tear down the WS, zero network round-trip; (2) **remote revoke** — a Devices page flips `revoked_at`; the daemon self-terminates/wipes on its 30 s heartbeat, enforced server-side on every relay message so it works against an offline laptop; (3) **global** env-var circuit breaker in api_server (same shape as `FEATURE_SERVER_TOOLS`) to cut the channel org-wide without a deploy.

**Audit log = legal/business control, not debugging.** Local-first, append-only SQLite (`local_chat_cache_native.dart` pattern): per envelope record sig-verify result, policy decision, command, stdout/stderr **hash** (not content, per `privacy_logger`), exit code, ts; **hash-chain** entries (`entry_hash=SHA256(prev+entry)`) so post-breach tampering is detectable. Lock files to `0600/0700` (Cowork got flagged for world-readable logs). Local-only by default; opt-in encrypted cloud backup. Deleting a session must delete all shards including child-agent transcripts.

---

## 6. The agentic engine (reuse the tool loop)

**The laptop daemon runs the existing chuk_chat tool loop UNCHANGED; that is the agent.** Reuse `tool_call_handler.dart` (`ToolLoopSession`/`ToolLoopStep`/`ToolLoopResult`), `tool_prompt_builder.dart`, `tool_parser.dart` (XML + markdown + Kimi-token), `tool_enforcer.dart`, `tool_executor.dart` + `tool_registry.dart` (45 built-ins), and all five model-recovery paths (malformed/truncated/deferred/empty-final/fact-check) verbatim. **Reject** moving the loop into api_server Python — it would re-implement ~3500 lines of battle-tested Dart, make a stateless proxy into a stateful agent host, and add a hop per tool call. The laptop calls `POST /v1/ai/chat` (OpenRouter, default **`deepseek/deepseek-v4-pro`** — 1M context, long-horizon-tuned) directly with the user's Supabase JWT, so `payment_service.py` billing keeps working unchanged.

**Only genuinely new Dart:** `lib/services/cowork/remote_agent_service.dart` — a headless `while(true)` around the same `ToolLoopResult` contract that `streaming_message_handler.dart` already consumes, minus Flutter widget interleaving. It streams model tokens, calls `processAssistantResponse(...)`, relays coarse events (content deltas, tool-call lifecycle, final answer via existing `toJson()`/`fromJson()`) to the phone, and never runs on the phone.

**Tool routing = three tiers** (see §4). Cloud + cloud-sandbox tools are unchanged. The new **`laptopSystem`** tier lives in `lib/tool_handlers/laptop_system_tools.dart` with a new `ToolCategory.laptopSystem` and `ToolType` for MCP. **Consolidated tool naming** (resolving four dossiers): `run_command`, `read_file`, `write_file`, `list_directory`, plus `process_exec` for interactive/long-running. These are **distinct from the existing `bash` tool** (E2B disposable VM) — the system prompt and registry must never let the model conflate "your real laptop" with "throwaway cloud sandbox." `bash_sandbox.dart` stays untouched for the consumer chat app; CoWork reuses only its `ApprovalCallback` *shape*, not its single-folder/blocklist containment. `process_exec` defaults **off** until the user opts in (mirrors `whoop`).

**Two loop changes CoWork requires:**
- `ToolEnforcer.maxIterations` (hardcoded 24) → **configurable, high** (session cap ~150–300 rounds) + a wall-clock budget, surfaced to the phone as progress. Guard runaway cost given per-token pricing over hundreds of rounds.
- **Session durability:** persist `ToolLoopSession` (`history` + `toolCalls` + `discoveredToolNames`) to the existing SQLite `kv_cache` table so a laptop reboot/daemon restart can rehydrate and resume an in-flight multi-hour task (today it's in-memory and lost).

**MCP (Tier-2 fast-follow):** add `ToolType.mcp`; a laptop-only `McpToolBridge` starts configured servers (stdio/Streamable-HTTP) from `~/.config/chuk_chat/cowork_mcp.json`, lists tools, and registers each as a `ClientTool(type: mcp)` into the same `ToolExecutor._tools` map — flows through existing discovery/`find_tools` compaction. Use **`mcp_dart`** (thin client, fits under `ClientTool`), **not** `flutter_mcp` (bundles a competing agent runtime). Prefer wrapping well-known MCP servers (filesystem, git, browser) over hand-rolling handlers, keeping bespoke handlers only for OS-native gaps (screen capture, clipboard, `open_app`).

---

## 7. Feature set — Claude Cowork parity

Build CoWork as a second execution surface on the existing loop, copying Cowork's load-bearing patterns (validated: Cowork shipped web+mobile cross-device handoff 2026-07-07; its largest usage category is 33.4% general business work vs 8.7% coding — the whole non-coding premise is confirmed).

**Tier 1 (MVP):**
1. Agent loop + tool protocol — reuse (§6).
2. Cloud sandbox — reuse E2B (§4 Tier-3).
3. Local privileged execution — new laptop daemon + srt (§2–4).
4. **Draft-then-gate for irreversible actions** (send email, calendar invite, message post, file delete) — a human tap is *structurally* required; do **not** build checkpoint/undo for things that can't be undone (you can't unsend an email). This is a churn/refund-prevention control, not ethics.
5. **Plan mode = a tool-catalog permission filter** on the existing loop (read-only tools until the user approves a written plan), reusing `_updateDiscoveredTools`/`find_tools` — not a separate model/prompt.
6. **`<tasklist>` visual tag** rendered like `<chart>`/`<map>`/`<email>` in `message_bubble.dart` (model-maintained checklist — disciplines decomposition, gives legible progress for long unattended tasks). Add a **`<shell>` tag** for live terminal output + inline approve/deny.
7. **Memory** — extend the existing `notes` tool (`update_memory`/`update_user`/`update_soul`) for per-task scope.
8. **Cross-device handoff + push** — task state in Supabase; phone subscribes for status + approval-needed; push via FCM/APNs (§1).

**Tier 2:** subagents (bounded child tasks, own tool subset, no further spawning, own context — blast-radius limit); **hooks-equivalent policy layer** (deterministic, non-model-overridable checks in daemon/server code, e.g. "never send to >N recipients without confirm" — must be code, not prompt text, because injected content overrides prompts); checkpoints/rewind for *reversible* work only (documents/generated files, content-addressed snapshot before mutating calls); MCP client (§6).

**Tier 3 (hardening):** full per-task audit trail locked `0600` (§5); time-boxed capability grants for phone-initiated high-risk actions (Cowork's 30-min TTL); **browser/computer-use as a separately gated, explicitly-consented capability** (drives the user's real Chrome via `--remote-debugging-port` + CDP over the existing `web_socket_channel` dep, sharing real cookies — necessarily runs *outside* the sandbox, so higher blast radius; distinct consent screen).

---

## 8. Privacy / local-first architecture

**Three concentric trust zones** (the marketing claim, each clause backed by showable code):

| Zone | Contents | Leaves device? | Protection |
|---|---|---|---|
| 1 Device-only | filesystem/shell contents, raw screenshots pre-redaction, local action log, optional local-model inference | Never | not serialized off-device |
| 2 Relayed | phone commands, laptop output/screenshots | Yes, via relay | E2E AES-256-GCM + Ed25519 (§5); relay sees ciphertext only |
| 3 Cloud inference | the prompt slice for one turn | Yes, to OpenRouter→ZDR provider | TLS + contractual zero-retention |

- **ZDR enforced per request, not just per account:** set `"provider":{"zdr":true}` on every CoWork OpenRouter call (additive/OR'd, can only strengthen) *and* keep api_server's existing ZDR provider allowlist (`ZDR_PROVIDER_ANALYSIS.md`, 158 clean slugs; Chutes/Alibaba/Friendli/Crusoe/W&B/nCompass excluded). Poll `openrouter.ai/api/v1/endpoints/zdr` to refresh the list.
- **Optional local model (not MVP-critical):** ship the daemon with **Ollama** (OpenAI-compatible at `127.0.0.1:11434/v1`) as a default backend for cheap/routine loop steps (file listing, simple greps, low-stakes planning), escalating to the frontier model for hard steps — reuse chuk_chat's existing OpenAI-shaped client code, zero new inference stack. **Reject** embedded llama.cpp/FFI for v1. Gate behind `kFeatureLocalModel`. Needs an eval pass (tool-calling reliability of a small model through the same `tool_prompt_builder` pipeline) before it becomes default.
- **Logging discipline:** client `privacy_logger`/`kDebugMode` gating applies to all new daemon code; server `chat_logger`/`audit_logger` and `usage_logs` (token/cost columns only, zero content) are the pattern for any CoWork usage table. New CoWork audit/action logs live encrypted client-key-only, following the `encrypted_payload` vs `payload` field-name split so plaintext can't accidentally reach Supabase.
- **GDPR/business framing (money, not ethics):** the ZDR allowlist already does the hard compliance work; a one-page subprocessor list + DPA is paperwork that preempts enterprise/B2B buyers and supports a premium data-residency tier on the same architecture. "Commands never leave your laptop unencrypted / the relay can't read them / every inference call is contractually no-train" is a three-part checkable claim neither Claude Cowork (server-side default) nor ChatGPT can make as cleanly.

---

## 9. Packaging, distribution, onboarding

**Phase 1 (days, no new infra):**
- **In-app "update available" banner** on every platform: `GET github.com/repos/chuk-development/chuk_chat/releases/latest`, compare to `pubspec` version, "Download" CTA. Works on Android/DEB/RPM too. Ship before any silent updater.
- **Code signing** (matters more here — a background agent with system access hitting SmartScreen/Gatekeeper reads as malware): macOS Apple Developer ($99/yr) — uncomment the scaffolded `release-macos.yml` block (Developer ID → `codesign --options runtime` → `notarytool submit --wait` → `stapler staple`), switch to the ready `build_dmg`/`build_pkg` Fastlane lanes. Windows — **Azure Artifact Signing** Basic ($9.99/mo, CI via `azure/trusted-signing-action`) *if the entity qualifies* (verify: individual path is US/Canada-only — chuk Development is German, so likely needs registered-business status or a reseller OV cert ~$70–200/yr). **EV is not worth it** (Microsoft removed EV's first-download SmartScreen bypass in 2024).

**Phase 2:** `desktop_updater ^2.7.0` (Sparkle/WinSparkle, SHA-256+length verify) for signed Win/macOS **only**; Linux uses native per-format (Flatpak auto-updates free → prioritize Flathub; AppImage zsync/`AppImageUpdate`; DEB/RPM defer to reinstall). `launch_at_startup` for autostart (avoid msix `startup_task` — empty-args bug).

**Pairing/onboarding (mirrors Claude Dispatch):** QR on desktop (`pretty_qr_code`, existing) + `mobile_scanner ^7.1.4` (new, phone). `POST /v1/pair/init` mints a 2-min single-use `pairing_code`; `POST /v1/pair/confirm` (phone, same account) submits code + device pubkey. QR payload `chukchat://pair?code=…` — **never a JWT**. Pairing-success pushed to desktop via a Supabase Realtime subscription on `paired_devices`. **First-run:** install signed binary → existing Supabase login → full-screen QR "Pair your phone" with live "waiting…" spinner → one-tap "Start CoWork at login" (default on, disclosed) → tray shows connected/idle/disconnected. Revocation enforced **server-side** on every relay message.

---

## What to reuse from chuk_chat

| chuk_chat asset | Reused for | Change |
|---|---|---|
| `api_server/routers/multiplex.py` `/v2/ws` | phone↔laptop relay | +`role`/`device_id` handshake, +`cowork_relay` forward frame, +executor presence map |
| `lib/services/multiplex_connection.dart` | Dart relay client (reconnect/backoff/heartbeat) | +executor/controller modes |
| `tool_call_handler.dart` / `tool_prompt_builder.dart` / `tool_parser.dart` / `tool_enforcer.dart` | the agent loop itself | unchanged (except configurable `maxIterations`) |
| `tool_executor.dart` / `tool_registry.dart` / `client_tool.dart` | tool dispatch | +`laptopSystem` category, +`ToolType.mcp` |
| `system_tray_service_io.dart` + `window_close_service_io.dart` (`tray_manager`/`window_manager`) | persistent tray daemon | +launch-at-login, start-hidden, single-instance |
| `notification_service_io.dart` (`flutter_local_notifications`) | desktop "agent done/needs input" | remove Android/iOS gate, +Windows settings |
| `encryption_service.dart` (`cryptography`, AES-GCM/HKDF/Ed25519/X25519, secure-storage fallback) | envelope crypto + device keys | reuse verbatim, zero new crypto deps |
| `api_server/sandbox_client.py` + `routers/sandbox.py` (E2B) | Tier-3 cloud shell escape hatch | reuse; share `ExecuteRequest`/`ExecuteResponse` with local path |
| `CLAUDE.md` multi-agent worktree protocol | Tier-2 per-Shell workspace | reuse verbatim |
| `local_chat_cache_native.dart` / `kv_cache` (SQLite) | session durability, hash-chained audit log, shell-policy JSON | reuse |
| `offline_send_executor.dart` | laptop-offline command queue | mirror pattern |
| `user_model_prefs_realtime_service.dart` (Supabase Realtime) | pairing/presence UI events only | keep scoped, do NOT carry commands |
| `POST /v1/ai/chat` + `payment_service.py` | model streaming + billing | unchanged (laptop auths as same user) |
| `per_model_system_prompt_service.dart` | CoWork system-prompt additions | reuse |
| `pretty_qr_code`, `privacy_logger.dart`, `platform_config.dart` flags, `io_helper.dart` split, `message_bubble.dart` visual tags | QR, logging, `FEATURE_COWORK`, native-only files, `<tasklist>`/`<shell>` | reuse patterns |
| `.github/workflows/*`, `linux/` Fastlane, `msix_config`, `android/key.properties` | CI/signing/packaging | enable commented signing steps |
| `ZDR_PROVIDER_ANALYSIS.md` + provider filter | CoWork inference routing | reuse gate |

---

## Key architectural decisions

| Decision | Chosen answer | Why |
|---|---|---|
| Transport | Extend existing `/v2/ws` multiplex relay | Zero new infra, outbound-only WSS solves NAT, reuses req_id/cancel/auth; Realtime caps (256 KB) can't stream stdout |
| Command bus vs Supabase Realtime | Multiplex relay for commands; Realtime for presence UI only | Realtime rate/size limits + shared quota + no delivery guarantee unfit for a request/response bus |
| Where the loop runs | Laptop daemon (headless Flutter), phone is thin controller | Preserves 100% Dart tool-loop reuse; avoids re-implementing ~3500 lines in Python + stateful backend |
| Local execution primitive | `dart:io Process.start` default; `flutter_pty`+`xterm` for interactive | Stdlib, streams incrementally, matches Claude Code's Bash tool |
| Local vs cloud sandbox | 3-tier: OS-native (default) → git worktree → E2B cloud (offline/high-risk) | Real-laptop toolchain is the differentiator; cloud is escape hatch, already built |
| OS sandbox tech | `bwrap`/srt (Linux/WSL2), `sandbox-exec` (macOS), ask-every-cmd (native Win) | Both Claude Code & Codex converged here; don't hand-roll seccomp/Seatbelt |
| Security boundary | Kernel OS sandbox on the running process | Command-string denylists bypassable (GuardFall 10/11); model intent is not a trust boundary |
| Envelope crypto | AES-256-GCM (reused account key) + per-device Ed25519 sig, seq+ts anti-replay, sig-before-decrypt | Relay can't read/forge/replay even if fully compromised; zero new Dart deps |
| Pairing | QR (`pretty_qr_code`+`mobile_scanner`) w/ 2-min single-use code + **local Approve on laptop** | QR never carries JWT; local Approve is the anchor vs a rogue-phone-pairing relay; numeric fallback |
| Irreversible actions | Draft-then-gate (human tap), NOT undo | You can't unsend an email; a wrong auto-sent email is a refund/churn event |
| Plan mode | Tool-catalog permission filter on existing loop | Cheap; reuses discovery/filtering; not a separate model call |
| Policy layer | Deterministic daemon/server code, not prompt text | Prompt injection overrides prompts; ~1% injection success at model level |
| Wake backgrounded phone | New FCM/APNs (`firebase_messaging`/`firebase-admin`) | `flutter_local_notifications` can't wake a killed app — critical-path new infra |
| Feature flag | New `FEATURE_COWORK` (consolidates local-CLI/sandbox flags) | Stronger commitment than a tray icon; default-on only in CoWork target |
| Default model | `deepseek/deepseek-v4-pro` via OpenRouter, `provider.zdr=true` | 1M context, long-horizon-tuned; no backend change; per-request ZDR |
| macOS menu-bar-only | Separate `Runner-CoWork` build target (LSUIElement in Info.plist) | Read before Dart runs; not a runtime toggle |
| Windows code signing | Azure Trusted Signing if eligible, else reseller OV | EV lost its SmartScreen edge in 2024; entity eligibility TBD |
| Session durability | Persist `ToolLoopSession` to `kv_cache` SQLite | In-memory today; a multi-hour task must survive reboot |
| Iteration cap | Configurable ~150–300 + wall-clock budget | 24 is chat-tuned; long-horizon tasks need headroom + cost guard |

---

## Security threat model — business-risk summary

The single invariant: **relay compromise must never equal laptop RCE.** If it did, this ships as a "remote-access trojan builder" in a breach headline. Concrete money exposure:

- **Phone-controlled laptop RCE abused** (miner/ransomware/exfil): §202a/303a StGB + EU/US unauthorized-access statutes → mandatory breach notification, Stripe/processor payout freezes pending investigation, chargebacks, user lawsuits, and — public `chuk-development` repo — GitHub org suspension risk. Mitigation: signed+seq+ts envelopes (relay can't forge/replay) + kernel sandbox + local approval; this is exactly the 2026 MCP "STDIO command-injection across ~200k instances" failure ($ from trusting transport to carry authority) that our design forecloses.
- **Prompt injection → destructive command** (poisoned web page/file makes the model request `rm -rf` or exfil `~/.ssh`): dominant real attack path (~1% model-level success). Mitigation: policy gate + sandbox + mandatory approval catch the rest; the deny-list is only defense-in-depth.
- **Secrets leak *through the model*** (`cat ~/.env` puts plaintext into the OpenRouter context): needs a redaction/warn pass on *tool output* before it enters context, plus ZDR. A wrong auto-sent email from the user's real account is a direct churn/refund event → draft-then-gate.
- **Stolen/unlocked phone sends validly-signed destructive commands**: the laptop policy gate + interactive confirm survive even a compromised phone; per-device revocation kills it server-side.
- **World-readable audit logs** (Cowork's own flagged mistake): lock `0600/0700`; hash-chain for tamper-evidence — turns a breach from "assume worst case" into "cryptographic proof of exactly what ran."
- **Windows has no v1 OS sandbox**: disclosed as a business gap, ask-every-command, recommend WSL2 — don't ship false parity.

---

## MVP milestone plan (M0…M7)

Effort: S ≈ 2–3 d, M ≈ 4–6 d, L ≈ 1–2 w. **MVP = M0–M4.**

| # | Milestone | Effort | Reused | New |
|---|---|---|---|---|
| **M0** | Relay + pairing skeleton | S | `/v2/ws` multiplex, `multiplex_connection.dart`, `encryption_service`, `pretty_qr_code` | `role`/`device_id` handshake, `cowork_relay` frame, executor presence map, `paired_devices` table, QR+`mobile_scanner`+local-Approve pairing, envelope `{seq,ts,nonce,ciphertext,sig}`, per-device Ed25519 keygen |
| **M1** | Headless agent daemon | M | full tool loop, `system_tray_service_io`, `POST /v1/ai/chat`, `payment_service`, `launch_at_startup`, single-instance | `remote_agent_service.dart` (headless while-loop), start-hidden, configurable `maxIterations`, `ToolLoopSession`→`kv_cache` persistence |
| **M2** | Laptop-native tools + approval gate | M | `Process.start`, tool_registry/executor, `ApprovalCallback` shape, streaming machinery, `flutter_local_notifications` | `laptop_system_tools.dart` (`run_command`/`read_file`/`write_file`/`list_directory`/`process_exec`), allow/deny/ask classifier, cwd jail, credential denylist, phone approval round-trip w/ timeout→deny, `<shell>`/`<tasklist>` tags |
| **M3** | Push + cross-device + draft-then-gate | M | Supabase task sync (`chat_storage_service`), `notes` memory, `notification_service_io` | FCM/APNs (`firebase_messaging`+`firebase-admin`, incl. Firebase project/APNs ops), draft-then-gate for email/calendar/message, plan-mode tool filter, task-list persistence |
| **M4** | OS sandbox Tier-1 + worktree Tier-2 | L | E2B as Tier-3, `CLAUDE.md` worktree protocol | `SandboxBackend` interface, `bwrap`/srt (Linux/WSL2), `sandbox-exec`+`.sbpl` (macOS), Windows ask-only (disclosed), local network-egress proxy, resource limits, git-worktree workspace + merge-back UX |
| **M5** | Distribution hardening | L | CI skeleton, Fastlane lanes, `msix_config` | macOS notarization + Windows signing enabled, `desktop_updater`, Linux zsync/Flathub, update banner, `libayatana-appindicator` in packaging |
| **M6** | MCP + subagents | L | `ClientTool`/discovery/`find_tools` compaction | `mcp_dart` bridge, `ToolType.mcp`, bounded subagents (own tool subset, no recursion), hooks-equivalent policy layer |
| **M7** | Advanced hardening | L | audit SQLite infra, kill switches | per-device signed-envelope full rollout, hash-chained `0600` audit, time-boxed capability grants, browser/computer-use (CDP, separately gated), optional Ollama local model + eval, per-request ZDR audit |

---

## Top risks & open questions

**Highest-liability risks (money/trust, ranked):**
1. **Prompt-injection → destructive local command** is the single biggest exposure of the whole product. Never ship laptop-native execution without the allow/deny/ask gate; never let approval default to yes on timeout or push failure.
2. **Secrets leak through the model to third-party providers** — needs a tool-output redaction/warn pass before context assembly (new; not covered by existing log-redaction).
3. **Firebase/push is on the critical path and is net-new ops** (new GCP project, APNs certs) — scope it before CoWork ships or "agent finishes while you're away" silently doesn't work.
4. **Windows has no v1 OS sandbox** — ship ask-only, disclosed; recommend WSL2. Don't fake parity.
5. **macOS `sandbox-exec` is deprecated with no replacement** — keep it behind the `SandboxBackend` interface. **App Nap / macOS TCC / Windows UAC** friction needs empirical testing.
6. **Runaway cost** over 150–300 rounds of deepseek-v4-pro — wall-clock + iteration budget mandatory.

**Open product/architecture questions to resolve before/at M0:**
- **Per-device Ed25519 signing at MVP vs. account-key-only** — recommended: ship per-device signing from M0 (it's the load-bearing security decision and cheap given the `cryptography` primitives already exist), account AES-GCM for payload.
- **CoWork as a separate bundle id (`dev.chuk.cowork`, own macOS LSUIElement target) vs. runtime mode in chuk_chat** — affects launch_at_startup packageName + Info.plist permanence.
- **Multi-device addressing:** N phones ↔ 1 laptop and N laptops ↔ 1 account (design the schema for it now; picking a target device on the phone).
- **Auto-reconnect the executor WS on OS boot/login** (survives reboot) — needs OS autostart per platform (dependency of §2).
- **Long-task on laptop sleep/network drop:** resume-from-`kv_cache` (chosen) — silently continue vs. "resume task?" prompt to the phone.
- **Windows entity eligibility** for Azure Trusted Signing (German individual vs. registered business) — determines $9.99/mo vs. ~$70–200/yr.
- **Workspace-root:** single fixed `~/CoWork` (simple, safe) vs. user-configurable per-project (more useful, more cwd-escape surface) — MVP: fixed default, configurable in M4.
- **Headless/unattended laptops** (no one to click Approve): explicit opt-in, much stricter allowlist, no destructive capability — not the default.
- **Deny/allow lists user-editable** (Claude Code `settings.json`) vs. curated by chuk — lean curated for a non-security-expert base initially.
- **Ollama local model:** run through the same `tool_prompt_builder` pipeline vs. a stripped tool subset — needs an eval pass before it's default (M7).
