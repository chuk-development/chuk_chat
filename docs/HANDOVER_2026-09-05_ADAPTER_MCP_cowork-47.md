# Handover — cowork-47, adapter / replay / MCP, 2026-09-05

Second handover. The first,
`docs/HANDOVER_2026-09-05_MCP_cowork-47.md`, covers the MCP OAuth work in
detail and is still accurate; this one covers the adapter, the replay loader and
what happened after it.

## Commits

- `6d7f75e` — carries my whole MCP block (mcp_oauth, mcp_redirect*, mcp_service,
  mcp_store, the MCP tests, HANDTEST_MCP_OAUTH.md, the first handover). It is
  NOT my commit and its message is about settings and model selection: another
  session staged broadly while my files sat in the shared index. Nothing is
  lost; the history simply lies at that point.
- `ea6daad` — "fix(replay): stop a retry and a reconnect from duplicating the
  thread". Mine, except for 145 lines in `app/test/widgets/messenger_shell_test.dart`
  that are somebody else's uncommitted sidebar work: `git commit -o` protects
  against the shared index, not against a named file holding another session's
  working-tree changes. Reported; the owner may want to split it out.
- The Python half of `regenerate` and the WIRE_CONTRACT section went into
  cowork-b5's R4. The MCP refresh path and `mcp_credentials` are in `0ae3a49`
  and `844be0a` (cowork-49).

## Not committed, on purpose

`app/lib/platform_specific/chat/desktop_send_logic.dart`,
`chat_ui_mobile.dart` and `handlers/streaming_message_handler.dart` are still
untracked — they are the verbatim chat-UI import, thousands of lines that belong
to nobody here. Each holds ONE line of mine: `regenerate: isRegenerate &&
currentPass == 0` on the `sendStreamingChat` call. **Whoever commits the import
brings the Retry fix with it.** Until then the app never sets `regenerate`, so
the host keeps storing one user row per retry even though both halves of the fix
exist. This is the single most important line in this document.

## What the replay path now guarantees

Three rules, each with a test:

1. **A live turn invalidates the cursor.** The cursor only moves on a replay, so
   after a live turn it points below rows the UI wrote locally; a later replay
   from there appends the host's copy under the local one. `invalidateCursor` on
   every live `done` makes the next replay a full one, and a full replay
   REPLACES the thread. Cost: one full replay per reconnect.
   **Migration:** when the host stamps live events with their row id
   (`done.last_mid`), swap that call for the already-public
   `advanceCursor(session, mid)` — cheaper and exact. `invalidateCursor` then
   stays as the fallback for a host that sends no id.
2. **A cursor with no local thread is a lie.** Two branches in `_commit` handle
   it: a delta WITH rows whose `existing` is empty (cowork-94's "review F2"),
   and a delta with NO rows, which checks `ChatStorageService.hasLocalThread`
   before advancing (mine, bead cowork-izh). The second is the nastier one — it
   is self-sealing: the thread stays empty, the cursor keeps advancing, and the
   host is never asked again although it still has every word.
   cowork-a4's `dropOrphanCursors` repairs an already-broken client at sign-in.
3. **Auth goes out before replay.** `requestReplay` waits on `_provisionGate`
   (opened per connect, closed when the provision lands, 10 s escape hatch).
   Proven live: after the rebuild the host log shows `reconnected` → `account
   session refreshed in place` → `token re-provisioned`, and the old `expected
   account_authentication, got 'replay'` appears only once, from the reconnect
   before the rebuild.

## Traps worth knowing

- **The chat UI writes the local rows; the loader writes the replayed ones.**
  Any change to one has to be checked against the other, or the same turn lands
  twice. The parity test cowork-84 added
  (`app/test/services/agents/tool_card_parity_test.dart`) is the tool-call half
  of exactly that.
- **`_isReplay` in the adapter decides ownership.** Anything replayed, and every
  `user` frame, belongs to the loader; everything else to the ledger. A new
  inbound type has to be classified in BOTH the adapter switch and the loader
  switch or it silently disappears.
- **Signature changes to `AgentsRelayController` need every fake in the same
  step.** There are three: `test/support/fake_relay_controller.dart`,
  `test/widget_test.dart`, `test/widgets/messenger_shell_test.dart`. I broke the
  tree once by adding `regenerate` to `sendTask` and only fixing the first.
- **The git index is shared by every session in this worktree.** Never
  `git add -A`, `git commit -a` or `git reset`. Use
  `git commit -o -- <explicit paths>` AND read `git diff --stat -- <paths>`
  first: `-o` still commits another session's working-tree changes in a file you
  name. Both failure modes happened today, once in each direction.
- **`messenger_shell_test` has one red test**, "deleting an agent syncs its rooms
  to the host". It fails on a sidebar UI finder, not on anything in this
  handover; cowork-a4 diagnosed it independently.

## Open

- **cowork-sls (P1)**: nobody has ever signed in to a REAL provider. The whole
  MCP flow is proven against a real loopback listener, a real redirect, a real
  code exchange and a real token endpoint on a socket — but no Google or Notion
  server has answered. `docs/HANDTEST_MCP_OAUTH.md` is the 5-step, ~2-minute
  acceptance. Do this before believing the feature works.
- **cowork-hza (P1)**: connectors already signed in inside chuk_chat show as
  "connect" in Agents. Mirror the connection state through the same Supabase
  tables chuk_chat uses. Reassigned away from me.
- **P7 rest (notifications, app side) and P8 (Opus review of the whole Flutter
  side)** were assigned to me and never started. Plan:
  `docs/PLAN_2026-09-04_AGENTS_CHUK_ALIGN.md` §WS-7. The host side exists
  (`host/notify.py`, `desktop_notify.py`, `supabase/functions/notify-run`); the
  app has `notification_service.dart` as a no-op stub from the import, and the
  real port belongs in `services/notifications/local_notifications.dart` with the
  stub kept as a signature-compatible facade until the imported chat UI is moved
  off it. `pubspec.yaml` needs `flutter_local_notifications`, `firebase_core`,
  `firebase_messaging`.
- **A test for the DEFAULT `_adoptRotatedSession` path.** The injected adopter
  keeps its signature so existing tests stay green, but the real path hangs on
  `SupabaseService.auth` and needs an injection point first.
- **cowork-9e's two optional scheduler hooks** in the relay client
  (`SessionRefreshScheduler.instance.hostAttached` and `.reconnectHost`). They
  close the laptop-wake gap. Not built: they touch the state transitions in
  `_set` and `dispose`, which should not change without a full test run after.
- **`runtime.py` / `config_token_exchange`** hands every forwarded `oauth` block
  to a function that only reads the §10 shape (`token_url`), so
  `mcp_oauth_connect` is offered to the model for connectors where it dead-ends.
  No credential leak — checked. Belongs to the Python owner.

## Test status at handover

Dart, each run alone: `agents_replay_loader_test` 27, `agents_relay_client_test`
51, `websocket_chat_service_test` 18, `mcp_store_test` 15, `mcp_oauth_test` 13,
`mcp_service_test` 27, `mcp_connectors_page_test` 2, `widget_test` 3.
Python: `test_mcp_client` 71, `test_state` + `test_loop` 56, `test_regenerate` 4.
Ruff clean.
