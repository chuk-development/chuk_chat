# CoWork — Execution Plan

**How to run this:** start a session and say *"führe den CoWork-Plan aus mit
vielen Subagenten"*. The agent reads this file, picks the first milestone whose
box is unchecked, and dispatches the subagents listed under it.

**One milestone per session.** Each ends with a green `flutter test`, a clean
CodeRabbit, and a commit. Do not start the next milestone in the same session —
the review step is the point, not a formality.

**What CoWork is** (corrected 2026-07-17 by the product owner — this supersedes
`docs/COWORK_BUILD_PLAN.md` wherever they disagree; that file stays the
reference for the threat model and decisions, not for this shape):

The desktop runs **the normal chuk_chat app**, holding its normal chat
WebSocket to `api.chuk.chat` exactly as today. **In addition** it opens a
**second WebSocket** that mirrors the session to the phone. The phone is a
**mirror plus an input**: it watches the desktop's session and can inject
messages into it. The relay is blind — it only ever carries signed,
E2E-encrypted blobs, and it stores nothing.

**The desktop runs with its window open, or tray-resident and invisible, and
the two must behave identically.** What is *not* optional is that **the program
is running on the laptop at all** — if nothing runs there, CoWork is
unavailable, full stop. The tool loop runs where it always ran: inside the app,
in both cases.

**"Invisible" means tray-resident, NOT a UI-less build** — the distinction is
worth money:

- **Tray icon, app running, nothing visible: already built and free.**
  `system_tray_service_io.dart` exists, `kFeatureSystemTray` gates it, and
  `window_close_service_io.dart:22` deliberately bails out when the tray is on
  so that closing the window minimises instead of quitting. The Dart isolate
  keeps running either way: the WebSocket and the tool loop are async Dart and
  are **not tied to rendering**, so a hidden window may stop pumping frames
  while timers, futures and sockets carry on untouched.
- **A truly headless, UI-less entrypoint: out of scope.** It is real work and
  buys nothing the line above does not already give.

**This is only free as long as the mirror and the queue read the session state,
not widgets.** Touch `BuildContext` or the widget tree and "minimised" becomes
a special case — at which point the app is forced to stay visible. The state
discipline above is not purism; it is what makes the tray cost nothing.

**What that forces — read this before writing the mirror.** "Mirror what the
chat UI displays" and "works headless" are in direct tension: **in headless
mode there is no UI displaying anything.** A mirror that scrapes rendered
widget state cannot work in the mode that matters most.

So the mirrored source of truth is the **session / message state model**, not
the widget tree. The desktop UI renders *from* that state; the mirror
serialises *the same* state. One source, two consumers. Headless then needs no
special case at all — the state is there, nothing renders it locally. Any
design where the UI path and the mirror path each compute "what the user sees"
is a fork with two answers, and it will drift. If the mirror ever needs the UI
to be open, that is the design error: stop and re-plan.

---

## The connection model (decided 2026-07-17 — supersedes "pairing")

**There is no pairing.** No QR code, no pairing code, no bearer token, no
scan-to-connect. An earlier draft of this plan had all of that; it was a
misreading and is dead. Do not resurrect it.

The model is:

1. **The account login is the authentication.** A user signs into chuk_chat on
   their desktop and on their phone, same account. Each device self-registers a
   row in `cowork_devices` on login, publishing its Ed25519 public key.
2. **Devices just appear in Settings.** The phone lists the user's devices and
   picks one. Nothing is exchanged, nothing is scanned.
3. **The connection is implicitly live** whenever both apps are open. Phone app
   closes → connection closes. Phone app reopens → it reconnects. **Desktop app
   closed → CoWork mode is not available on the phone at all**, and the UI must
   say so rather than hanging. Presence gates the whole feature; it is not a
   nicety.
4. **One-time desktop approval is the security boundary, and it is
   CLIENT-SIDE ONLY.** An unknown device can drive nothing. The desktop owner
   approves it once, in the desktop's own Settings. **Default deny**, always —
   never timeout-to-allow, never unknown-state-to-allow. Revocable at any time.

   *Why it exists:* without it a stolen account password alone lets an attacker
   run code on the victim's laptop. With it, the attacker also needs physical
   access to an already-approved desktop.

5. **The backend has no say in approval whatsoever.** It does not store it,
   manage it, or see it. There is no `approved` column, anywhere. The desktop
   keeps its own set of approved Ed25519 public keys in local storage and
   verifies every incoming frame against it. This is deliberately stronger than
   a server-side flag the desktop double-checks: **there is no flag for a
   compromised backend to flip**, so the attack is eliminated rather than
   mitigated. The server provides the WebSocket and presence. Nothing else.

   **Server-side approval was never even possible** (verified 2026-07-17, and
   the reason to never revisit this): **RLS authenticates the account, not the
   device.** Every device of one user carries a JWT with the same `auth.uid()`,
   so Postgres cannot tell the desktop from the phone. Any `status` column
   meant to gate the phone would have been writable to `'approved'` **by that
   very phone**. Client-side approval does not merely shrink that attack
   surface — it replaces a control that could not have worked.

6. **Approval binds to the public key, not the device id.** Approving a
   `device_id` alone would let an attacker re-register that id with a fresh
   `public_key` and inherit the approval. The desktop approves *keys*; an
   unknown key is an unknown device, full stop.

7. **What a hacked relay can and cannot do.** It cannot decrypt — it never has
   the account key. It cannot forge or inject a frame — an altered or injected
   frame fails the AES-256-GCM auth tag and arrives as nonsense, so it is
   rejected; it also cannot sign over a key the desktop locally trusts. It
   cannot grant itself access — approval never touches the server. It *can*
   deny service and observe routing metadata. That is the accepted boundary. If
   a milestone finds itself putting trust in something the server asserts, that
   is a design error: stop and re-plan.

8. **The two layers stop two different attackers — do not collapse them.**
   The account key is **per account, not per device**: every device the user is
   logged into holds it. So E2E encryption stops *the server* but cannot stop
   *another device of the same account*, which can encrypt perfectly validly.
   That is what per-device Ed25519 + local approval is for. E2E stops the
   relay; the signature stops the un-approved device. Anyone who argues one
   layer is redundant has not noticed they defend against different attackers.

9. **The routing envelope cannot be E2E, and that is the honest limit.** The
   relay must read `device_id` in cleartext or it cannot route — unavoidable.
   Everything else must be encrypted. **Known gap (2026-07-17):** the presence
   map also holds `device_name` in cleartext, i.e. the user's own label
   ("Dietrich's MacBook"). Routing does not need it. Under "we are only a
   relay, we see nothing", the label belongs inside the encrypted payload and
   `device_id` must stay an opaque random id that says nothing about the
   machine. M0 fixes this rather than shipping it.

---

## State of the world (verified 2026-07-17)

| Piece | Reality |
|---|---|
| `lib/platform_specific/cowork/cowork_surface.dart` | **64 lines.** An M0 "coming soon" placeholder. That is the entire client. |
| `lib/models/app_mode.dart` | 3 lines: `enum AppMode { chat, cowork }` |
| Mode switcher | Works — `cowork_mode_switcher.dart`, wired into both root wrappers |
| `kFeatureCoWork` | `platform_config.dart`, default **false**. `./run.sh` forces it **true**, so the switcher and the dead screen are visible while this gets built |
| `api_server/routers/cowork_relay.py` | **LIVE as of `625d53a`** (verified on `/health`, 2026-07-17). Earlier drafts of this table said "written and NOT MOUNTED, `main.py` has no `include_router(cowork_relay_router)`" — that was **wrong**: the file has **no `APIRouter` at all**. It is a registry/forwarding helper imported by `routers/multiplex.py`, whose `multiplex_router` was already mounted. It was dead only because the `multiplex.py` wiring sat **uncommitted**. Committing and deploying *was* the mount. |
| Devices table | **Does not exist, and may never need to.** See M0 — with approval client-side and offline desktops unusable by definition, the relay's presence map may be the entire device list. |
| `multiplex_connection.dart`, `encryption_service.dart` | Present, reusable |
| `pretty_qr_code` | In pubspec. **Not needed for CoWork** — there is no QR pairing. Leave it alone; other features may use it. |
| `mobile_scanner` | Not in pubspec, and **not needed**. It was only there to scan a pairing QR. Pairing is dead. |

**The invariant that makes this affordable:** the tool loop is never
re-implemented. `ToolCallHandler`, `ToolPromptBuilder`, `ToolEnforcer`,
`ToolExecutor` and `tool_registry` run **unchanged**, headlessly. Anything
landing in the shared loop reaches CoWork for free — Agent Skills already do.
If a milestone finds itself forking the loop, that is a design error: stop and
re-plan.

---

## Non-negotiable rules

These are paid for in this repo's blood. Put them in every subagent prompt.

1. **`flutter test` must pass. Baseline is 950.** A drop is a regression you
   caused. `flutter analyze` must be clean — the one pre-existing
   `unintended_html_in_doc_comment` at `notes_tools.dart:665` is not yours.
2. **CodeRabbit before every commit**, `coderabbit review --plain --type uncommitted`
   (it takes ~10 min and sometimes times out — re-run it). Do not push with
   open findings. It has caught 5 **critical** cross-user data leaks in this
   repo that passed a full green test suite.
3. **NEVER `dart format <directory>`.** The repo is on an older formatter
   style. `dart format lib/platform_specific/chat/` produced **530 churn lines
   on a 44-line change** and made CodeRabbit report pre-existing code as new
   findings. Format only files you edited, then `git diff --numstat <file>` —
   deletions you did not make are churn: `git checkout --` and re-apply by hand.
4. **Review every subagent result. Do not trust the report.** In this repo a
   subagent reported "17 tests, I proved they're load-bearing" for a fix that
   had *moved* the bug rather than fixed it; all 17 passed against broken code.
   Re-run the proof yourself: break the fix, watch the tests fail, restore.
5. **Column before code.** A Supabase table must exist in production *before*
   client code that queries it lands on master — push auto-deploys web.
   `supabase db push` is forbidden (history mismatch); apply SQL via the
   Management API. See `.claude` project memory `project_supabase_migrations`.
   New RLS policies use `(select auth.uid())`, never bare `auth.uid()`.
6. **Keep pubspec constraint floors low.** The Android CI job pins Flutter
   3.38.7 (Dart 3.10.7) while every other job pins 3.41.4, and it *ignores
   `pubspec.lock` and re-resolves*. Raising a floor to a Dart-3.11-only version
   makes that job unsolvable. See the header block in `pubspec.yaml`.
7. **Privacy logging:** wrap every `debugPrint` in `if (kDebugMode)`, never log
   user content — counts, lengths, ids and status codes only.

**Subagent isolation:** worktrees (`isolation: "worktree"`) work fine. The trap
is your own shell: `cd` persists between Bash calls, so after entering a
worktree every relative path silently reads the wrong copy. Use absolute paths,
or `cd` back immediately.

---

## M0 — Relay + device presence + local approval  ·  ~2–3 d  ·  [ ]

Goal: phone and laptop can see each other and exchange a signed, encrypted
frame. Nothing else works without this.

**Subagents (parallel where marked):**

- ~~**`relay-mount`**~~ — **DONE, `625d53a`, live on `api.chuk.chat`**
  (independently verified: `/health` `git_sha` matches local HEAD; `/v2/ws`
  answers a real handshake). No `include_router` was needed — see the state
  table. Shipped two call-time bugs found by CodeRabbit on the way: the relay
  bypassed the documented 1 MB cap for 20 MB and fanned it out N× unmetered
  (**major**), and an uppercase `target_device_id` missed the canonical key,
  producing a **false "laptop offline"**. 40 tests pass.

  **What it already does:** `role` handshake (`controller`/`executor`) on the
  existing Supabase-JWT `auth` frame; uuid `device_id` canonicalisation;
  presence map `user_id → device_id → ExecutorEntry`; `executor_status`
  broadcast on register/close plus a snapshot to new controllers;
  reconnect-safe unregister; verbatim opaque forwarding; `cowork_error`
  frames; user-scoped routing (cross-account is impossible — verified).
  "Store-and-forward" was a **misnomer**: it stores nothing.

- ~~**`relay-split`** (own process)~~ — **REVERSED by the product owner
  2026-07-17, after it shipped as `b5d012b`.** Decision: **one API server, one
  codebase, one domain, one deployment, one process — CoWork is just a new
  endpoint.** No second container. Separation is achieved *inside* the process,
  not by splitting it.

  **What survives and must be reused:** the split's refactor was not wasted.
  `routers/cowork_ws.py` owns the socket, `ws_auth.py` is the one shared trust
  boundary both paths import, and `cowork_relay.py` stayed pure. Keep all of
  that; only the second entrypoint and `Dockerfile.relay` go.

  **What in-process actually buys, honestly:** an exception in a WS handler
  does not kill FastAPI — that isolation is already real. The one credible OOM
  source (the 20 MB fan-out) is capped at 1 MB. What stays shared and cannot be
  isolated in-process: a blocking call stalls the event loop for every chat
  request, and true OOM takes everything down. Mitigated, not eliminated.
  Accepted.

- **`relay-crossreplica`** (server, next — the blocker that forced the above
  decision) — **the relay is broken in production right now, and robust code
  cannot fix it.**

  **Verified in Dokploy, not assumed:** the chat API runs
  `modeSwarm.Replicated.Replicas: 2`, with `updateConfigSwarm.Order:
  "start-first"` (which deliberately runs two instances at once during a
  deploy). The relay's presence map is in memory, so it is correct only at
  exactly 1 replica. Riding in the same process, it inherits 2 — the phone
  lands on replica A, the laptop on replica B, and they **never see each
  other**. Roughly half of all controller/executor pairs would never connect.
  No test caught it because every test runs in one process. Chat needs ≥2 for
  availability; an in-RAM presence map needs exactly 1. One process means one
  replica count — that is arithmetic, not a code-quality problem.

  **Decided fix: peer-to-peer between replicas over Swarm task DNS. NO
  database.** Replica A forwards the frame straight to replica B on the overlay
  network. Presence stays in memory, where it belongs.

  **This plan first prescribed Postgres `LISTEN`/`NOTIFY`. That was wrong**, and
  the correction is recorded because the reasoning generalises:

  - **The direct Postgres connection is unreachable from the code.**
    `db.xooposctxswumvgtyqlg.supabase.co` has **no A record — AAAA only**
    (verified). The host has IPv6; the Docker overlay does not
    (`/etc/docker/daemon.json` lacks `"ipv6": true`). Enabling it means a
    daemon restart bouncing all **37 containers** on `dokploy-network`.
  - **The plan's own trap #1 was backwards.** Transaction mode (6543) does
    break `LISTEN`/`NOTIFY`, but **session mode (5432 on
    `*.pooler.supabase.com`) supports it and is reachable over IPv4**. "Use the
    direct connection, not the pooler" was exactly inverted.
  - **The killer argument, which outranks the plumbing:** a DB presence row
    needs a **heartbeat** to expire it — smuggling back in precisely the
    app-level heartbeat that was refused above after *measuring* uvicorn's
    transport keepalive. Both DB options reintroduce it. Peer-to-peer makes the
    stale-presence problem **disappear** instead of solving it: no rows,
    nothing to go stale, no TTL, no reaper — a dead replica's presence
    evaporates with its heap. **A better class of solution, not a cheaper one.**
    Do not "improve" this into a database.

  **Verified working end-to-end** (not merely resolved): `tasks.chukchat-api-ssqfsl`
  → `['10.0.1.92', '10.0.1.93']`, one per replica; the VIP →
  `['10.0.1.11']`; `socket.gethostname()` gives the task its own ip so
  self-exclusion works; and replica A reached replica B's `/health` at
  `10.0.1.92:8000` → `200`. It also keeps "the relay stores nothing" literally
  true, needs no `asyncpg`, no DB credential, and puts no DB hop on the hot
  path — the 8 KB `NOTIFY` limit becomes irrelevant.

  **The one cost:** a shared **peer token** env var. `dokploy-network` is shared
  with 37 containers and Traefik routes `api.chuk.chat → :8000`, so the internal
  peer endpoint needs a shared secret with constant-time compare (plus a
  `tasks.` source-ip check as defence-in-depth, not the primary control). It is
  self-generated, grants no DB access, is freely rotatable, and if it leaks the
  E2E/Ed25519 layers still hold — an injected frame fails the GCM tag (§7).
  Incomparably smaller than a Postgres credential.

  **Why this is not optional:** today the relay is not a separate component at
  all — it is a *frame type on the chat socket*. `/v2/ws` (`multiplex.py:1271`)
  is one multiplexed connection carrying `chat`, `tool`, `cancel` **and**
  `cowork_relay`. One process, one event loop, one heap. The 20 MB fan-out bug
  CodeRabbit caught at `625d53a` would have OOM'd that process and **taken chat
  down for every user** — the failure mode is demonstrated, not hypothetical.
  A blocking relay call stalls every chat request on the same loop.

  **Why it is cheap here:** `cowork_relay.py` imports `uuid`, `dataclasses`,
  `typing` — no DB, no Supabase client, no shared state. It is pure in-memory
  pubsub behind a JWT check. Almost all of the work is wiring.

  **A sub-app mount does not count.** Same process, same loop, same heap — it
  buys nothing. Separate process or it is theatre.

  Known costs and traps, in order of how much they will hurt:
  1. **The relay must validate the Supabase JWT itself.** Today `multiplex.py`
     does the auth before the relay ever sees a frame. This is the one real
     coupling — the new service needs the JWT secret/JWKS in its own env. Get
     this wrong and the relay is an open door.
  2. **Both clients open a second socket.** Phone and laptop each connect to
     chat *and* relay. Accepted cost: extra battery and a second auth, bought
     with a CoWork lifecycle that is independent of chat — which matches the
     product model ("phone app closed → connection closed") rather than fighting
     it.
  3. **The relay stays at 1 replica, and that must be enforced, not assumed.**
     Its presence map is in-memory; at >1 replica a controller and its executor
     land on different instances and simply never see each other. Splitting it
     out is what *lets* chat scale without dragging this constraint along.
     Document it at the deployment, not just in code. (Note: the deploy is
     Swarm with a rolling update — an old replica drains for a while and will
     briefly serve the previous `git_sha`. Sample `/health` more than once
     before concluding a deploy failed.)

  **The seams, mapped at `5338d87`** — `cowork_relay.py` itself is still clean
  (imports only `logging`, `uuid`, `dataclasses`, `typing`; no DB, no globals,
  no `multiplex` internals), so the work is these hooks in `multiplex.py`:
  the docstring contract (~9–48); the imports (94–105); connection state
  `role`/`executor_entry`/`is_controller` (1309–1314); the handshake `role` +
  `device_id` parse (1446–1470); registration + snapshot (1479–1513); the
  `handle_cowork_presence_frame` hook (~1557); the `cowork_relay` branch and
  its 1 MB cap; and the `finally` unregister/broadcast.

  **`routers/ws_control.py` is shared on purpose — do not "clean it up".**
  `ping`/`pong` is a property of *the socket*, not of chat or CoWork, so both
  processes import it and neither imports the other to answer a ping. Its
  liveness does not depend on chat keeping the socket warm: uvicorn's PING is
  transport-level and the client's timer is unconditional, so it survives the
  split unchanged.

- ~~**`relay-hardening`**~~ — **DONE, `5338d87`, live** (verified on `/health`).
  Tests **40 → 57**.
  1. **`device_name` cleartext leak — removed.** Gone from the wire contract,
     `ExecutorEntry`, `executor_status_frame`, `register_executor`, the
     handshake parse and both docstrings. `ExecutorEntry` is now
     `{device_id, send}` — the relay cannot leak what it never holds.
  2. **`device_id` opacity — uuid4 enforced.** Rejects v1/v3/v5/nil through the
     existing invalid-handshake path. **Honest limit, recorded in the code:**
     it reads the version nibble, so it stops *our own client* accidentally
     calling `uuid.uuid1()` and publishing hardware identity; it cannot stop a
     device stamping v4 over a MAC — which is not the threat model.
     Same-account `device_id` squatting is still possible (silently replaces
     the socket): self-inflicted, own account only, accepted.
  3. **Heartbeat — NOT built, and the reason matters more than the fix.**
     The premise in this plan was **wrong**, verified empirically rather than
     by reading code: uvicorn 0.47 resolves `ws="auto"` to the websockets impl
     with **`ws_ping_interval=20` / `ws_ping_timeout=20`**, stock defaults that
     neither `main.py` nor the Dockerfile CMD overrides. A silent peer's
     `receive()` raises after a **measured 50.0 s** with `code=1006`, running
     the existing `finally` → `unregister_executor` → `executor_status
     online=false`. **A closed lid does not strand an executor as online.**
     An app-level timer would have to beat ~50 s to change any outcome, and
     cannot safely: the client pings every 25 s, so any threshold under ~50 s
     evicts a live phone that missed one ping on a flaky network — a regression
     at a useful threshold, dead code at a safe one. The ~50 s is irreducible;
     a silent TCP peer cannot be told from an idle one without a timeout.

     **The trap to remember: reading application code cannot reveal
     transport-level keepalive.** Two passes over `cowork_relay.py` "confirmed"
     a missing heartbeat that the server had all along.

     What *was* real: the client pings on an unconditional 25 s timer, and the
     server answered **`{"code":"invalid_req_id"}`** — ping carries no `req_id`
     and fell past the `req_id` gate. Every client traded an error frame every
     25 s for its whole connection. Now answered with `{"type":"pong"}`, and
     the client's long-vestigial `pong` branch
     (`multiplex_connection.dart:290`) finally means something.
  4. **On-demand presence — done.** Controllers always get a `cowork_presence`
     snapshot at connect, **empty list included** (an empty loop previously
     sent literally nothing, so "none online" and "snapshot pending" were
     indistinguishable) and can re-query any time. `executor_status` stays the
     single-device delta.
- **`envelope-crypto`** (parallel, client) — the frame format
  `{seq, ts, nonce, ciphertext, sig}`: AES-256-GCM with the account key
  (`encryption_service.dart`, reuse it) + **per-device Ed25519** signing.
  Per-device signing ships from M0 — it is the load-bearing security decision
  and `cryptography` is already a dep. Replay protection via `seq` + `ts`
  window. Verification takes the desktop's **locally** approved key set;
  unknown key → reject, empty set → reject everything. Default deny, with no
  convenience overload that skips the check. Pure Dart, fully unit-testable:
  this subagent's output is mostly tests.
- ~~**`device-list-decision`**~~ — **DONE, 2026-07-17: there is no table, and
  M0 ships none.** Independently verified, not merely reported:
  `cowork_relay.py` imports only `uuid`, `dataclasses`, `typing` — no DB
  client, no persistence; `self._executors: Dict[str, Dict[str, ExecutorEntry]]`
  is the entire state, and it already carries `device_id` + `device_name`
  in-band from the handshake. So the presence map *is* the device list.
  `platform` rides the same handshake frame. Public keys travel in-band inside
  the account-key-encrypted channel the server has no key for — and trust comes
  from the desktop's local approval of a key, never from transport.
  `last_seen_at` would be the highest-write column in the schema, storing a
  value stale the moment it is read, to describe offline devices that are
  un-drivable by definition; the socket alone can express "the socket is open",
  and a phone-side cache covers "last connected 3 days ago". A `paired_devices`
  table applied under the old brief was **dropped, 0 rows lost**; prod re-checked
  clean for anything matching `%device%`/`%pair%` — no table, no policy, no
  leftover function.

  **The one thing that will genuinely need durable storage is M3's push
  tokens** — waking a device that is *by definition not connected* is the one
  fact an in-memory presence map provably cannot hold. That is one `fcm_token`
  column, three milestones out. Do not pre-build it here.
- **`approval-ui`** (after `envelope-crypto`) — desktop Settings lists the
  user's devices and approves/revokes them; approved keys persist in **local**
  storage on the desktop, never server-side. Phone Settings shows its devices
  and their online state, and says plainly that CoWork is unavailable when the
  desktop is closed rather than hanging. **Default deny throughout.**

**Done when:** two devices of one account see each other, an unapproved device
is refused, an approved one exchanges a signed encrypted frame through the
relay, and the relay logs prove it never saw plaintext. Envelope tests:
round-trip, tamper → reject, replay → reject, stale ts → reject, wrong-device
sig → reject, unapproved key → reject, empty approval set → reject all.

---

## M1 — Session mirror + message queue  ·  ~4–6 d  ·  [ ]

Goal: the phone sees the desktop's live chat session and can put messages into
it — identically whether the desktop window is open or tray-resident/headless.

- **`session-mirror`** — the second WebSocket: serialise the **session state
  model** and mirror it to the phone as encrypted frames. Read
  `streaming_message_handler.dart` and `desktop_send_logic.dart` first. Reuse
  the existing streaming machinery — **do not invent a second protocol**, and
  do not fork the tool loop.

  **This is not a screen mirror.** The phone renders the same session in its
  own mobile UI; the repo already has two renderers over one chat state
  (`chat_ui_desktop.dart`, `chat_ui_mobile.dart`), and the mirror simply feeds
  a third consumer. Mirroring *rendered* state would both look wrong on the
  phone and break outright in headless mode, where nothing renders. Mirror the
  state; let each end draw it.
- **`tray-lifecycle`** (parallel, small) — tray-resident mode: start-hidden,
  `launch_at_startup`, single-instance guard. Most of this exists —
  `system_tray_service_io.dart` (10.5 KB) is written, `kFeatureSystemTray`
  gates it, and `window_close_service_io.dart:22` already bails out so that
  closing the window minimises rather than quits. Verify and finish it; do not
  rewrite it, and **do not build a UI-less entrypoint** (see above — out of
  scope, no gain). **Visible and tray must be the same product**: if anything
  in the mirror or the queue only works with a window open, that is the bug.
- **`message-queue`** (the load-bearing one — see the section below) — queued
  message injection from **both** phone and desktop, delivered between tool-loop
  rounds, with force-send, and **never silently dropped**.

**Done when:** the phone mirrors a live desktop session, a message queued from
the phone lands in the loop at the next round boundary, force-send lands
immediately, and a queued message survives a reconnect — **and all of it works
with the desktop window closed to the tray**, which is the acceptance test that
catches a UI-coupled mirror. **Skills must work end-to-end here for free** — if
they do not, the loop was forked.

---

## The message queue (product owner, 2026-07-17)

Messages can be composed on **the phone or the desktop** while the AI is
working. They do not interrupt a tool call. When the model finishes its current
tool call(s), the queued message is injected **between rounds** of the tool
loop, as further instruction. The user can also **force** a message to be sent
immediately instead of waiting for the boundary.

**The requirement that outranks the rest: a queued message must ALWAYS actually
be delivered.** The product owner named the failure mode explicitly, from
Claude Code (the tool this plan was written with): messages sent while the agent
is working can silently vanish. That is the thing this must not do. Design
consequences:

- **Never drop, never silently.** Not on reconnect, not on a round that ends
  early, not on an error path, not when the loop finishes before the boundary
  arrives. If a message cannot be delivered, that must be *visible* — an
  explicit state in the UI, never a `debugPrint`-and-return. (See `.claude`
  memory `feedback_silent_failure`: this repo has a standing rule against
  swallowing failures in a catch block.)
- **Ack, don't hope.** Queued → sent → accepted-by-the-loop is a state machine
  the sender can observe, not fire-and-forget. The user must be able to tell
  "it's waiting for the round to end" from "it's gone".
- **Survive a reconnect.** The phone's socket dies on app close by design, and
  the user's network changes (see `.claude` memory `feedback_user_mobile_use` —
  mobile use with changing networks is a real requirement here, not
  theoretical). A message queued just before a drop must still land.
- **Both directions.** The desktop can queue too — it is not a phone-only
  feature.
- **Ordering.** Two messages queued in order arrive in order. Force-send is the
  deliberate exception and must be obvious in the UI, not a silent queue-jump.

**Where it hooks in:** the round boundary of the existing tool loop
(`desktop_send_logic.dart`, `streaming_message_handler.dart`). **Do not fork the
loop to get this** — an injection point is a hook, not a second driver. If it
starts looking like a fork, stop and re-plan.

---

## M2 — Laptop-native tools + approval gate  ·  ~4–6 d  ·  [ ]

Goal: the agent touches the real machine, and cannot do so unsupervised.

- **`laptop-system-tools`** — `run_command` / `read_file` / `write_file` /
  `list_directory` / `process_exec` via `Process.start`. Registering a tool
  takes **four** edits, not three: `builtinTools`, `toolCategoryMap`,
  `_builtinExecutableToolNames` (`registerTool` throws `StateError` without
  it), **and `_nonFactualToolNames`** in `tool_call_handler.dart` — omitting
  the last makes every turn using the tool fire a spurious `[VERIFY]`
  fact-check round.
- **`policy-gate`** (parallel) — allow/deny/ask classifier, cwd jail,
  credential denylist. Phone approval round-trip with **timeout → deny**, never
  timeout → allow.
- **`shell-tags`** (after both) — `<shell>` / `<tasklist>` output tags. Model on
  the existing visual output tags in `tool_prompt_builder.dart`. **Consider a
  skill instead of always-injecting the schema** — that is what `<chart>` and
  `<weather>` do now, and it saved 1145 tok/round. But read
  `.claude` memory `project_agent_skills` first: a skill only pays when the
  load-rate is low, and it must never gate a reflex.

**Done when:** the phone can run a real command on the laptop, a dangerous one
is blocked by the gate, and an ambiguous one round-trips for approval and
denies on timeout.

---

## M3 — Push + cross-device + draft-then-gate  ·  ~4–6 d  ·  [ ]

- **`push-wake`** — FCM/APNs (`firebase_messaging` + `firebase-admin`, includes
  real Firebase project + APNs setup — this has ops work outside the repo, budget
  for it). Wake a backgrounded phone when the laptop needs approval.
- **`draft-then-gate`** (parallel) — irreversible actions (email, calendar,
  messages) are drafted and shown, never sent unprompted. The `<email>` tag
  already works this way — reuse the pattern.
- **`task-persistence`** (parallel) — task list synced via Supabase, model on
  `chat_storage_service`.

---

## M4 — OS sandbox  ·  ~1–2 w  ·  [ ]

- **`sandbox-backend-interface`** — a `SandboxBackend` interface; E2B (already
  wired) becomes Tier-3.
- **`sandbox-linux`** (parallel) — `bwrap` on Linux/WSL2.
- **`sandbox-macos`** (parallel) — `sandbox-exec` + `.sbpl`. A macOS box is on
  record at `ssh root@10.11.12.80`.
- **`sandbox-windows`** (parallel) — ask-only, and **disclose that it is
  ask-only**; do not imply containment that does not exist.
- **`worktree-workspace`** (after the interface) — git-worktree workspace +
  merge-back UX.

---

## Traps

- **A relay fault must never reach the chat API.** This is a product
  requirement, not a nice-to-have: if the CoWork part crashes, everything else
  keeps running. It is also why `relay-split` exists. Any change that puts
  relay code back on the chat process — "just for now", "it's only a small
  handler" — reintroduces the exact failure the split paid to remove. The 20 MB
  fan-out bug is the standing proof that in-process relay bugs kill chat.
- **Pairing is dead — do not resurrect it.** An earlier draft of this file
  specced QR pairing, `mobile_scanner`, a `paired_devices` table and a
  server-side approved flag. All of it was a misreading of the product. The
  account login authenticates; the desktop approves keys locally; the server
  only carries the WebSocket. If a subagent starts building a pairing exchange,
  it is working from a stale copy of this plan.
- **Never put approval on the server.** Not even as a "convenience mirror" the
  desktop double-checks. A flag that exists is a flag a compromised backend can
  flip; a flag that does not exist cannot be attacked. The desktop's local key
  set is the only authority.
- **A registered-but-broken tool is worse than an absent one** — the model
  reaches for it and the turn dies. This is why `FEATURE_SPOTIFY` /
  `FEATURE_WHOOP` are off: their backend routes were removed.
- **`FEATURE_PROJECTS` does not exist.** Nothing in `lib/` reads it, yet
  `build.sh`, `codemagic.yaml` and `AGENTS.md` still pass it. The real flag is
  `FEATURE_WORKSPACES` (default true). Do not copy that pattern.
- **Prompt redundancy is not code redundancy.** Do not "dedupe" prompt text
  because another copy exists — see `.claude` memory `project_agent_skills`,
  where exactly that was investigated and rejected: the copies were added
  deliberately, in the same commit, one with a regression test.
- **`resetServices()`-style hooks are not a guarantee.** Six sign-out paths
  exist and one bypasses `AuthService` entirely. Key per-user state by user id
  and re-check on access. See `.claude` memory
  `project_dead_logout_cache_reset`.
