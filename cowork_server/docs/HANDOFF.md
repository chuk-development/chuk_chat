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


4. **Group rooms** — DONE end to end, locally proven. Every sub-item (4a–4c,
   4b-relay/-drive/-exec/-exec-relay, 4c-shell/-mount/-stream/-stream-wire) is
   built and green; the only remaining step is the user-gated prod transport
   (driving a room from a real host over the prod relay). Detail below.
   `manager/group_room.py` is the pure, transport-free heart: `GroupRoom`
   (immutable, ≤6 members, unique handles/ids), `RoomCaps` (Hermes 6/3/10,
   configurable), `parse_mentions` (known-handle-only, ordered, deduped, honours
   cross-machine `@name-device`), and `RoomSession` — the turn driver that
   enforces the caps and reports why it stopped (`no_more_mentions` /
   `rounds_exhausted` / `messages_exhausted`). 19 tests. Sub-items, all DONE:
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
       4b-relay: the wire contract is DONE both ends. Executor protocol gains
       `room_turn_payload` / `room_done_payload` (the frames a room streams);
       `RoomRunner` gains an `on_turn` hook that fires a `RoomTurn` live after
       each reply (never for a crashed turn); the app parses `room_turn` /
       `room_done` into `CoworkRelayRoomTurn` / `CoworkRelayRoomDone` inbound
       events. +2 manager, +1 executor, +2 app tests. **Still open
       (4b-drive):** DONE (routing + offline handling). `manager/room_driver.py`
       `RoomDriver` fills `RoomRunner`'s turn seam with per-member routing —
       each turn goes to *that member's* agent via a `member_runner(member,
       prompt) -> reply|None` seam — and an offline member (None) gets a fixed
       `OFFLINE_REPLY` placeholder that carries no @mention, so a member whose
       executor is down neither crashes the room nor drags a coworker into a
       fresh round. Streams via on_turn, honours stop + caps. 7 tests.
       4b-exec (routing layer): DONE. `manager/room_binding.py` `RoomBinding`
       is the host's registry of reachable members — register/unregister,
       reconnect last-writer-wins, thread-safe; member_runner() reads it per call
       and returns None for an offline member. TaskSender stays the seam. 7
       tests. 4b-exec-relay: DONE. `executor/room_sender.py`
       `make_room_task_sender` wraps one ControllerSession into the TaskSender
       RoomBinding registers — send the room prompt as a task, return the done
       frame's final_answer (None on error/timeout/empty -> offline placeholder);
       room turns ride a `room:<id>` session_key. 3 tests incl. a full
       RoomBinding -> RoomDriver -> two real encrypted executors end-to-end over
       the sealed loopback. The room path is proven end to end **locally**; the
       only remaining gate is pointing the members' controllers at live executors
       over the prod relay — the user-gated transport deploy.
   4c. **App UI** — create-room flow DONE. `app/lib/models/cowork_room.dart`
       (`CoworkRoom`/`CoworkRoomMember`/`CoworkRoomDraft`, `kRoomMaxMembers` 6)
       + `app/lib/widgets/room_create_sheet.dart`: name + a checklist of
       coworkers, the six-member cap enforced in the form (the rest disable at
       6, re-enable on uncheck), Create gated on a name + ≥2 members. 6 tests.
       4c-thread: room thread view DONE. `cowork_room.dart` gains `CoworkRoomTurn`
       + `CoworkRoomStop` (wire-string parser + human label, matching the
       manager's stop reasons), and `room_thread_view.dart` renders the user
       message, each turn grouped by round with the speaker's avatar/@handle, a
       running indicator, and a footer naming why it ended. 6 tests.
       4c-wire (part 1): `CoworkRoom` model (id + name + members) +
       `LocalRoomSource` (a ChangeNotifier room store mirroring
       `LocalAgentRosterSource`: addRoom assigns an id and enforces the
       ≥2/≤6/unique rules defensively, byId, removeRoom). 7 tests.
       4c-shell (part 1): `RoomListView` DONE — a thin view over `RoomSource`
       (like `AgentRosterView`): one row per room with name, an overlapped stack
       of member avatars + a "+N" chip, a member count, a ＋ New-room affordance,
       and live updates. 5 tests. 4c-mount: DONE. The shell gains a "Rooms" app-bar button that opens the
       rooms screen (`RoomListView`) as its own route — so the agent thread and
       its live socket stay mounted underneath, untouched. New-room opens
       `RoomCreateSheet` (members from the roster) and adds to the shell's
       `RoomSource`; opening a room pushes a `RoomThreadView` page. A room shows
       an honest waiting state (no turns) because driving a room streams over the
       relay from the host, which is the user-gated transport step. +2 shell
       tests (app 205 green). 4c-stream: DONE (the accumulator). `app/lib/widgets/room_thread_page.dart`
       `RoomThreadPage` subscribes to an injected `Stream<CoworkRelayInbound>`,
       accumulates `room_turn` frames into turns and `room_done` into the stop,
       and renders `RoomThreadView` live (running until done); non-room events are
       ignored. Injected stream = testable with a fake controller (4 tests) and
       drivable by the real relay socket unchanged. **Concurrent rooms:** DONE — `room_turn`/`room_done` now carry a `room_id`
       (executor protocol + app parser require it), and `RoomThreadPage` keeps
       only frames for its own `roomId`, so several rooms stream over one socket
       without crossing wires. 4c-stream-wire: DONE. `CoworkThreadView` hands its live controller up
       through a new `onController` callback (fired on build and rebuild; the
       parent must not dispose it). The shell keeps that `_sharedController` and,
       when a room is opened, feeds `RoomThreadPage` its `inbound` so the room
       streams over the *same* socket the agent thread uses — no second
       connection. A shell test proves it end to end: open a room, emit a
       `room_turn` from the fake controller, see it render in the room page.
       Falls back to the static waiting view if the transport is not built yet.


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


### Follow-ups picked from plan §20 (safe, local)

- **Cross-machine handle disambiguation (§16.1)** — DONE. `assign_room_handles`
  in `manager/group_room.py` turns coworkers (`AgentIdentity`: id, name, device)
  into room members with unique mention handles: a plain name when unique,
  `@name-device` when two share a name across machines (the exact form
  `parse_mentions` understands), a numeric suffix on a same-name-same-device
  squat. Names are slugged to mentionable handles, order preserved, and the
  result always builds a valid GroupRoom. 7 tests, manager 152 green.

- **`@all` / `@everyone` broadcast mentions in rooms (§16.1)** — DONE.
  `has_broadcast_mention` recognises `@all` / `@everyone` / `@room`
  (case-insensitive); in round 1 an `@all` seeds everyone (same as no mention),
  and in a reply it re-engages the whole room for the next round — every other
  member in room order, still bounded by the round and message caps, never
  re-triggering the speaker. The group-chat "everyone, again" convention. 5
  tests, manager 157 green.

- **Room task input (app -> host) + composer (§16.1)** — DONE. `room_task_payload`
  (`{type:room_task, room_id, message}`) is the frame that starts a room; the app
  seals it via `CoworkRelayController.sendRoomTask(roomId, message)`, and
  `RoomThreadPage` gains a composer (when `onSend` is set) that sends it and
  resets the thread for the new exchange. The shell wires the composer to the
  shared socket, so a room round-trips on the app side: send a message, watch the
  turns stream back. The host acting on `room_task` (look the room up, drive it)
  is the one user-gated step left. +3 page tests, +1 executor test, shell test
  extended; app 213, executor 40 green.

- **Host room handler (§16.1/4b)** — DONE. `host/room_service.py` `RoomService`
  turns a `room_task` frame into a running exchange: looks the room up in the
  `RoomStore`, drives its members with a `RoomDriver` over the `RoomBinding`
  (each member routed to its own executor), and emits the turns and the end as
  `room_turn` / `room_done` payloads through an `emit` seam (the host binds it to
  seal-and-send; a test captures the dicts). An unknown room ends with
  `no_such_room` rather than silence; an offline member shows the offline
  placeholder; a reply `@mention` drives the next round; caps override honoured.
  5 tests, host 68 green. So the **whole room round-trip is now built and locally
  proven** — app composes `room_task` → host drives the room → `room_turn`/`room_done`
  stream back → app renders. **Still open (host-wire):** call
  `RoomService.handle_room_task` from the host's actual frame dispatch and
  register real per-member `TaskSender`s as executors connect — the live
  transport wiring, which is the user-gated deploy.

- **Room transcripts persist (§16.1)** — DONE. A group room is a persistent
  thread, not a throwaway exchange. `manager/room_transcript.py`
  `RoomTranscriptStore` (SQLite, append-only, ordered by a per-room `seq` so
  repeated round numbers cannot mis-order it) keeps a room's turns; `RoomService`
  clears the room at the start of each new user message and appends every turn as
  it streams, so the stored history is always the current conversation. 7 store
  tests + 1 service test; manager 164, host 69 green. room-history-wire: DONE. `room_history_request` (app -> host) and
  `room_history` (host -> app) frames; `RoomService.handle_room_history` replays
  the stored transcript (empty, never silent, when there is none); the app parses
  `room_history` into `CoworkRelayRoomHistory`, `RoomThreadPage` replaces its view
  with the stored turns (marking the exchange over) and asks for it via a new
  `onReady` once its listener is attached, and the shell wires `onReady` to
  `controller.requestRoomHistory`. So reopening a room now shows its last
  conversation. +4 app, +2 executor, +2 host tests; app 218, executor 41,
  host 71 green.

- **App-created rooms sync to the host (§16.1)** — DONE, and it closes the room
  loop's real gap: rooms were built in the app's `LocalRoomSource` but the host's
  `RoomStore` never learned of them, so `room_task` would hit `no_such_room`.
  Now a `room_create` frame (app -> host) carries `{room_id, name, members}`;
  `RoomStore.create_room` accepts an explicit id (the app owns room identity, a
  clash is refused not overwritten); `RoomService.handle_room_create` builds the
  room on the host — idempotent (a reconnect re-send does nothing), skipping any
  member over the six-cap while keeping the room; and the shell sends it over the
  shared socket the moment a room is created. So create-in-app now really makes
  the room drivable. +1 executor, +2 store, +3 service, +1 shell tests; app 218,
  manager 166, host 74 green.

- **Delete a room (§16.1)** — DONE, and it cascades cleanly. A `room_delete`
  frame (app -> host); `RoomService.handle_room_delete` drops the room from the
  `RoomStore` **and** clears its transcript, so a deleted room leaves no orphan
  behind (and it is a no-op on an unknown room). `RoomListView` gains a per-row
  delete menu (shown only when `onDelete` is set); the shell removes the room
  from its `RoomSource` and tells the host to forget it over the shared socket.
  So room management is complete: create, list, open, message, delete. +1
  executor, +2 host, +2 app tests; app 220, executor 43, host 76 green.

- **Per-agent routines (§16.1 Bot Mode)** — DONE. A routine belongs to a bot;
  the scheduler already tagged jobs with `agent_id`, so this adds the per-agent
  view and cleanup: `Scheduler.jobs_for(agent_id)` (an agent's routines),
  `remove_agent_jobs(agent_id)` (drop them when the agent is deleted — the
  scheduler's twin of the room-delete cascade, so a gone agent leaves no routine
  firing at nothing), and `Job.routine_label(agent_name)` → `[bot:<name>] <id>`,
  the exact namespaced display Bot Mode uses. 3 tests, manager 169 green.

- **Rename a room (§16.1)** — DONE, completing room management (create, rename,
  delete). A `room_rename` frame (app -> host); `RoomStore.rename_room` (unknown
  room -> RoomError); `RoomService.handle_room_rename` (no-op on an unknown room,
  which just has not synced yet); `LocalRoomSource.renameRoom` (trims, ignores
  blank/unknown/no-change); a Rename item in `RoomListView`'s row menu opening a
  small stateful dialog (owns its controller so it survives the exit animation);
  the shell renames locally and tells the host. +1 executor, +2 store, +2 host,
  +2 app tests; app 222, executor 44, manager 171, host 78 green.

- **Room member strip (§16.1)** — DONE. The room thread now shows who is in the
  room: `RoomThreadView` renders a compact horizontal strip of member avatars +
  `@handle` under the room name (hidden when empty); `RoomThreadPage` passes the
  members through and the shell supplies `room.members`. So the user sees the
  coworkers they are addressing, not just the room name. +2 view tests; app 224
  green.

- **Delete a coworker, cascading its rooms (§16.1)** — DONE, closing a real gap:
  agents could be hidden but never deleted. The roster row menu gains Delete —
  offered only for non-host agents (the paired host is the real device, not a
  bot to delete). The shell removes the agent and cascades:
  `LocalRoomSource.removeAgentFromRooms` pulls it out of every room, shrinking
  those that survive and deleting any that fall below two members (a room of one
  is not a room), and the shell tells the host to forget each deleted room, and
  clears the selection if the deleted agent was open. +2 source, +1 roster tests;
  app 227 green.

- **Executor routes room frames to the host (§16.1)** — DONE, and it is the
  low-risk half of the host wiring I had deferred. The executor already opens
  and validates every frame with its one opener; its dispatch now has a
  `room_*` branch that hands the decoded payload up through a new `on_room_frame`
  callback instead of trying to run it as a task (no request-scoped terminal —
  a room's replies are the host's to stream). No crypto change, no second opener,
  no pairing-path change: the whole worry about the transport was avoidable by
  branching at the point the frame is already open. With no handler a room frame
  errors cleanly ("rooms not enabled"); ordinary tasks are untouched. Added
  `ControllerSession.send_payload` (the generic seal-and-send room frames ride).
  3 tests incl. a real sealed-loopback route; executor 47 green. host-room-wire: DONE. The host owns persistent room stores (`RoomStore` +
  `RoomTranscriptStore` files under the workspace, opened per party thread like
  the roster; a thread-safe `RoomBinding` field). `_build_task_server` builds a
  `RoomService` whose `emit` seals a reply and sends it over this session's
  channel (the same path executor results take), and passes
  `on_room_frame=dispatch_room_frame(service, ·)` down through `TaskServer` to the
  `Executor`. `dispatch_room_frame` maps each room wire type to its service call.
  So on a live host, room_create / rename / delete / history now function end to
  end, and room_task routes (driving members via the binding). +2 dispatcher
  tests; host 80 green. What is left needs the user only: **multi-executor** —
  registering a real per-member `TaskSender` in the `RoomBinding` as each
  member's executor connects, so room_task drives online members instead of the
  offline placeholder. That is the multi-agent host + the prod relay.

- **Room open re-syncs to the host + no_such_room is legible (§16.1)** — DONE,
  closing a resilience gap: a room created while the host was offline never
  reached the host, so `room_task` came back `no_such_room` with no explanation.
  Now opening a room re-sends `room_create` first (idempotent on the host, so it
  just repairs a missing room) before requesting history, and `CoworkRoomStop`
  gained `noSuchRoom` → "This room is not on your host yet", so the footer names
  it instead of showing nothing. +1 page test, shell test extended; app 228 green.

- **Agent role in the control panel (§16.1/§16)** — DONE. The panel showed the
  brief but not the role (the Bot Mode "title" the model and roster already
  carry); it now shows the role under the name, in the accent colour, matching
  the roster. Small consistency fix; +1 test, app 229 green. (Also tried a live
  conversation-count line but dropped it — an always-on line pushed a section
  below the lazy ListView's viewport and broke an unrelated widget-count test;
  not worth the fragility.)

- **Room membership editing (§16.1)** — DONE (data/protocol/service/source),
  the last room-management gap: create/rename/delete existed but you could not
  change who is in a room. `room_add_member` / `room_remove_member` frames;
  `RoomService.handle_room_add_member/remove_member` (ignore an unknown room,
  a full room, or a duplicate/non-member — the room stays valid);
  `dispatch_room_frame` routes them; `LocalRoomSource.addMemberToRoom`
  (refuses full/duplicate) and `removeMemberFromRoom` (deletes a room that drops
  below two members); controller `addRoomMember`/`removeRoomMember`. +1 executor,
  +2 host, +2 app-source tests; app 231, host 82 green.
- **Member-edit UI (§16.1)** — DONE. `RoomMembersSheet` lists the room's members
  (Remove, disabled at two) and the roster agents not in it (Add, disabled at
  six); a "Manage members" item in `RoomListView`'s row menu opens it; the shell
  wires add/remove to `LocalRoomSource` + the host and reopens the sheet on each
  change (or stops if a removal dropped the room below two and deleted it). +7
  sheet, +1 list tests; app 238 green.

- **Fix: agent-delete now syncs surviving rooms to the host** — the earlier
  agent-delete cascade told the host to forget rooms that fell below two members,
  but a room that *survived* (lost one member, kept ≥2) had the member removed
  only in the app's `LocalRoomSource` — the host still held the phantom member.
  `_deleteAgent` now captures the rooms the agent was in before the cascade and
  syncs each: a deleted room -> `deleteRoom`, a survivor -> `removeRoomMember`.
  +1 shell test driving the real roster-delete path; app 239 green.

- **Members-sheet remove: defensive host-delete + test** — audited the
  member-remove path for the same sync class as the agent-delete fix. Via the
  sheet a removal can only *shrink* a room, not delete it (Remove is disabled at
  two members), so the survivor path (host told `removeRoomMember`) was already
  correct — now covered by a test that drives the sheet. Added a defensive
  branch anyway: if `removeMemberFromRoom` ever deletes the room (guard changed,
  or another caller), the host is told `deleteRoom`, not left with a stranded
  one-member room — matching the agent-delete cascade. app 240 green.

- **Room resilience: reconnect banner (§16.1, mobile)** — an open room page is
  bound to the controller's inbound stream it had at open time. On a reconnect
  (a changing mobile network) the transport is rebuilt and that stream closes,
  so the room would silently receive nothing. `RoomThreadPage` now listens for
  the stream's `onDone` and shows "Connection changed. Reopen the room to
  continue." instead of hanging on a dead room — the user knows to reopen, which
  rebinds to the live socket. +1 test; app 241 green. (A fuller auto-rebind is
  possible but needs the page to observe controller swaps; the honest banner is
  the safe minimal fix.)

- **Host reconciles room membership on re-open (§16.1)** — closes an offline-edit
  sync gap for free. The app re-sends `room_create` whenever a room is opened
  (idempotent), but the old handler only *skipped* an existing room, so a
  membership change or rename made while the host was offline never reached it.
  `RoomService.handle_room_create` is now create-*or-reconcile*: an existing room
  has its name updated, members in the payload but not on the host added, and
  members on the host but not in the payload removed — the app is the authority,
  and the next open brings the host back in step. No new frames, no app change
  (the open-time re-sync already carries the current membership). +2 host tests;
  host 84 green.

- **Offline room-delete flushes to the host on connect (§16.1)** — the last
  room-sync gap. Create/rename/member edits made offline are repaired by the
  reconcile on the next open, but a *deleted* room has no later open, so the host
  was left holding an orphan. The shell now routes every host delete through
  `_hostDeleteRoom`: sent if the socket is up, else queued in
  `_pendingHostDeletes` and flushed the moment a transport arrives (in
  `_onController`). +1 shell test that deletes while the controller's future is
  unresolved, then completes it and asserts the delete flushed; app 244 green.
  So the app→host room sync is now complete: every offline op (create, rename,
  member edit, delete) reaches the host once it reconnects.

### Verified green baseline (2026-08-22, full cross-package run)

Re-run after the whole room build-out and the shell's ValueNotifier refactor
(auto-rebind), to catch any cross-package regression. All green:
crypto 65 · agent 647 · executor 48 · manager 171 · host 82 · sandbox 58 ·
app 243 (+3 skipped) — 1314 tests. Working tree clean. No regressions.

**Group rooms are complete on every layer that does not need live multi-agent
transport:** model → store → session → runner → driver → binding → relay frames
(create/task/rename/delete/history + turn/done) → executor routing → host
RoomService wiring → app (list, create, open, compose, stream, history, member
strip, delete, rename) → cross-machine handles → @all → per-agent routines →
persistence. Everything below the live transport is built and tested.

### Gates that STILL need the user (not auto-run)

**Runbook for the one remaining room step: `docs/ROOMS_GOING_LIVE.md`** — a
turnkey spec for making rooms drive real members (register per-member
`TaskSender`s in the host's `RoomBinding`; needs a multi-agent host — one executor
per member, not the serving one — plus the prod relay). All the pieces it wires
already exist and are tested; only the credit-spending / prod parts are gated.

- Prod `relay-crossreplica` deploy on the chat server — it can take chat down.
  (Note: the chat-side `cowork_peers.py` fix already shipped there as `d0732c1`,
  verified live 2026-08-20; this gate is about pointing CoWork at the prod relay,
  not the fix itself.)
- Any real-credit task run.
- The by-hand release-client pairing pass (release build has burned us twice).
