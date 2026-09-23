# Handover — cowork-47 (MCP OAuth, retry duplication), 2026-09-05

Written at ~550k context. Everything below is done and tested unless it says
otherwise. Nothing of mine is committed on the Dart side; the Python side is
partly committed (see the file list at the end).

## What was built

### 1. MCP OAuth on the device (beads cowork-865, cowork-e8u)

The ~50 OAuth connectors showed in the UI and never authenticated, because
nothing started an OAuth flow: `mcp_oauth.dart` and `mcp_redirect*.dart` were
missing from the tree, `McpService.connect()` was a pure store write, and the
forward payload therefore always went out with `auth: "oauth"` and no token.

- `lib/services/mcp/mcp_oauth.dart`, `mcp_redirect.dart`, `mcp_redirect_io.dart`,
  `mcp_redirect_stub.dart` — verbatim from chuk_chat, only `clientName`,
  `clientUri` and the redirect page copy changed.
- `McpService.connect()` runs the real flow: discovery → dynamic client
  registration → PKCE → loopback redirect → code exchange → full record.
  `_launch` / `_closeBrowser` are chuk's.
- One deliberate addition over chuk: `_challengeFor()` sends ONE unauthenticated
  request and reads only the status and the `WWW-Authenticate` header. Agents has
  no device-side MCP client by design, so without it `McpOAuth.challengeScopes`
  and `resourceMetadataUrl` were dead code — and Atlassian and Linear name their
  required scopes ONLY in that challenge. Without them the token is minted for
  the wrong grant and every tool call comes back 403, which looks like a broken
  connector rather than a broken sign-in.
- `McpStore` keeps chuk's full secret record (client credentials, tokens with
  refresh and expiry, issuer, endpoints, scope). A legacy bare-token value still
  reads and is upgraded on the next write. `forwardPayloads()` refreshes a lapsed
  token before forwarding, adds the additive `oauth` block, and carries `id`.
- `McpConnectorSync` mirrors the whole record. The mirror is adopted only when
  the local record is UNUSABLE — never over a live one, because the mirror is
  written on connect and disconnect and is routinely the older copy.
- Python (`agent/src/chuk_agents_runtime/mcp_client.py`): `token_expired`,
  `refresh_access_token`, `MCPConnection.refresh_token(force=)` under a lock,
  `_http_headers` precedence, `MCPManager._retry_with_fresh_token` and `_revive`,
  and the `on_credentials_rotated` hook the executor hangs `mcp_credentials` on.
- Contract: `docs/WIRE_CONTRACT.md`, sections "`mcp_servers` on `task`" and
  "`mcp_credentials`". Frozen fixture asserted from both languages:
  `app/test/fixtures/mcp_forward_payload.json`.
- Hand test for the user: `docs/HANDTEST_MCP_OAUTH.md` (5 steps, ~2 minutes).

An Opus review found 12 issues; 11 are fixed (3 HIGH: a 401 mid-session was never
renewed, a cached manager never revived a dead connector, a rotated refresh token
was thrown away). The twelfth is `runtime.py` and belongs to the Python owner:
every forwarded `oauth` block is passed to `config_token_exchange`, which only
reads the §10 shape (`token_url`), so `mcp_oauth_connect` is offered to the model
for connectors where it dead-ends. No credential leak — checked.

**Still unproven: a real provider.** The flow is proven against a real loopback
listener, a real redirect, a real code exchange and a real token endpoint on a
socket, but no Google or Notion server has ever answered. That is bead
`cowork-sls` (P1, assignee chukfinley) and `docs/HANDTEST_MCP_OAUTH.md`.

### 2. Retry duplicated the user message (bead cowork-bkw)

Two independent causes produced the same picture. Fixing one alone would have
left the user still seeing duplicates.

**Cause A — the host stored one user row per attempt.** Retry re-sends the same
prompt as an ordinary task, so `AgentLoop.run` appended a second identical user
row. `state.replay_events` emitted one `user` event per row and the replay loader
appended one bubble per event. Worse and invisible: the model was handed a
history in which the reader asked the same thing four times, and the reader paid
for all of it on every later turn.

Fix: additive `regenerate: true` on the `task` frame
(`docs/WIRE_CONTRACT.md`), `StateStore.drop_last_user_turn`, `AgentLoop.run(...,
regenerate=)`, `_Run.regenerate` + `_accept_task` + the `loop.run` call,
`task_payload` and `ControllerSession.send_task`. App side: `sendTask`,
`WebSocketChatService.sendStreamingChat`, and the first pass only in
`desktop_send_logic.dart` and `streaming_message_handler.dart` — later passes of
the same turn are continuations and must NOT drop again.

**Cause B — the replay cursor never moved for a live turn** (found by
cowork-84). A live turn is written locally by the UI; the cursor only advances on
a replay. The next reconnect asked from the stale cursor, the host honoured it,
and `_commit` appended the host's copy of those same turns under the local ones.

Fix: `AgentsReplayLoader.invalidateCursor(session)`, called from the adapter on
every live `done`. The next replay is then a full one, and a full replay REPLACES
the thread instead of appending. Cost: one full replay per reconnect.

**Migration to do later:** when the host stamps live events with their row id
(`done.last_mid`), replace that call with the already-public
`advanceCursor(session, mid)`. That is the cheap path; `invalidateCursor` then
becomes the fallback for a host that sends no id. Both are documented in
`agents_replay_loader.dart`.

### 3. Replay before auth

The relay client asked for a replay before it provisioned the account — the host
logged `expected account_authentication, got 'replay'` on every reconnect.
`requestReplay` now waits on `_provisionGate` (a completer opened on each
connect, closed when the provision lands, with a 10 s escape hatch so a caller
that never provisions still gets its transcript).

**Proven live**: after the rebuild, `.hostlive` shows `reconnected with app
device …` → `account session refreshed in place from a new token frame` → `token
re-provisioned`, and the old line appears only once, from the pre-rebuild
reconnect.

### 4. The logout (bead cowork-2n1, 9e's diagnosis, my file)

`_adoptRotatedSession` called `setSession(refreshToken)` — a `/token` call with
the HOST's token. gotrue-dart 2.27.1 clears the stored session and fires
`signedOut(sessionExpired)` on ANY non-retryable `/token` failure, even when the
app's own access token is still valid. Adopting the host's rotated pair could
therefore sign the user out of a working app. `_effectiveSessionAdopter` now
takes the rotated access token and passes it, so gotrue goes through `/user`:
nothing is spent and a rejected pair costs nothing.

### 5. Reasoning on replay (b5's request, my files)

`AgentsRelayReasoning` carries `replay` and `mid`; the replay loader buffers it
per assistant row and writes `reasoning`, so a replayed answer shows the same
thinking block the live one had.

## Files I own

`app/lib/services/mcp/**`, `app/lib/services/agents/agents_relay_client.dart`,
`agents_replay_loader.dart`, `app/lib/services/websocket_chat_service.dart`
(send path + replay/ledger only — the inbound reasoning mapping is cowork-b5's),
`app/lib/pages/settings/mcp_connectors_page.dart`,
`app/lib/widgets/mcp_connect_card.dart`, `agent/src/chuk_agents_runtime/mcp_client.py`,
the MCP sections of `docs/WIRE_CONTRACT.md`.

`app/lib/services/mcp/mcp_sync_service.dart` is a deliberate no-op. chuk syncs one
row per connector on a tick; Agents mirrors the whole set as ONE encrypted blob,
pulled by `McpService.load()` and pushed on connect/disconnect. A 30-second tick
would decrypt that blob over and over for a set that only changes when the user
touches it — and it would be repeated chances to lay an older mirror over a
record this device has just refreshed. The reasoning is in the file header.

## Test status

Green, each run on its own: Dart `agents_relay_client_test` 46,
`agents_replay_loader_test` 16, `websocket_chat_service_test` 18,
`mcp_store_test` 15, `mcp_oauth_test` 13, `mcp_service_test` 27,
`mcp_connectors_page_test` 2, `widget_test` 3. Python `test_mcp_client` 71,
`test_state` + `test_loop` 56, `test_regenerate` 4. Ruff clean.

`messenger_shell_test` is 14 green, 1 red — `deleting an agent syncs its rooms to
the host` fails on a sidebar UI finder. Not mine; cowork-a4 diagnosed it
independently and points at the sidebar rebuild.

## Open, NOT done

1. **`flutter analyze` after a4's diff 8.** I changed
   `agents_thread_view.dart:_bootstrap` from `ChatStorageService.loadChats()` to
   `loadFromCache()` (cloud pull + decrypt of every chat on every mount → local
   metadata). RAM was too tight to analyze afterwards. Verify before trusting it.
2. **A test for the DEFAULT `_adoptRotatedSession` path.** The injected adopter
   keeps its signature so existing tests stay green, but the real path now hangs
   on `SupabaseService.auth` and would need an injection point first.
3. **9e's two optional scheduler hooks** in the relay client:
   `SessionRefreshScheduler.instance.hostAttached` (true on paired, false on a
   drop with a stored pairing, null in dispose) and `.reconnectHost`. They close
   the laptop-wake gap. Not built: they touch the state transitions in `_set` and
   `dispose`, which I did not want to change without a full test run after.
4. **cowork-84's tool-card proposal**
   (`docs/PROPOSAL_2026-09-05_TOOLCARDS_cowork-84.md`) — 84 builds it in my files
   itself, after cowork-b5's Python tool-frame pass.
5. **`runtime.py` / `config_token_exchange`** — see the review note above.
6. **P7 (notifications, app side) and P8 (Opus review of the whole Flutter side)
   were assigned to me and NEVER STARTED.** The plan is
   `docs/PLAN_2026-09-04_AGENTS_CHUK_ALIGN.md` §WS-7. The host side exists
   (`host/notify.py`, `desktop_notify.py`, `supabase/functions/notify-run`). The
   app has `notification_service.dart` as a no-op stub from the import; the real
   port goes to `services/notifications/local_notifications.dart` with the stub
   kept as a signature-compatible facade until the imported chat UI is moved off
   it. `pubspec.yaml` needs `flutter_local_notifications`, `firebase_core`,
   `firebase_messaging`.

## Uncommitted

Dart: everything above, waiting on the user's release.

Python, mine, uncommitted at the time of writing: `agent/src/chuk_agents_runtime/state.py`
(`drop_last_user_turn`), `agent/src/chuk_agents_runtime/loop.py` (`run(regenerate=)`),
`executor/src/chuk_agents_executor/executor.py` (`_Run.regenerate`, `_accept_task`,
the `loop.run` call), `executor/src/chuk_agents_executor/protocol.py` (`task_payload`),
`executor/src/chuk_agents_executor/controller.py` (`send_task`),
`agent/tests/test_state.py`, `agent/tests/test_loop.py`,
`executor/tests/test_regenerate.py`, `agent/tests/live_native_probe.py` (the
probe guards), `docs/WIRE_CONTRACT.md` (the `regenerate` section).

Already committed by cowork-49: 0ae3a49 and 844be0a (MCP refresh path,
`mcp_credentials`, the rotation hook, the fixture, the MCP contract sections).

## Notes for whoever runs the model probe

`agent/tests/live_native_probe.py` takes its token from the RUNNING APP's
`shared_preferences.json` — there is no `.env.live`. I added three guards: it
refuses to run with under 15 minutes of token life, `session.refresh` is replaced
by a hard stop (refreshing rotates the pair and signs the app out), and an
unknown model or an unavailable provider aborts instead of silently falling back
to the default, which would report a pass for a model nobody asked about.

Result on 2026-09-05: `deepseek/deepseek-v4-flash-0731 @ fireworks/serverless`
PASSES (`native tool_calls frame used: True`, one `run_command` call, no prose).
Gemini-3 could not be probed: `/v1/models_info` lists 39 models and not one is a
Gemini. The only Google entry is `google/gemma-4-31b-it`.
