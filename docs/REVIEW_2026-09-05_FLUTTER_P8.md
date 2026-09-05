# Review 2026-09-05 — Flutter side, pass P8 (bead cowork-4wd)

Reviewer: Opus 5 subagent (session cowork-f7). Read-only pass over the working
tree on branch `cowork`, with the uncommitted work of sessions a4, 9e, 47, 84,
b5, c6, 5c and f7 in place. No file under `app/` was changed; this document is
the only output.

## Scope

IN: everything under `app/lib` that is CoWork's own code.

OUT (not reviewed; a finding on one of these would be marked "upstream"):
`app/lib/third_party/**`, `app/lib/widgets/browser_view_page.dart`, and every
path listed in `tools/chat_ui_manifest.txt` (123 entries) — the byte-identical
imports from chuk_chat master. Note that the manifest contains
`lib/services/supabase_service.dart`, `lib/utils/theme_extensions.dart`,
`lib/widgets/anchored_menu.dart`, `lib/widgets/expressive_settings.dart`,
`services/chat_mode_service.dart`, `services/model_capabilities_service.dart`,
`platform_config.dart` and the whole chat-storage block
(`chat_storage_crud/sync/mutations/sidebar`, `chat_preload_service`,
`chat_sync_service`, `local_chat_cache_*`). `chat_storage_service.dart`,
`websocket_chat_service.dart`, `tool_call_handler.dart` and
`notification_service.dart` are NOT in the manifest and were reviewed.

No `flutter`, `dart`, `flutter test` or `flutter analyze` was run (one compiler
at a time on this machine). Everything below was read with `cat` / `sed` /
`grep` and is quoted from the tree.

Docs read first: `HANDOVER_2026-09-05_CHAT_STORAGE.md`, `_LOGOUT_2n1.md`,
`_MCP_cowork-47.md`, `_REPLAY_EVENTS_266.md`, `_TOOLCARDS_cowork-84.md`,
`_REASONING_TOOLFRAMES.md`, `_MOBILE.md`, `_SHELL_cowork-shell.md`,
`_SHELL_SETTINGS_cowork-5c.md`, `WIRE_CONTRACT.md`, `PRODUCT_PHILOSOPHY.md`.

## Status after the fix pass (session cowork-f7, 2026-09-05)

Fixed and tested: F1, F2, F3, F4, F5, F6, F7, F8, F9, F13, F14, F15. Open: F10,
F12 (services/mcp, cowork-47's files, LOW), F11 (ledger, cowork-84). Every
fix carries a test in the file named under its **Status** line; all touched
suites are green (loader 25, websocket_chat_service 18, relay_client 51,
thread_view 25, thread_view_notifications 3, cowork_notifications 7,
tool_card_parity 5, run_ledger 17, messenger_shell 21). Files edited by the
fixer: `services/cowork/cowork_replay_loader.dart`,
`services/websocket_chat_service.dart`, `services/cowork/cowork_relay_client.dart`,
`widgets/cowork_thread_view.dart`, `services/notifications/run_notifications.dart`,
`services/notifications/cowork_notifications.dart` (additive `runId`).

Side note for cowork-84: `services/cowork/cowork_run_ledger.dart` contains
four literal NUL bytes inside a doc comment (`"<sessionKey>\0<subagentId>"`,
around byte 8623); the analyzer accepts it, but `grep` treats the file as
binary. Write the separator as `\u0000` in the comment.

## Findings

| id | severity | file | one line | owner |
|---|---|---|---|---|
| F1 | HIGH | `app/lib/services/cowork/cowork_replay_loader.dart` | one global `_activeSession` + implicit drafts: a second replay folds thread A's rows into thread B and commits them as a full replace | 47 / 9e |
| F2 | HIGH | `app/lib/services/cowork/cowork_replay_loader.dart` | a delta replay whose local cache read comes back empty truncates the thread to the delta and still advances the cursor | 47 / a4 |
| F3 | HIGH | `app/lib/services/websocket_chat_service.dart` | `_isReplay` does not know `subagent` / `file` / `approval_request`, so replayed cards enter the live run and a replayed file is written to the blob store again | 47 / 9e |
| F4 | MEDIUM | `app/lib/services/cowork/cowork_relay_client.dart` | `_onSocketDone` never clears `_socket`, so the scheduler's `reconnectHost` always throws and cowork-2n1's wake-up adoption never runs | 9e / 47 |
| F5 | MEDIUM | `app/lib/services/cowork/cowork_relay_client.dart` | the `account_session_rotated` fallback provisions the host with `user_id: ""` | 47 / 9e |
| F6 | MEDIUM | `app/lib/widgets/cowork_thread_view.dart` | `_reconnect()` calls `setState` after an await with no `mounted` check — the auto-reconnect timer can hit a disposed state | 47 |
| F7 | MEDIUM | `app/lib/services/notifications/run_notifications.dart` | `consumeForSession` is once-per-launch per thread, so the second "answer ready" row of a session is never closed | c6 |
| F8 | MEDIUM | `app/lib/widgets/cowork_thread_view.dart`, `cowork_replay_loader.dart` | `clearAnswerReady` is never called, so every later loader notification cancels the thread's toast | c6 |
| F9 | MEDIUM | `app/lib/widgets/cowork_thread_view.dart` | a live `approval_request` prompts on whatever thread is on screen; the frame carries no session key | 9e |
| F10 | LOW | `app/lib/services/mcp/mcp_service.dart` | an `mcp_credentials` frame without `expires_at` erases the expiry the device knew | 47 |
| F11 | LOW | `app/lib/services/cowork/cowork_run_ledger.dart` | `recordTool` fills an open line that has a *different* call id when the names match | 84 |
| F12 | LOW | `app/lib/services/mcp/mcp_redirect_io.dart` | the loopback listener completes on the first request of any path, code or no code | 47 |
| F13 | LOW | `app/lib/services/cowork/cowork_replay_loader.dart` | the `user` case has no `replay` guard, against the file's own stated invariant | 47 |
| F14 | LOW | `app/lib/services/websocket_chat_service.dart`, `cowork_thread_view.dart` | two `run_ack` frames are sent for every live `done` | 47 / c6 |
| F15 | LOW | `app/lib/services/cowork/cowork_relay_client.dart` | doc drift: `CoworkRelayReasoning` still says nothing emits it on the real wire | b5 / 47 |

---

### F1 — HIGH — one `_activeSession` for every replay, and drafts made behind the caller's back

**Status: FIXED (f7).** `expect` no longer moves the active session while an answer is streaming; the `run_state` header (or, for a header-less host, the order of requests) decides which draft a frame folds into; a second request for the same thread queues behind the answer in flight. Tests: loader "two overlapping replay requests land in their own threads", "a second request for the same thread queues behind the answer in flight".

`app/lib/services/cowork/cowork_replay_loader.dart:169-173`, `:352-355`,
`:405-441`; `app/lib/widgets/cowork_thread_view.dart:329-368`;
`app/lib/pages/cowork_shell_state.dart:188-196`.

The loader routes every replayed frame through one mutable pointer:

```dart
_Draft _draftFor() {
  final key = _activeSession ?? CoworkRelayLink.instance.sessionKey.value;
  return _drafts[key] ??= _Draft(key);
}
```

`expect(sessionKey, afterId:)` sets `_activeSession` and installs a draft that
knows the `after_id` the request was made with. Every other path (`_draftFor`)
creates a draft with the default `afterId = 0`, and `_commit` reads
`honouredCursor` off that field:

```dart
final honouredCursor =
    draft.afterId > 0 && (draft.minMid == null || draft.minMid! > draft.afterId);
```

`afterId == 0` therefore means "full replay" and `_commit` **replaces** the
cached rows instead of appending.

The failing path is the very first pairing, no exotic input needed. In
`_onStateChanged` the view does, in this order:

```dart
final peer = state.peerDeviceId;
if (peer != null) widget.onPaired?.call(peer);   // shell: setState, threadKey 'default' -> 'host:<peer>'
...
_requestReplay();                                 // expect('default', afterId: cursor('default'))
```

`onPaired` runs `_roster.ensureHostAgent(peerDeviceId)` whose thread key is
`'host:$peerDeviceId'` (`agent_roster_source.dart:119-136`) and calls
`setState`, so the next frame gives the thread view a new `threadKey` and
`didUpdateWidget` fires a second `_requestReplay()` — `expect('host:<peer>')`,
which moves `_activeSession` while the host is still streaming the `default`
transcript. From that moment the `default` rows are folded into the
`host:<peer>` draft, and `default`'s history-end `done` commits them into the
`host:<peer>` thread (appended when that thread had a cursor, or replacing when
it did not). The cursor for `host:<peer>` is then advanced to `default`'s
highest `mid`, so the host's next delta for `host:<peer>` starts above rows the
app never received: the real thread is permanently short.

The same shape happens whenever the user picks another coworker while a replay
is still in flight, and a *second* replay of the same thread loses the first
draft outright (`expect` overwrites `_drafts[key]`) and then commits the
remainder of stream 1 into a fresh `afterId: 0` draft — a full replace with
half a thread.

Fix: make the session explicit instead of ambient.

1. Give `_Draft` the `afterId` it needs and key every fold by the session the
   frame belongs to. The cheapest correct version: keep a queue of expected
   sessions (`final _expected = Queue<String>()`), push in `expect`, and have
   `_draftFor()` use `_expected.isEmpty ? link.sessionKey.value : _expected.first`;
   `_commit` pops. A `run_state` frame already names its session and should set
   the head of the queue, so a host that answers out of order still lands right.
2. In `_commit`, refuse to write a draft that was never `expect`ed
   (`_drafts` entry created by `_draftFor`): treat it as a full replay of an
   unknown thread and drop it rather than replace a cache with it.
3. In `expect`, do not silently discard an in-flight draft for the same key —
   commit or drop it explicitly.

---

### F2 — HIGH — a delta replay truncates the thread when the local read comes back empty

**Status: FIXED (f7).** A delta whose local read comes back empty is treated as a cache miss: nothing is written, the cursor is forgotten (`invalidateCursor`) and `takeReplayWanted` tells the thread view to ask for the whole thread again (`_onLoaderChanged` → `_requestReplay`). Test: loader "a delta that finds no local rows forgets the cursor instead of truncating the thread".

`app/lib/services/cowork/cowork_replay_loader.dart:416-441` and `:444-455`.

```dart
var rows = draft.rows;
if (honouredCursor) {
  final existing = await _cachedRows(session);
  rows = <Map<String, String>>[...existing, ...draft.rows];
}
final saved = ChatStorageService.saveChat(...);
_advanceCursor(session, draft.maxMid);
```

```dart
Future<List<Map<String, String>>> _cachedRows(String session) async {
  final chat = await ChatStorageService.loadFullChat(session);
  final messages = chat?.messagesOrNull;
  if (messages == null) return const <Map<String, String>>[];
  ...
```

`ChatStorageService.loadFullChat` → `CoworkChatStore.loadThread`
(`app/lib/services/storage/cowork_chat_store.dart:201-211`) returns null on any
of: no signed-in user, a SQLite read that threw (the `catch` returns `existing`,
which is null), a cloud row that cannot be fetched because
`supabase/migrations/20260905000000_cowork_chats.sql` has not been run yet (the
handover says the user must run it once), or a memory entry that is only a
sidebar title (`isFullyLoaded == false` → `messagesOrNull == null`).

So: the app holds a thread with 200 rows, asks for a delta from `after_id`, the
host sends the 4 new rows, the local read fails for any of the reasons above,
and `_commit` writes **4 rows** over the thread and moves the cursor to the
newest `mid`. The 200 rows are gone from the cache, and the host will never
re-send them because the cursor is past them. The only recovery is the removal
watcher in `cowork_chat_store.dart:591-601`, which fires only when the sync
removes the chat from `chatsById` — not for a transient read failure.

Fix: an empty local read is a cache miss, not an empty thread. In `_commit`:

```dart
if (honouredCursor) {
  final existing = await _cachedRows(session);
  if (existing.isEmpty) {
    // We asked for a delta and have nothing to append it to. Do not write:
    // forget the cursor and ask again from zero.
    invalidateCursor(session);
    return;
  }
  rows = <Map<String, String>>[...existing, ...draft.rows];
}
```

(and let the thread view re-request a replay on the next `notifyListeners`, or
call `_requestReplay` from the loader's own listener).

---

### F3 — HIGH — replayed `subagent` / `file` / `approval_request` frames enter the live run

**Status: FIXED (f7).** `_isReplay` covers `CoworkRelaySubagent`, `CoworkRelayFile`, `CoworkRelayApprovalRequest`. Test: websocket_chat_service "replayed frames and user turns never enter a live run" extended with the three types (tool calls AND blocks stay empty).

`app/lib/services/websocket_chat_service.dart:375-382`, and the handlers at
`:182-196`.

```dart
static bool _isReplay(CoworkRelayInbound event) => switch (event) {
      CoworkRelayUser() => true,
      CoworkRelayDelta(:final replay) => replay,
      CoworkRelayReasoning(:final replay) => replay,
      CoworkRelayTool(:final replay) => replay,
      CoworkRelayDone(:final isReplay) => isReplay,
      _ => false,
    };
```

Bead cowork-266 gave `CoworkRelaySubagent`, `CoworkRelayFile` and
`CoworkRelayApprovalRequest` a `replay` flag
(`cowork_relay_client.dart:369-380`, `:544-556`, `:686-696`), and the replay
loader honours it. The adapter does not: `_ => false` sends all three straight
into `handle()`, which does

```dart
case CoworkRelaySubagent(): ledger.subagent(...);
case CoworkRelayFile():     await ledger.file(sessionKey, event);
case CoworkRelayApprovalRequest(): ledger.approval(sessionKey, event);
```

`ledger.file` re-encrypts the bytes and writes them into the blob store again
(`cowork_run_ledger.dart:399-414`) and appends a `sandboxArtifact` block to the
run that is open right now. The adapter's stream is open exactly while a run is
in flight, and a replay does reach it in that window: the relay client asks for
a replay on every (re)connect and the thread view calls `_requestReplay()` on
every `paired` transition (`cowork_thread_view.dart:334-345`), so a socket that
flaps during a run — a host restart, a laptop wake — replays the whole thread
into the live turn. Result: yesterday's child-agent cards and yesterday's file
attached to today's answer, a duplicate copy of every replayed file in the blob
store, and a replayed approval drawn as a fresh `ask_user` line on the live
turn. The adapter's own file header states the invariant this breaks ("It must
NEVER..."), and `test/services/websocket_chat_service_test.dart` covers only
delta / reasoning / tool / user / done.

Fix, one line each:

```dart
CoworkRelaySubagent(:final replay) => replay,
CoworkRelayFile(:final replay) => replay,
CoworkRelayApprovalRequest(:final replay) => replay,
```

and extend the "replayed frames and user turns never enter a live run" test
(line 329) with the three types.

---

### F4 — MEDIUM — `_onSocketDone` leaves `_socket` set, so `_reattach` can never reconnect

**Status: FIXED (f7).** `_onSocketDone` cancels the subscription and nulls `_socket`; `_reattach` also returns while a dial is in progress. Test: relay_client "after a host drop the scheduler's reconnectHost dials again instead of refusing with Already connected".

`app/lib/services/cowork/cowork_relay_client.dart:2167-2184`, `:1086-1096`,
`:1293`; `app/lib/services/session_refresh_scheduler.dart:116-131`.

`_onSocketDone` moves the phase to `closed` but never clears the socket:

```dart
if (_state.value.isPaired) {
  _set(const CoworkRelayState(phase: CoworkRelayPhase.closed, detail: 'Disconnected'));
}
```

`_socket = null` happens only in `_closeSocket()` (`:2200`, pairing failures)
and `dispose()` (`:1712`). `reconnect()` opens with

```dart
if (_socket != null) throw StateError('Already connected');
```

so `_reattach()` — the callback this client hands the scheduler as
`reconnectHost` in `_publishAttachment` — throws on every call after a normal
drop. In the scheduler that lands in

```dart
try { await reconnect().timeout(_reconnectGrace); } catch (_) { }
```

and falls through to rule 3: the app spends its own refresh token while the
host is away. That is precisely the sequence cowork-2n1 exists to avoid (host
rotated the pair, app's copy is dead, `/token` rejected, gotrue wipes the
session). The window is bounded by the thread view rebuilding the controller
(`_scheduleAutoReconnect` → `_rebuildController`), which disposes the old
client and withdraws its hooks, but on a phone in the background or with no
pairing store that rebuild may not happen for a long time.

Fix: null the socket (and the subscription) when the socket is done.

```dart
void _onSocketDone() {
  ...
  _sub?.cancel();
  _sub = null;
  _socket = null;
  if (_state.value.isPaired) { _set(closed); }
}
```

`_reattach` also needs a guard for a client that is `connecting`/`pairing`
already, otherwise two dials can race.

---

### F5 — MEDIUM — the rotated-session fallback provisions an empty `user_id`

**Status: FIXED (f7).** `_adoptRotatedSession` stays silent when the adopted session has no `userId` (no current session and no adopter). Test: relay_client "account_session_rotated with no session to name the user is not acked with an empty user_id". `ExecutorProvisioning.provision` was not changed (services/**, not in scope of this pass).

`app/lib/services/cowork/cowork_relay_client.dart:1479-1494`;
`app/lib/services/executor_provisioning.dart:66-80`.

```dart
adopted ??= AccountSession(
  accessToken: access is String ? access : (current?.accessToken ?? ''),
  refreshToken: refresh,
  userId: current?.userId ?? '',
  expiresAt: rotatedExpiresAt,
);
if (adopted.accessToken.isEmpty) return;
_provisionedAccessToken = null;
await _reprovision(adopted);
```

With no current session (the app is between a `signedOut(sessionExpired)` and
the recovery, or Supabase is not initialised so `_effectiveSessionAdopter`
returns null) `userId` is the empty string, and `ExecutorProvisioning.provision`
puts it on the wire unconditionally:

```dart
'user_id': session.userId,
```

`docs/WIRE_CONTRACT.md` ("account_session_rotated") says the app "never treats
this as a login for a different user: `user_id` is not carried and must not
change" — an empty one is exactly a change. Cheap fix: skip the ack when the
user id is unknown, or leave the key off the payload.

```dart
if (adopted.accessToken.isEmpty || adopted.userId.isEmpty) return;
```

and in `ExecutorProvisioning.provision`, `if (session.userId.isNotEmpty) 'user_id': session.userId`.

---

### F6 — MEDIUM — `setState` after an await with no `mounted` check in the reconnect path

**Status: FIXED (f7).** `_reconnect` bails when `!mounted`. Test: thread_view "a view disposed while its reconnect rebuilds the transport stays quiet".

`app/lib/widgets/cowork_thread_view.dart:395-401` and `:406-426`.

```dart
_autoReconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
  _autoReconnectTimer = null;
  if (!mounted || _storedPairing == null || _manuallyDisconnected) return;
  await _rebuildController();
  await _reconnect();
});
```

```dart
Future<void> _reconnect() async {
  final controller = _controller;
  final stored = _storedPairing;
  if (controller == null || stored == null || _busy) return;
  setState(() { ... });          // no mounted check
```

`_rebuildController` awaits `widget.controllerBuilder()` (a real client
generates a signing key first, so this is a real await). If the view is
disposed during that await, `_rebuildController` returns early — but it leaves
`_controller` pointing at the **old**, non-null controller, so `_reconnect`
does not bail and calls `setState` on a defunct state. Every later `setState`
in the method is guarded (`if (mounted)`), only the first is not.

Fix: `if (!mounted || controller == null || stored == null || _busy) return;`.

---

### F7 — MEDIUM — a thread's second "answer ready" row is never consumed

**Status: FIXED (f7, with F8).** The loader remembers the `run_id` of the `while_away` done (`answerReadyRunFor`); the thread view passes it to `CoworkNotifications.onAnswerReplayed(sessionKey, runId:)` (additive parameter); `RunNotifications.consumeForSession` dedups per `session/run_id` when the run is known, per session otherwise (old host). Tests: cowork_notifications "a second run for the same coworker is consumed too; the same run only once"; loader asserts `answerReadyRunFor`.

`app/lib/services/notifications/run_notifications.dart:36`, `:48-51`.

```dart
final Set<String> _consumedSessions = <String>{};
...
Future<void> consumeForSession(String sessionKey) async {
  if (!_consumedSessions.add(sessionKey)) return;
  await _consume(sessionKey: sessionKey);
}
```

The doc says "Idempotent per launch", but the set is keyed by session only, so
it is *once* per launch per thread, not once per row. Sequence: run 1 finishes
while away → row inserted → replay → row PATCHed to `consumed_at`, key added.
Later in the same app launch, run 2 for the same coworker finishes while away →
a new row → replay → the guard returns early → the row stays open forever. The
Edge Function then keeps that row as unread for every other device, and the
host's dedup key (`notified_at` / `consumed_at`, `docs/SUPABASE_SCHEMA.md`)
never closes.

Fix: the guard is there to stop a repeated replay of the *same* answer from
PATCHing twice. Key it on something that changes per run, or drop it and rely
on the `isFilter('consumed_at', null)` in the writer, which already makes the
PATCH a no-op when there is nothing open:

```dart
Future<void> consumeForSession(String sessionKey) => _consume(sessionKey: sessionKey);
```

---

### F8 — MEDIUM — `answerReadyFor` is never cleared, so later toasts for the thread are cancelled on sight

**Status: FIXED (f7).** `_onLoaderChanged` clears the flag before acting (`clearAnswerReady` notifies; re-entry sees it down). Test: cowork_thread_view_notifications third case extended — a later `run_state` neither consumes nor cancels again.

`app/lib/services/cowork/cowork_replay_loader.dart:185-189`;
`app/lib/widgets/cowork_thread_view.dart:612-621`.

```dart
void _onLoaderChanged() {
  if (!mounted) return;
  if (_loader.answerReadyFor(widget.threadKey)) {
    unawaited(CoworkNotifications.instance.onAnswerReplayed(widget.threadKey));
  }
  _syncRevision();
}
```

`clearAnswerReady` exists on the loader and is called by nothing outside
`test/services/cowork/cowork_replay_loader_test.dart:467`. So once a
`while_away` terminal has landed for a thread, the flag is true for the rest of
the process and `_onLoaderChanged` — which fires on every `run_state`, every
commit, every `notifyListeners` — calls `onAnswerReplayed` again and again.
`onAnswerReplayed` cancels the OS toast for that thread
(`cowork_notifications.dart:76-84`). Realistic consequence: the app is in the
background, a later run finishes, `onLiveDone` shows the toast, then any replay
or reconnect notification fires and the toast is cancelled before the user ever
looks at the screen. It also makes the flag useless as an "answer waiting"
affordance.

Fix: clear it when it has been acted on.

```dart
if (_loader.answerReadyFor(widget.threadKey)) {
  _loader.clearAnswerReady(widget.threadKey);
  unawaited(CoworkNotifications.instance.onAnswerReplayed(widget.threadKey));
}
```

(`clearAnswerReady` itself calls `notifyListeners`, so guard against the
re-entry — clear first, then act, as above.)

---

### F9 — MEDIUM — an approval prompt is shown on whatever thread is on screen

**Status: FIXED (f7 + 9e).** Host: 9e added `session_key` to the `approval_request` frame (protocol, executor, contract). App: `CoworkRelayApprovalRequest.sessionKey` (optional); the thread view prompts only when it is null (older host) or equals its own thread. Test: thread_view "an approval that names another thread is left to that thread's view".

`app/lib/widgets/cowork_thread_view.dart:505-524`;
`app/lib/services/cowork/cowork_relay_client.dart:717-740`
(`CoworkRelayApprovalRequest.fromPayload`).

The frame carries `approval_id`, `action`, `path`, `name`, `file_count`,
`total_bytes`, `base_url`, `public`, and — for a replay — `mid` / `decision`.
It carries no session key, and `_onInbound` does not check one either:

```dart
case CoworkRelayApprovalRequest():
  if (event.replay && (event.isDecided || !_ledger.isRunning(widget.threadKey))) return;
  setState(() { _approval = event; _approvalDecision = null; });
```

With two coworkers running at once (the ledger explicitly supports that:
`CoworkRunLedger.runningSessions`), a publish approval raised by coworker B
pops up as a standing bar over coworker A's thread. The decision itself is
correlated by `approval_id`, so the answer is not wrong — but the user is asked
about a publish in a conversation that has nothing to do with it, and the guard
on the replay path (`_ledger.isRunning(widget.threadKey)`) is asking about the
wrong thread too.

Fix needs one contract line — `session_key` on `approval_request`, the same way
`run_state` and `debug_context` carry it — plus, on the app side, parse it into
`CoworkRelayApprovalRequest` and prompt only when it equals
`widget.threadKey`. Until the host sends it, an app-side half-measure is to
prompt only while `_ledger.isRunning(widget.threadKey)`, which at least keeps
the bar off an idle thread.

---

### F10 — LOW — a credentials frame without `expires_at` erases the expiry

**Status: OPEN.** services/mcp/** is cowork-47's; left as documented (self-heals on the host's first 401).

`app/lib/services/mcp/mcp_service.dart:661-669`;
`app/lib/services/mcp/mcp_oauth.dart:72-76`.

```dart
final next = record.withTokens(McpTokens(
  accessToken: accessToken.isNotEmpty ? accessToken : record.tokens.accessToken,
  refreshToken: refreshToken,
  expiresAt: DateTime.tryParse(oauth['expires_at']?.toString() ?? ''),
  scope: record.tokens.scope,
));
```

`expires_at` is optional in the contract. When the host omits it,
`DateTime.tryParse('')` is null, the stored expiry is dropped, and
`McpTokens.isExpired` returns `false` for a null expiry — so
`McpStore._refreshedSecrets` will never pre-refresh that connector again and
the app keeps forwarding a bearer whose life it can no longer judge. Self-heals
on the host's first 401, so it is only LOW. Fix: `?? record.tokens.expiresAt`.

---

### F11 — LOW — `recordTool` can fill an open line that belongs to a different call

**Status: OPEN → 84/9e.** Assigned to cowork-84 (ledger), 9e carries the two-line change in the ledger pass.

`app/lib/services/cowork/cowork_run_ledger.dart:304-325`.

```dart
final sameId = event.callId != null && candidate.id == event.callId;
if (!sameId && candidate.name != event.name) continue;
```

When the frame carries a `call_id` and the newest open line has a *different*
id but the same name, `sameId` is false and the name check passes, so the open
line is filled in with the other call's result. That is only reachable with two
open lines of the same tool, which today needs a host that emits `running`
frames — no current host does. Fix: when both ids are known and differ, skip.

---

### F12 — LOW — the loopback listener completes on the first request of any path

**Status: OPEN.** services/mcp/** is cowork-47's; robustness nit, left as documented.

`app/lib/services/mcp/mcp_redirect_io.dart:30-46`.

```dart
_server.listen((HttpRequest request) async {
  final uri = request.uri;
  final ok = uri.queryParameters.containsKey('code');
  ...
  if (!_result.isCompleted) _result.complete(uri);
  await close();
});
```

Any local process that hits `http://127.0.0.1:<port>/` before the browser
redirect arrives ends the wait, and `exchange` then throws "the sign-in answer
did not match the request" (state check) — the sign-in fails rather than being
hijacked, so this is a robustness nit, not a hole. Fix: ignore requests whose
path is not `/mcp/callback` (answer 404 and keep listening).

---

### F13 — LOW — the loader's `user` case has no `replay` guard

**Status: FIXED (f7).** The loader's `user` case checks `replay`. Test: loader "a LIVE user frame is ignored like every other live frame".

`app/lib/services/cowork/cowork_replay_loader.dart:236-244`.

Every other case starts with `if (!replay) return;`. `CoworkRelayUser` does
not, and the class defaults `replay` to true, so today it cannot misbehave —
but the loader's own header states "this file handles nothing live", and the
adapter enforces the same rule by type (`CoworkRelayUser() => true`) rather
than by flag. Add the guard so the invariant is checked, not assumed.

---

### F14 — LOW — two `run_ack` frames per live `done`

**Status: FIXED (f7).** One owner: the thread view (`_onInbound`, dedups by run id, sees adopted runs too). The adapter no longer acks; its header table says so. Test: websocket_chat_service done test now expects no ack from the adapter; thread_view "a live done is acknowledged to the host, exactly once" unchanged.

`app/lib/services/websocket_chat_service.dart:235-242` and
`app/lib/widgets/cowork_thread_view.dart:530-534`.

Both the adapter and the thread view send `sendRunAck(runId)` for the same live
terminal. The thread view dedups with `_ackedRuns`; the adapter does not, so
the host gets the ack twice per run. Harmless (the host sets `seen_at` once),
but it is two sealed frames and two `seq` numbers for nothing, and `_ackedRuns`
grows for the life of the view. Pick one owner — the thread view's hook is the
one the WS-7 handover documents.

---

### F15 — LOW — doc drift on `CoworkRelayReasoning`

**Status: FIXED (f7).** Comment on `CoworkRelayReasoning` rewritten: emitted live and in replay (b5).

`app/lib/services/cowork/cowork_relay_client.dart:188-193`.

> "The executor strips `<think>` blocks today and does not forward them, so
> nothing emits this yet on the real wire."

Session b5 landed the reasoning channel on the host
(`HANDOVER_2026-09-05_REASONING_TOOLFRAMES.md`, live probe: 11 reasoning
frames) and `WIRE_CONTRACT.md` documents it as emitted. Update the comment.

---

## Areas reviewed with no finding

- `cowork_relay_link.dart` — the long-lived fan-out and `bind`/`unbind` are
  correct; an open subscription survives a controller swap, which is what keeps
  a run alive across a reconnect.
- `cowork_replay_guard.dart` — the `check`/`commit` split and the re-validation
  across the decrypt await are right, and the reasoning is written down.
- `cowork_frame.dart` / `cowork_frame_codec.dart` / `cowork_pairing.dart` /
  `cowork_reconnect.dart` — read for the frame path the loader depends on; no
  issue in scope for this pass.
- `services/storage/cowork_chat_store.dart` — the memory-first replace, the
  per-session write chain, the outbox marking *before* the cloud attempt and the
  `savingChats` shield against the sync are all sound; `replaceThread` refusing
  an empty row list is what keeps an empty replay from wiping a thread.
- `services/storage/cowork_chat_storage_bootstrap.dart` — sign-in / sign-out
  symmetry, the flush timer and the migration call are correct.
- `services/chat_storage_service.dart` (the facade divergences) — the dirty-thread
  guards in `mergeSyncedChat`, `mergeSyncedChatsBatch` and `removeChatLocally`
  do what the header claims.
- `services/account_session.dart` — the headroom rule, the `/user` restore after
  a rejected refresh and the "unknown expiry counts as due" choice all match
  cowork-2n1's analysis.
- `services/session_recovery.dart` — `_rotationSeen` / `_stashSpent` correctly
  make the app's own refresh token a last resort, and the crash-safe stash key
  handles a kill mid-recovery.
- `widgets/auth_gate.dart` — the `signOutReason` split, the `_recovering` gate
  and the stash cleanup are correct.
- `services/notifications/local_notifications.dart` and
  `notification_router.dart` — no answer content in title, body or payload; the
  cold-start pick-up survives a shell that is not built yet.
- `services/notifications/push_service.dart` — the token row follows sign-in and
  sign-out, and Firebase being absent disables push instead of breaking the app.
- `services/mcp/mcp_oauth.dart` — PKCE, `state` and `iss` are all checked before
  the code is spent; a rotated refresh token is kept, a non-rotating server's is
  carried forward.
- `services/mcp/mcp_store.dart` — the shared in-flight refresh future, the UTC
  expiry on the wire and the legacy bare-token upgrade are right.
- `services/mcp/mcp_service.dart` mirror adoption — "adopt only when the local
  record is unusable" is implemented as described and is the correct rule.
- `pages/messenger_shell.dart` / `pages/cowork_shell_state.dart` — one
  `_buildThread` with one `GlobalKey`, the thread view kept `Offstage` on both
  the compact desktop and the phone inbox, `_hostDispose` releasing exactly what
  it owns. Single-socket ownership holds.
- `widgets/agent_roster_view.dart`, `widgets/agent_run_views.dart`,
  `pages/settings/mcp_connectors_page.dart` — controllers disposed, `mounted`
  checked after every await, no timers left running.
- `services/tool_call_handler.dart` — the fold never returns `shouldContinue`,
  so the client-side tool loop stays structurally dead.
- Secret hygiene: no `debugPrint` in CoWork's own code prints a token, a refresh
  token, a client secret or a VNC password. The relay client logs only phases
  and step names; the MCP files log the exception, never the material.

Nothing in this pass touched a file in the OUT list, so there is no upstream
finding to hand back to chuk_chat master.

## Summary for the fixer

- **F1 (HIGH, `cowork_replay_loader.dart`)** — one global `_activeSession`: a
  second replay (first pairing, or switching coworker mid-stream) folds one
  thread's rows into another's cache and poisons its cursor.
- **F2 (HIGH, `cowork_replay_loader.dart`)** — a delta replay whose local read
  returns nothing writes only the delta over the thread and still advances the
  cursor; the older history is unrecoverable.
- **F3 (HIGH, `websocket_chat_service.dart`)** — `_isReplay` misses
  `subagent` / `file` / `approval_request`, so a replay during a live run
  attaches yesterday's cards and re-writes a replayed file into the blob store.
- **F4 (MEDIUM, `cowork_relay_client.dart`)** — `_onSocketDone` keeps `_socket`,
  so `reconnectHost` always throws and the app spends its own refresh token
  instead of adopting the host's rotated pair.
- **F5 (MEDIUM, `cowork_relay_client.dart`)** — the rotated-session fallback can
  provision the host with `user_id: ""`.
- **F6 (MEDIUM, `cowork_thread_view.dart`)** — `_reconnect()` calls `setState`
  without a `mounted` check after an await.
- **F7 (MEDIUM, `run_notifications.dart`)** — the per-session guard closes only
  the first notification row per launch; later ones stay open forever.
- **F8 (MEDIUM, `cowork_thread_view.dart` / loader)** — `clearAnswerReady` is
  never called, so later toasts for that thread get cancelled on any loader
  notification.
- **F9 (MEDIUM, `cowork_thread_view.dart`)** — a publish approval prompts on
  whichever thread is on screen; the frame needs a `session_key`.
