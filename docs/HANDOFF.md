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

**MCP client + Tool Search + the OAuth bridge landed** (§9 / §7.2 / §10) —
`agent/src/cowork_agent/{mcp_client,tool_search,oauth_bridge}.py`:

- **MCP as the fallback protocol**, on the official `mcp` SDK (2.0), all three
  transports (stdio / SSE / streamable HTTP), **one persistent transport thread
  per server** so a session survives across tool calls. Servers come from
  `<workspace>/.cowork/mcp.json` (or `mcp.json`), editor-shaped
  (`{"mcpServers": {...}}`). Tools register as `mcp__<server>__<tool>` with the
  server's own schema. A server that does not answer costs only its own tools —
  `check_fn` false, error in `MCPManager.errors`, nothing in the prompt.
- **Tool Search (§7.2)**: once the deferrable (= MCP) schemas pass 10 % of the
  effective input budget, they leave the prompt and `tool_search` /
  `tool_describe` / `tool_call` replace them. Core tools are structurally
  undeferrable (`ToolRegistry.defer` refuses a tool that did not opt in).
  Measured: 160 MCP tools = 15 930 prompt tokens → 403, **−97 %**, per round.
- **OAuth bridge (§10)**: client side complete — flow start through the backend,
  redirect terminating on the **public** backend URL, `hmac.compare_digest` state
  compare, expiry, single-use code, Event-gated wait with a timeout. **The
  backend routes do not exist yet** — the contract is
  `docs/MCP_OAUTH_BACKEND_ROUTE.md` and the tests implement it as a fake.
- Wired in `build_runtime`: `loop.mcp` (close it when the run ends) and
  `loop.tool_search` (the measured decision).
**browser-use fallback (§8/§9) landed** — `agent/src/cowork_agent/browser.py`:
`browser_task` (a task in plain language, bounded at 12 steps / 40 hard, result
capped, screenshots pushed through the `send_file_to_user` sink), a
`BackendChatModel` adapter that makes browser-use's `BaseChatModel` Protocol run
on **our** `ModelClient` (so every browser step bills the account through
`api.chuk.chat`; no provider key, no token in the sandbox), and a per-task usage
block (`model_rounds`, tokens, `structured_retries`) so a browser session can
never spend invisibly. Chromium lives in a separate image variant,
`sandbox/docker/Dockerfile.browser` (`cowork-browser:latest`,
`COWORK_SANDBOX_IMAGE=` to use it); the base image stays browser-free.
`check_fn` keeps the tool out of the prompt without browser-use + a Chromium (or
`COWORK_BROWSER_CDP_URL`). Verified against a real install + real Chromium in a
throwaway container — see the module docstring for the measured numbers.
**Open wiring:** `build_runtime` only registers it when it is given a
`browser_model` (or an `aux_model`), because the loop's own client is wrapped for
streaming and would push every browser step's JSON into the chat. The executor
does not pass one yet — one line in `executor.py`
(`browser_model=self._model_factory()`), deliberately left to the executor's own
milestone.

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

## DONE — the Stop button is really wired (`agent/wire-stop`)

The app had a Stop button that sealed `{"type":"stop"}` and the executor ignored
unknown payload types, so nothing happened: the run continued and the UI sat on
"Stopping…" until the task finished on its own. What landed:

- **`stop` is a first-class in-frame payload** (`executor/protocol.py`), sealed and
  signed like every other frame — so only an **approved device** can end a run
  (default deny is the whole authorisation story). It **names its target**:
  `request_id` (exact, relay level) or `session_key` (what the app has). A stop
  naming nothing stops nothing, because "abort whatever runs" races the next task.
  Every stop is answered with `{"type":"stop_ack","stopping":[ids]}` — sent
  *before* the interrupt fires, so it can never lose the race with the `done` it
  causes.
- **The executor got a second thread.** Tasks used to run on the serve thread, so
  no frame could be read while a task ran — the stop physically could not arrive.
  Now: serve thread parses frames, one worker thread runs tasks (serial, one
  sandbox + one db), and a run registry maps `requestId`/`session_key` → the
  task's `KillSwitch`.
- **`KillSwitch` notifies listeners** (`on_interrupt`). That is what cancels work
  *in flight*: the executor hangs the sandbox's new `cancel()` and the model
  client's `cancel()` on it, and the subagent supervisor registers `cancel_all` on
  its `parent_kill` — so one interrupt at the root walks the whole tree in a single
  call, children nobody is waiting on included.
- **`BaseEnvironment.cancel()`**: Local kills the process group, Docker kills the
  exec client plus the tree inside the container. Not sticky — the shell still
  works afterwards, because the journal commit after a stop needs it.
- **`BackendModelClient.cancel()`** closes the socket and marks the turn cancelled
  so the retry-once path does not spend credits on an answer nobody waits for. The
  loop reports `INTERRUPTED` when a model call dies while the switch is set.
- **The loop polls three places** now: loop top, right after the model turn (so a
  stopped run cannot report `finished`), and before each tool call of a multi-call
  turn (each skipped call still gets a result row).
- **ESTOP** = `touch ~/.cowork/ESTOP` (the host prints the path and `cowork-host
  status` shows it). Children inherit the parent's sentinel path, so an engaged
  ESTOP also stops a child nobody is waiting on.

Still not cancellable in flight: the §9 media/ffmpeg tools (they shell out beside
the `Environment` seam, so they end at their own timeout — 600 s default, 3600 s
max) and `web_fetch`/`web_search`/vision HTTP calls (bounded by their own 20–180 s
timeouts).

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
- **`uv run pytest` in `agent/` used to run the SYSTEM python** (`/usr/bin/python3`
  + `~/.local/lib`), because `pytest` was only an optional extra and `uv run` fell
  back to the one on `PATH`. That silently tested against whatever version of a
  dependency happened to sit in `~/.local` — `mcp` 1.25 instead of the pinned 2.0,
  whose `ClientSession` takes a `timedelta` where 2.0 takes a float. `pytest` is a
  real dev dependency now, so `uv run pytest` uses `agent/.venv`. If a test
  suddenly cannot import something, check `uv run python -c "import sys;
  print(sys.executable)"` first.
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

---

## Overnight autonomous session (2026-08-20 → 21)

Context: user away, "merge das all, launch subagents, build a very good working
version by morning, set an hourly cron, keep building, research what the
competitors have." No questions; local cron only (never cloud).

**Merge: DONE.** All 15 agent branches are in `master`. The last open one,
`agent/live-verify`, merged as `d3ce819` — its `cowork_thread_view` change
(remove the status strip) was already achieved by `pairing-persist` on master,
so master's superset was kept and live-verify's more descriptive test name
taken. Full suite re-verified green:

| Suite | Result |
|-------|--------|
| common/cowork_crypto | 65 pass |
| agent | all pass |
| executor | 34 pass |
| manager | 93 pass (serial; the "flake" was parallel-load only) |
| host | 63 pass |
| sandbox | 58 pass (serial; the "flake" was parallel-load only) |
| app (Flutter) | 177 pass, 3 skip (was 160; +17 tests) |

The two "failures" are real-Docker tests starved when all 5 Python suites spin
containers at once; each passes in isolation. Worth a fix (serialize the
container fixture, or a session-scoped lock) so CI on a loaded box is not red.

**Competitive research (2026-08-20): Hermes shipped our moat.** Nous Research
bundled **Bot Mode** default-on in Hermes Desktop v0.20.3 (2026-08-16), sidebar
`SESSIONS | BOTS` in v0.20.4 (2026-08-18): agent profiles become a roster of
named bots — role, model, memory, skills, avatar each — persistent per-bot
thread, @mention between bots, group rooms (≤6 bots, ≤3 rounds, ≤10 msgs/send),
per-bot routines. That is §1 of our plan, shipped first, in a GUI. Plan §16.1 +
§17 rewritten: the "real GUI vs CLI bot" moat is dead; what still stands is
phone-native control (they have NO mobile app), zero self-hosting, and the
device trust model (E2E + Ed25519 + client-side approval; they use URL +
password/OAuth, no pairing).

### Overnight build backlog (from §16.1, safe to build without the user)

Ordered; each lands with tests + a commit. NONE of these touch prod or spend
credits.

1. **Per-bot hide/unhide** — DONE (roster source + view + tests). The
   `SESSIONS | BOTS` tab strip itself is deferred: SESSIONS needs a cross-agent
   thread-aggregation model the app does not have; opened as its own item 1b.
2. **Agent avatars** — DONE (name-derived `AgentAvatar`: stable hue from the
   agent id, monogram; roster row + "Active now" strip use it). No fabricated
   last-message preview — the codebase never invents data; the row keeps real
   activity + timestamp. Uploaded/AI-portrait tiers wait on a byte store.
3. **Three-field agent creation** — DONE, the honest subset. The onboarding
   sheet already had Name + Job + optional Files/Schedule; added an optional
   **Role** (§16.1 Bot Mode's "title"), shown under the name in the roster.
   Role is display-only metadata the user typed, exactly like the name — it
   does NOT fake a host-side model/skill config the executor cannot consume, so
   the deliberately-not-faked fields (per-agent model, skill toggles) stay out
   until the host has an agent-config API. Made the onboarding/shell tests find
   fields by label instead of brittle positional indices while here.


4. **Group rooms** — orchestration core DONE; wiring is split out below.
   `manager/group_room.py` is the pure, transport-free heart: `GroupRoom`
   (immutable, ≤6 members, unique handles/ids), `RoomCaps` (Hermes 6/3/10,
   configurable), `parse_mentions` (known-handle-only, ordered, deduped, honours
   cross-machine `@name-device`), and `RoomSession` — the turn driver that
   enforces the caps and reports why it stopped (`no_more_mentions` /
   `rounds_exhausted` / `messages_exhausted`). 19 tests. **Still open:**
   4a. **Room store** — DONE. `manager/room_store.py`: `rooms` + `room_members`
       tables, CRUD, member order by `position`, the ≤6 cap enforced at the DB
       edge (count before insert) and again by `GroupRoom` on rehydration, caps
       persisted per-room, `ON DELETE CASCADE` so deleting a room drops its
       members. 10 tests.
   4b. **Room runner** — DONE (orchestration + context + stop seam).
       `manager/room_runner.py`: `RoomRunner` drives a `RoomSession` through a
       `turn_fn(RoomContext) -> str` seam, builds the shared context each speaker
       reads (`RoomContext.as_prompt()` = user message + prior `@handle: text`
       replies), checks a `stop()` predicate between turns (reason `stopped`),
       and turns a crashing turn into `turn_failed` instead of raising. 7 tests.
       **Still open (4b-relay):** the real `turn_fn` that runs a member's
       executor turn over the relay and seals each reply as a frame — the last
       mile, needs a live executor per member.
   4c. **App UI** — a room thread that shows who is speaking each round and the
       stop reason; a create-room flow (pick ≤6 coworkers).


5. **Per-subagent token budget** — DONE (mechanism). The loop now takes a
   cumulative `token_budget` (prompt + completion, `StopReason.token_budget_
   exhausted`, one-round overshoot max) and reports `LoopResult.tokens_spent`
   even when uncapped; `build_runtime(token_budget=)` and
   `SubagentLimits.max_child_tokens` thread it to children, so a wedged/looping
   child cannot burn credits unwatched. Default stays uncapped (a real cap is a
   pricing decision, not a code default); the executor's `subagent_limits` sets
   one. **Still open:** surface the subagent list + per-child spend in the app
   (the `subagents` table + `tokens_spent` now carry the data) — item 5b.
6. **Wire `browser_model` in `executor.py`** — DONE. `_handle_task` now passes
   `browser_model=self._model_factory()`, a separate lazy client (opens no
   socket unless `browser_task` runs, which needs a Chromium in the sandbox), so
   the chat stream stays free of browser-step JSON and the base image is
   unaffected. Fixed the one test that assumed exactly 2 factory calls per
   delegating task (now 3: stream, browser, child).
7. **De-flake the parallel Docker fixture** — ROOT-CAUSED, no code change
   needed. Every package suite is green run on its own (`uv run pytest` per
   package). The only failures appear when 5 Python suites spin Docker
   containers **at the same time** (the overnight verifier did this) and a
   container is starved before its first `exec`. CI runs packages separately, so
   this does not bite there. If a single loaded box ever runs them together, add
   a cross-process container lock or `-p no:xdist`; until then it is a
   test-harness note, not a bug.
5b. **Surface token spend in the app** — DONE for a **run**: `done_payload`
   carries `tokens_spent`, the relay client parses it, and the done card shows
   "done · 3 rounds · 1,234 tokens" (hidden at zero/absent so an old host reads
   differently from a real 0). **Still open:** the subagent *roster/list* view —
   the `subagents` table persists handles and `subagent` frames already reach
   the controller, but the app drops them (`default: break`); needs an event
   class + a compact per-child view (state/progress/result/spend).
5c. **Per-child token spend on the subagent line** — DONE. A child's
   `LoopResult.tokens_spent` now flows into its `SubagentRecord` and its
   `subagent_state` summary (omitted at zero), the relay client parses it onto
   `CoworkRelaySubagent.tokensSpent`, and the child's line reads "writer ·
   succeeded · 4,321 tokens". `TOKEN_BUDGET_EXHAUSTED` maps to a FAILED child
   state, same as the other ceilings. +2 Python tests; app tests extended.


8. **1b: `SESSIONS | BOTS` tab strip** — DONE. The roster gained a segmented
   `Bots | Sessions` strip (§16.1). BOTS is the coworker list (default, so all
   existing behaviour is unchanged); SESSIONS is a flat, most-recent-first list
   of every conversation across every visible coworker, built from the roster
   the app already holds (agent + thread + the thread's own last-activity — a
   thread with no activity sinks, never gets a fabricated time). Tapping a
   session selects that thread. +2 tests (24 in the roster file).


### Gates that STILL need the user (not auto-run)

- Prod `relay-crossreplica` deploy on the chat server — it can take chat down.
  (Note: the chat-side `cowork_peers.py` fix already shipped there as `d0732c1`,
  verified live 2026-08-20; this gate is about pointing CoWork at the prod relay,
  not the fix itself.)
- Any real-credit task run.
- The by-hand release-client pairing pass (release build has burned us twice).
