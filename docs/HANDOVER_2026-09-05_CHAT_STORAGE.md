# Handover 2026-09-05 — Agents chats in SQLite + Supabase, like chuk_chat

Session `cowork-a4`, bead `cowork-sha`. Coordinator: `cowork-b7`, then `cowork-76`.
This file lets a fresh session finish or maintain the work with no context.

## The directive (user, 2026-09-05 04:00)

"Die Chats für Agents müssen auch in lokaler SQL gespeichert werden und
schnell und besser geladen werden, genau wie die anderen Chats: in der Supabase
und in der Flutter-SQL. Basically genau wie das andere Ding, nur zusätzlich im
Python-Ding gespeichert."

So: the chuk_chat storage path, verbatim where possible; Agents threads are rows
in it; the Python host stays the source of truth and its replay is a delta
reconcile from the cursor.

## What was found (Ist)

- chuk_chat (`~/git/chuk_chat` master, `d31526a`): `ChatStorageService` is a
  facade over `chat_storage_crud/sync/mutations/sidebar`, `chat_preload_service`,
  the sqflite cache `local_chat_cache_native` (gzip plaintext rows, own
  `sqfliteFfiInit()` on Linux/Windows) and `chat_sync_service` (30 s poll of
  `encrypted_chats` on `id, updated_at`, fetch + decrypt the changed rows).
- Agents had stubs for the facade and the sync, a SharedPreferences cache, and
  P2b's interim JSON-file cache (one file per session key). No sqflite in
  pubspec. Same Supabase project as chuk_chat.
- A Agents session key (`default`, an agent id) is not a UUID, and
  `encrypted_chats.id` is `uuid`. A shared table would also list Agents threads
  in chuk_chat's sidebar.
- chuk_chat's write path INSERTs a new chat / UPDATEs a known one and refuses to
  run without a signed-in user and an unlocked encryption key. The replay loader
  wrote through it and swallowed the error, so with the key missing at start
  (bead `cowork-6v5`) nothing from a replay would have been cached.

## What was built

Files owned by this session. Committed: dcaa60d (storage), a520aed (pubspec lines); the migration + outbox follow in their own commits. Commit rule since 2026-09-05: every finished step is committed at once (CLAUDE.md "Commit-Regel").

| file | what |
|---|---|
| `app/lib/services/chat_storage_crud.dart`, `chat_storage_sync.dart`, `chat_storage_mutations.dart`, `chat_storage_sidebar.dart`, `chat_preload_service.dart`, `chat_sync_service.dart`, `local_chat_cache_service.dart`, `local_chat_cache_native.dart`, `local_chat_cache_web.dart` | VERBATIM chuk_chat (package prefix rewritten, table name `'encrypted_chats'` → `'cowork_chats'` by the import script). Listed in `tools/chat_ui_manifest.txt` ("Chat storage" block). Never hand-edit; re-sync with `scripts/import_chat_ui.sh`. |
| `app/lib/services/chat_storage_service.dart` | chuk's facade with RECORDED divergences (header + `docs/CHAT_UI_IMPORT.md` "Allowed divergences" 3/4): `saveChat`/`updateChat` → `AgentsChatStore.replaceThread`; `loadFullChat` memory-first; `loadFromCache`/`loadChats`/`loadSavedChatsForSidebar` no-op with no Supabase client. NOT in the manifest. |
| `app/lib/services/storage/agents_chat_store.dart` | The write path: memory synchronously → SQLite row (`LocalChatCacheService.upsert`) → `EncryptionService.encrypt` + `upsert` on `cowork_chats (user_id, id)`, best-effort, chained per session, never throws. Adopts the server's timestamps. Drops a thread's replay cursor when the sync removes the thread locally (next open = full replay). `loadThread` = memory → chuk cache-first load. Test seams: `userIdProvider`, `cloudUpsert`, `localCacheWriter`, `keyLoader`, `encryptor`. |
| `app/lib/services/storage/agents_chat_storage_bootstrap.dart` | Auth-stream listener started from `main.dart`: session → `loadSavedChatsForSidebar()` + `ChatSyncService.start()` + cache migration; sign-out → `stop()` + `reset()`. |
| `app/lib/services/mcp/mcp_sync_service.dart` | 8-line stub (`pullAndReconcile` no-op) the verbatim sync imports. Owner from now: cowork-47. |
| `app/lib/main.dart` | +2 imports, +2 lines after `SupabaseService.initialize()`: `initChatStorageCache()`, `AgentsChatStorageBootstrap.start()`. |
| `app/pubspec.yaml` | +4 lines (append-only, chuk versions): `sqflite ^2.4.3`, `sqflite_common_ffi ^2.4.2`, `path ^1.9.1`, `sqlite3_flutter_libs ^0.6.0+eol`. Committed alone as a520aed; `app/linux/flutter/generated_plugin*` carry no hunk for these packages. |
| `supabase/migrations/20260905000000_cowork_chats.sql` | DDL + trigger + RLS. **The user must run it once** in the Supabase SQL editor. Until then every cloud upsert fails silently ("relation cowork_chats does not exist") and threads stay local; nothing else breaks. |
| `docs/SUPABASE_SCHEMA.md` | New section "Agents threads — cowork_chats". |
| `docs/CHAT_UI_IMPORT.md` | Stub inventory rows updated, divergences 3/4, new section "Chat storage (bead cowork-sha)". |
| `tools/chat_ui_manifest.txt`, `scripts/import_chat_ui.sh` | Manifest block; table-name sed after the package-prefix sed. |
| `app/test/services/storage/agents_chat_store_test.dart` (10), `agents_chat_storage_bootstrap_test.dart` (5) | Green. |

## How a thread flows now

1. Open: the imported screen calls `loadFullChat(threadKey)` → memory → SQLite
   → cloud. Paints at once from the local copy.
2. In parallel `AgentsThreadView` requests a host replay from the persisted
   cursor (`cowork.replay_cursor.<key>`, `after_id`). `AgentsReplayLoader`
   folds the delta, appends to the cached rows and calls
   `ChatStorageService.saveChat(rows, chatId: key)` → `replaceThread`.
3. A live turn: the imported persistence handler calls `saveChat`/`updateChat`
   → the same `replaceThread`.
4. Every 30 s `ChatSyncService` compares `id, updated_at` with `cowork_chats`,
   pulls rows another device wrote, refreshes SQLite. A row deleted on the
   server is removed locally and its cursor dropped → the host replays it in
   full next time (host = truth).

## Verified (seen, not assumed)

- Scoped `flutter analyze` on the 13 touched files: 0 issues.
- `agents_chat_store_test` 10/10, `agents_chat_storage_bootstrap_test` 5/5,
  `agents_replay_loader_test` 12/12 (was 10/12 after the raw verbatim import;
  the facade override fixed it), `tool_card_parity_test` 3/3, `widget_test` 3/3.
- `agents_thread_view_test` 22/23: the red one is a pending 500 ms timer from
  `AppThemeService.setShowReasoningTokens` (test line 421) — the reasoning
  session's in-progress change, not storage.
- `messenger_shell_test` 14/15: 'deleting an agent syncs its rooms to the host'
  fails on a sidebar icon finder (line 543) — cowork-5c's sidebar rebuild, not
  storage (no `ChatStorageService` call on that path).
- The rebuilt app (pid 4167244, started by cowork-5c) created
  `~/.local/share/dev.chuk.cowork/chat_cache.db` at 03:55.

## The cloud outbox (bead cowork-hyg, closed)

Problem: the cloud upsert is skipped without a key (a restored session has
none until the next password login), without a network, or while the table
is missing. A thread with no further turn then never reached Supabase and a
reinstall would lose it.

Fix, all in `agents_chat_store.dart` / the bootstrap / the facade:

- Outbox = `Map<sessionKey, updated_at>` in memory, persisted in the SQLite
  file chuk_chat's cache already has (`kv_cache`, key
  `cowork.cloud_outbox.<userId>`; no verbatim file touched). A thread is
  marked BEFORE each cloud attempt and cleared after a successful one, so a
  crash mid-write is covered.
- `flushOutbox()`: serialised on its own chain; needs user + key; pushes the
  newest local copy (memory if fully loaded, else the SQLite row via
  `loadById`); skips a thread whose own write chain is running; drops a flag
  with no local copy anywhere. Triggered on sign-in and every 30 s by the
  bootstrap's timer (same period as `ChatSyncService`), and by the facade
  when the sync tries to remove a dirty thread.
- Shield against the sync: a dirty thread sits in
  `ChatStorageState.savingChats` (chuk's own skip set); the facade drops it
  from `mergeSyncedChat(s)` and refuses `removeChatLocally` for it (flushes
  instead). Local data is never overwritten by an older cloud picture and
  never discarded before it was uploaded.
- Tests: `agents_chat_store_test` 16/16 (6 outbox cases: no key → dirty +
  persisted + shielded; key arrives → flush from memory; offline → retried;
  persisted outbox from a previous run flushed from the SQLite row; ghost
  dropped; facade never removes/merges over a dirty thread),
  `agents_chat_storage_bootstrap_test` 6/6 (flush at sign-in and per tick,
  stops at sign-out), `agents_replay_loader_test` 21/21.

## "Yesterday's history is gone" (bead cowork-izh, P0) — cause and fix

Found with data, not by running the app:

- Host DB `~/.agents/executor-state.db`: session 2 = `host:cowork-host`,
  89 messages from 2026-09-03 23:06 to 2026-09-05 01:23, max mid 106. Intact.
- P2b JSON cache `~/.local/share/dev.chuk.cowork/chats/host_cowork-host.json`:
  27 folded rows, written 03:26. Intact.
- SQLite `chat_cache.db`: only the row `default` (host session 1, 17 old
  messages). No row for `host:cowork-host`.
- SharedPreferences: `cowork.replay_cursor.host:cowork-host` = 106.

Chain: open the thread → `loadFullChat`: memory empty, no SQLite row, no
cloud row → nothing to paint; replay with `after_id` 106 → the host has
nothing above 106 → the loader commits "nothing new" → the thread stays
EMPTY. Cause: the SQLite storage replaced the JSON-file cache without reading
those files, while the persisted cursor still claimed the device held
everything. Nothing was lost anywhere.

Fix (`services/storage/agents_chat_cache_migration.dart`, run by the
bootstrap at the first auth event, i.e. at app start with a restored session,
before `ChatSyncService.start()`; no encryption key needed, the rows are
plaintext):

1. `migrateJsonCache(userId)`: every `<support>/chats/*.json` (except
   `index.json`) without a SQLite row → `AgentsChatStore.replaceThread` with
   the file's own `createdAt`/`updatedAt`/`isStarred`/`customName`; the file
   is renamed `.migrated` (a backup, never deleted). A file whose thread
   SQLite already holds is only renamed (the row is newer).
2. `dropOrphanCursors(userId)`: a cursor whose thread has no local copy
   (neither memory nor a SQLite row) is removed, so the next open is a full
   replay from the host. A full replay is always safe; an empty delta is not.

Tests: `agents_chat_cache_migration_test` (6): the P2b file becomes the
thread with its dates, a known thread keeps the newer row, an unreadable file
stays and does not stop the rest, no directory → no-op, orphan cursor dropped
and a live one kept, the default probe sees memory.

## Open

- Full `flutter analyze` at the gate (compiler window per coordinator).
- Live proof + screenshots before/after (`docs/screenshots/cowork-a4/`) once
  the user says the screen is free: cold-open a thread → paints from SQLite
  before the host answers; restart the app → history is there without waiting
  for the replay.
- Diff for cowork-47 (`agents_thread_view.dart` line ~232):
  `ChatStorageService.loadChats()` → `loadFromCache()`; chuk's `loadChats`
  pulls and decrypts every chat on each mount. Not urgent (the facade makes it
  a no-op without a client; with a client it is just slow).
- `cowork-6v5` (encryption key not loaded at start until the next password
  login) now only delays the cloud copy; the local copies never depend on it.

## Rules kept

No commit, no worktree, no branch switch, no hot-reload of an app this session
did not start, one Flutter compiler at a time, tests one file at a time,
foreign files only by diff proposal (the one new stub file in
`services/mcp/` was announced to its owner and handed over).
