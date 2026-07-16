# CoWork — Execution Plan

**How to run this:** start a session and say *"führe den CoWork-Plan aus mit
vielen Subagenten"*. The agent reads this file, picks the first milestone whose
box is unchecked, and dispatches the subagents listed under it.

**One milestone per session.** Each ends with a green `flutter test`, a clean
CodeRabbit, and a commit. Do not start the next milestone in the same session —
the review step is the point, not a formality.

**What CoWork is** (from `docs/COWORK_BUILD_PLAN.md`, which stays the
architectural reference — this file is only the execution order): a personal
agent the user drives *from their phone* while it runs *on their own laptop*
with real filesystem/CLI access. The laptop runs a tray-resident daemon that IS
the agent — it runs chuk_chat's existing tool loop headlessly. The phone is a
thin remote control. `api.chuk.chat` is a blind store-and-forward relay that
only ever sees signed, E2E-encrypted blobs.

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

6. **Approval binds to the public key, not the device id.** Approving a
   `device_id` alone would let an attacker re-register that id with a fresh
   `public_key` and inherit the approval. The desktop approves *keys*; an
   unknown key is an unknown device, full stop.

7. **What a hacked relay can and cannot do.** It cannot decrypt — it never has
   the account key. It cannot forge a frame — it cannot sign over a key the
   desktop locally trusts. It cannot grant itself access — approval never
   touches the server. It *can* deny service and observe metadata (which device
   ids talk, when, how much). That is the accepted boundary. If a milestone
   finds itself putting trust in something the server asserts, that is a design
   error: stop and re-plan.

---

## State of the world (verified 2026-07-17)

| Piece | Reality |
|---|---|
| `lib/platform_specific/cowork/cowork_surface.dart` | **64 lines.** An M0 "coming soon" placeholder. That is the entire client. |
| `lib/models/app_mode.dart` | 3 lines: `enum AppMode { chat, cowork }` |
| Mode switcher | Works — `cowork_mode_switcher.dart`, wired into both root wrappers |
| `kFeatureCoWork` | `platform_config.dart`, default **false**. `./run.sh` forces it **true**, so the switcher and the dead screen are visible while this gets built |
| `api_server/routers/cowork_relay.py` | **261 lines, written, and NOT MOUNTED.** `main.py` has no `include_router(cowork_relay_router)` — grep it and see. It is dead code on the server too. |
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

- **`relay-mount`** (server, `/home/user/git/api_server`) — mount the existing
  `cowork_relay.py`: `app.include_router(cowork_relay_router)` in `main.py`
  next to the other four. Read the router first and report what it already
  handles vs. what is stubbed, specifically: (a) any **pairing/approval/
  handshake** logic, which is now wrong and must be flagged rather than
  silently mounted; (b) the **executor presence map** — how presence registers,
  how disconnect is detected, and whether the phone can ask *"is my desktop
  online right now?"*, which is what gates CoWork being available at all;
  (c) whether it is a pure blind store-and-forward relay, and whether it can
  see or log any plaintext (a critical finding if so). Verify against a
  deployed `/health` `git_sha`; the backend must deploy before client code
  lands.
- **`envelope-crypto`** (parallel, client) — the frame format
  `{seq, ts, nonce, ciphertext, sig}`: AES-256-GCM with the account key
  (`encryption_service.dart`, reuse it) + **per-device Ed25519** signing.
  Per-device signing ships from M0 — it is the load-bearing security decision
  and `cryptography` is already a dep. Replay protection via `seq` + `ts`
  window. Verification takes the desktop's **locally** approved key set;
  unknown key → reject, empty set → reject everything. Default deny, with no
  convenience overload that skips the check. Pure Dart, fully unit-testable:
  this subagent's output is mostly tests.
- **`device-list-decision`** (parallel, blocked on `relay-mount`'s report) —
  settle whether a Supabase devices table is needed **at all**. With approval
  client-side, public keys travelling in-band inside the account-key-encrypted
  channel, and offline desktops unusable by definition, the relay presence map
  may already be the whole device list. Ship a table only if something
  genuinely needs durable server-side storage — name it, or drop the migration
  and save a prod schema change, an RLS surface, and a deploy-ordering risk.
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

## M1 — Headless agent daemon  ·  ~4–6 d  ·  [ ]

Goal: the laptop runs the tool loop with no UI, driven by relay frames.

- **`remote-agent-service`** — `lib/services/cowork/remote_agent_service.dart`:
  a headless while-loop that calls the **unchanged** `ToolCallHandler`. Read
  `desktop_send_logic.dart` and `streaming_message_handler.dart` first — they
  are the two existing loop drivers; this is a third, minus UI. Configurable
  `maxIterations`. Persist `ToolLoopSession` to `kv_cache` so a restart resumes.
- **`daemon-lifecycle`** (parallel) — start-hidden, `launch_at_startup`,
  single-instance guard, tray-resident. `system_tray_service_io.dart` exists
  and `kFeatureSystemTray` already gates it. **Note:** with the tray on,
  `window_close_service_io.dart:22` bails out, so closing the window minimises
  instead of quitting — that is the intended daemon behaviour, not a bug.
- **`progress-streaming`** (after `remote-agent-service`) — stream loop progress
  back through the relay as encrypted frames. Reuse the existing streaming
  machinery; do not invent a second protocol.

**Done when:** the phone dispatches a task, the laptop runs a real multi-round
tool loop headlessly, and progress streams back. **Skills must work end-to-end
here for free** — if they do not, the loop was forked. That is the M1
acceptance test.

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

- **The relay is written but unmounted.** Anything that assumes M0 infra is
  live is wrong until M0 ships.
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
