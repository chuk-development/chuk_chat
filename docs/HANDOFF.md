# CoWork — Handoff / Takeover

Read this + `docs/COWORK_AGENT_PLATFORM_PLAN.md` (the canonical plan). This file
is the live state of the build so a fresh agent can continue.

Repo: `/home/user/git/cowork` (new monorepo, separate from `/home/user/git/chuk_chat`;
merged later). Git on `master`. Plan is canonical HERE (a stale copy sits in
`chuk_chat/docs/`).

## What exists (packages, all tested green)

| Dir | Package | What | Tests |
|-----|---------|------|-------|
| `common/cowork_crypto` | cowork_crypto | E2E frame crypto (byte-identical to the Dart in `app/`) + SAS pairing (§15) + X25519 channel key | ~53 pytest |
| `agent/` | cowork_agent | agent loop (structural continue/finish, dual-counter termination, ESTOP+interrupt), self-registering tool registry, `run_command`, append-only SQLite state (resume by id, session_key routing), model client. **Tool calls are parsed from `<tool_call>` in the assistant CONTENT** (chuk_chat protocol), not structured. `BackendModelClient` talks the real `wss://api.chuk.chat/v2/ws`; `SupabaseSession` = access+refresh token (token only, never password). | ~50 pytest |
| `sandbox/` | cowork_sandbox | `BaseEnvironment` ABC (`_run_bash`+`cleanup`) + snapshot-file session persistence + Local/Docker backends | 14 pytest |
| `manager/` | cowork_manager | roster (SQLite, random names), supervisor, scheduler (parse+tick), relay frame contract | ~10 pytest |
| `executor/` | cowork_executor | `Executor` (compose loop+sandbox+crypto), loopback transport, `ExecutorSupervisor`, backend model factory | 11 pytest |
| `host/` | cowork_host | **`cowork-host` CLI** — a blind localhost relay + Manager + §15 pairing INITIATOR + task serving. `--mock-model` (offline, no credits). Reads supabase creds from the token or `--supabase-url/--anon-key`/env. | ~10 pytest |
| `app/` | Flutter | CoWork controller app: security-stack port from chuk_chat, real Supabase login, **real chat UI** (`cowork_thread_view.dart`), `CoworkRelayClient` (connect → pairing JOINER → provision token → sendTask → stream), pairing joiner. | ~40 tests |

**Subagents (§7.6) landed** — `agent/src/cowork_agent/subagents.py`:
`delegate_task` + `subagent_control`, one child per `task_id` with its own
environment (built through the sandbox factory) and its own state DB, handles
persisted in the `subagents` table so the app can list them after a restart, live
child output streamed to the parent, a heartbeat that keeps a waiting parent off
the inactivity timeout, per-child kill switch, depth/concurrency/pause caps
(2 / 4 per level / 900 s), and a git worktree + branch per child that is merged
back on success (§7.7). On in the executor with
`Executor(subagent_sandbox="local"|"docker")`; off by default.

## What works (verified live)

- **Local encrypted end-to-end, cross-language**: the real Dart `CoworkRelayClient`
  pairs with the live Python `cowork-host` over a `ws://127.0.0.1` relay, the app
  provisions the account token, a task runs in the sandbox, encrypted results
  stream back. Confirmed live: host log reached `paired`; a task created a file.
- Dart↔Python crypto is byte-identical (shared vectors).
- Real model access: `BackendModelClient` over `/v2/ws` with the account token +
  refresh; the app provisions `access/refresh/user_id/supabase_url/anon_key` so
  any host works without being pre-configured.

## Bugs fixed this session (the pairing saga — all committed)

1. **Single-use pairing** → host now mints a FRESH pairing session per controller
   connection (stable code, per-connection session). `host c707f27`.
2. **`ws://` through the cert-pinned connector** dropped the socket in release →
   `defaultRelaySocketConnector` uses a plain WebSocket for `ws://`, pinned only
   for `wss://`. `app` (in `92851d9`/earlier).
3. **Pairing race** (THE one that made it work): the Dart client processed inbound
   pairing envelopes concurrently; `device-c` ran before the awaited `confirm-c`
   transitioned state → `wrongState`. Now inbound pairing steps are serialized on
   a queue. `92851d9`.
4. **Host missing supabase creds** → app sends them in the token. `92851d9`.

## DONE — persistent pairing (Task #24, `agent/pairing-persist`)

"One code, then never again" is landed and **live-verified** (see §15.1 of the
plan for the design):

- Trust persists on both sides (`paired.json` 0600 / `flutter_secure_storage`).
- **The code is single-use, enforced by the host.** It is burned the moment a
  pairing completes; a host with stored trust mints no code at all. Recovery is
  `cowork-host --pair` (drops the trust, mints ONE fresh code).
- Code-free reconnect = mutual signed-nonce challenge against the stored Ed25519
  keys. Imposter / replay / reflection / wrong-channel / wrong-peer all abort
  with no channel, proven in Python, Dart, and against the live host.
- The app auto-reconnects with capped backoff; the code form appears only before
  the first pairing; **Forget** is the only connection control.

Two release-class bugs were found and fixed while landing it:

1. `provisionAccount` read the peer device id off `_pairing`, which is null after
   a reconnect → every auto-reconnect threw "Cannot provision before pairing
   completes" and served no task. Now tracked on both paths, with a regression
   test that was proven to fail before the fix.
2. `_rebuildController` awaited `StreamSubscription.cancel()`, which returns
   Dart's root-zone `Future._nullFuture`. A `flutter_test` FakeAsync zone never
   drains root-zone microtasks, so the auto-reconnect only ran after the test
   ended. Cancel without awaiting.

## How to run / test

- Host: `cd host && uv run cowork-host` (real; creds ride the token) or
  `uv run cowork-host --mock-model` (offline, no credits). Prints a **single-use**
  code + `ws://127.0.0.1:8787` — but only until the first pairing; after that it
  prints "Already paired" and no code. `--pair` forces a fresh code.
- Client (debug, shows `[cowork-relay]` logs): `cd app && flutter run -d linux
  --dart-define-from-file=.env`. Release: `cd app && flutter build linux --release
  --dart-define-from-file=.env` → `./build/linux/x64/release/bundle/cowork`.
- In the app: log in → chat → **Connect** (`ws://127.0.0.1:8787` prefilled) → type
  the code → chat.
- Live interop test: `app/test/interop_smoke_test.dart`, env-gated, three halves.
  Pair: `COWORK_HOST_URL` + `COWORK_PAIRING_CODE` + `COWORK_TRUST_FILE`. Then
  restart the host and drop the code var: the same file drives a **cold-start
  reconnect** and an **imposter rejection** against the live host. Each run is a
  fresh Dart VM, so it is a real app restart, not a simulated one.

## Gotchas (these cost hours)

- **Bash tool: foreground `sleep` is blocked → exit 144.** Wait via a
  `run_in_background` Bash with `until grep -q ...; do sleep 0.5; done`, or Monitor.
- **`pkill -f cowork-host` self-kills** (the shell's own cmdline contains the
  pattern) → 144. Use the bracket trick `pkill -f '[c]owork-host'`, and NEVER put
  a `pkill` in the same command as a host launch.
- **Verify against the RELEASE app / live, not just `flutter test`.** `flutter
  test` runs debug (cert pinning OFF) with an injected plain connector — it MASKED
  both release-only bugs above and the timing race (a 5/5 loop passed by luck).
  The debug client (`flutter run`) prints `[cowork-relay]` logs; the host logs each
  pairing step. Use both to localize.
- **Don't burn real credits** — use `--mock-model` for transport/pairing tests.
- Two plan copies exist; edit the one in `cowork/docs/`.
- CodeRabbit has an org-seat error in this environment (`FORBIDDEN`, not the code);
  don't loop on it.

## Currently-running processes to be aware of

- The user may have `uv run cowork-host` running in a terminal on 8787.
- A `flutter run -d linux` debug client may be running in the background.
- Check with `pgrep -af '[c]owork-host'` and `pgrep -af 'release/bundle/[c]owork'`
  / `pgrep -af '[f]lutter'` (bracket trick). Kill stale ones bracket-safe.

## Next steps (in order)

1. Rebuild the RELEASE client and confirm the loop with the user by hand: pair
   once → task → close both → auto-reconnect with no code → task again. The
   headless proof is done (`_scratch/host{1,2,3}.log`), but the release build has
   burned us twice before, so it still needs one real pass.
2. Confirm a REAL task runs against the user's account (needs the user logged in;
   spends real credits — one small task).
3. Then continue the platform per plan §21: the tool set (browser-use, anydoc for
   file→md, host ffmpeg passthrough, send-file, search-chats, first native API
   tools, MCP + the dashboard-OAuth callback bridge), memory + skills
   (frozen-snapshot MEMORY.md/USER.md, FTS5 search, the background-review skill
   fork), the context cost ladder, the interactive terminal (§7.8), the
   git-versioned workspace (§7.7), scheduler/cron + push. (Subagents/multi-agent
   §7.6 is done — see above; what is still open there is the group-thread model,
   a token budget per child, and surfacing the subagent list in the app.)
4. **Gates that need the user** (do NOT auto-run): the real relay = the prod
   `relay-crossreplica` deploy on the chat server (§14/§21.1) — it can take chat
   down for all users; do it WITH the user. The current transport is a local
   blind relay (no prod).

## Working style the user expects

Terse German. Money-focused (flag only money risks: bans/chargebacks/broken
prod). No Artifact tool. Verify before claiming done; re-run subagent proofs
(they've reported false greens here). One capable Opus subagent per focused piece,
orchestrated; the user is fine spending tokens on subagents when asked.
