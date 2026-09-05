# Supabase schema — encrypted pairing mirror

This is the provisioning contract for the "reinstall anywhere, reconnect
automatically" feature (see `docs/PRODUCT_PHILOSOPHY.md`). The Flutter client
mirrors its CoWork trust record to Supabase so a fresh install can sign in and
reconnect to the same running Python server with no re-pairing.

The client code that reads and writes this table is
`app/lib/services/cowork/supabase_pairing_sync.dart` (`SupabasePairingSync`).

## What Supabase stores

Only **ciphertext**. The trust record — host URL, channel id, the 32-byte
channel key, the host device id and its approved Ed25519 public key — is
serialized to JSON and encrypted client-side with AES-256-GCM by
`EncryptionService` before upload. The key is the per-user key already used for
chat: derived from the user's password with PBKDF2-HMAC-SHA256 (600k iterations)
over a salt held in `auth.users.user_metadata`. Supabase never sees the salt-
derived key or the plaintext. A leaked anon key, a database dump, or a Supabase
admin all see only an opaque blob.

The ciphertext value is the JSON envelope produced by `EncryptionService.encrypt`:
`{"v":"1","kv":<int>,"nonce":"<b64>","ciphertext":"<b64>","mac":"<b64>"}`.

## Table

One row per user. The user id is the primary key, so a re-pair overwrites the
previous mirror (last-writer-wins).

```sql
create table if not exists public.cowork_pairings (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  ciphertext text        not null,
  updated_at timestamptz not null default now(),
  primary key (user_id)
);
```

| column       | type          | notes                                                        |
| ------------ | ------------- | ------------------------------------------------------------ |
| `user_id`    | `uuid`        | PK. Owner; FK to `auth.users`. `on delete cascade`.          |
| `ciphertext` | `text`        | AES-256-GCM envelope JSON. Never plaintext.                  |
| `updated_at` | `timestamptz` | Last write. Set by the client on every upsert.               |

## Row-Level Security

RLS must be **on**. Every row is readable and writable only by its owner. With
no policy granting cross-user access, a signed-in client can touch exactly one
row: its own.

```sql
alter table public.cowork_pairings enable row level security;

-- Read your own row.
create policy "cowork_pairings_select_own"
  on public.cowork_pairings
  for select
  using (auth.uid() = user_id);

-- Insert only a row owned by you.
create policy "cowork_pairings_insert_own"
  on public.cowork_pairings
  for insert
  with check (auth.uid() = user_id);

-- Update only your row, and you cannot reassign it to someone else.
create policy "cowork_pairings_update_own"
  on public.cowork_pairings
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Delete your row (the "un-pair / forget" action).
create policy "cowork_pairings_delete_own"
  on public.cowork_pairings
  for delete
  using (auth.uid() = user_id);
```

Grants (Supabase's `authenticated` role; RLS still filters every statement):

```sql
grant select, insert, update, delete on public.cowork_pairings to authenticated;
```

The client upserts with `on_conflict = user_id`, so both the `insert` and
`update` policies must be present for a re-pair to succeed.

## Client access pattern

- Save: `upsert({user_id, ciphertext, updated_at}, onConflict: user_id)` after a
  successful pairing. Best-effort; failures are swallowed so offline pairing
  still works.
- Load: `select(ciphertext).eq(user_id, <uid>).maybeSingle()` on a fresh
  install, then decrypt. Returns nothing usable unless the same user is signed
  in and the encryption key is unlocked (password entered).
- Clear: `delete().eq(user_id, <uid>)` on un-pair.

## Security note (business risk)

Encryption is client-side and password-derived on purpose. If it were server-
readable, a Supabase breach would hand an attacker a live channel key and host
URL, i.e. a working session against the user's own machine. Keeping Supabase to
ciphertext keeps a database leak worthless.

---

# Supabase schema — encrypted MCP connector mirror

The connector half of "reinstall anywhere". The Flutter client mirrors the
user's MCP connector set (the servers they connected, plus the secrets those
servers need) to Supabase, so a fresh install can sign in and pick the same
connectors back up. It works exactly like the pairing mirror above: one row per
user, ciphertext only, owner-only RLS.

The client code that reads and writes this table is
`app/lib/services/mcp/mcp_connector_sync.dart` (`McpConnectorSync`). The local
store it mirrors is `app/lib/services/mcp/mcp_store.dart` (`McpStore`).

## What Supabase stores

Only **ciphertext**. The whole connector set is serialized to one JSON blob and
encrypted client-side with AES-256-GCM by `EncryptionService` — the same per-user
password-derived key as the pairing mirror and the chat payloads. The plaintext
blob is:

```json
{
  "connections": [ { "id": "...", "name": "...", "url": "...", "auth": "oauth",
                     "description": "...", "icon_url": "...", "tools": [] } ],
  "secrets": { "<connection id>": { "token": "<oauth bearer>",
                                    "api_credentials": { "<param>": "<value>" } } }
}
```

The secrets sub-object carries real key material (OAuth bearer tokens, API keys),
which is exactly why the blob is encrypted before it ever reaches Supabase. A
leaked anon key, a database dump, or a Supabase admin all see only an opaque
blob. The stored `ciphertext` value is the same envelope JSON
`EncryptionService.encrypt` produces for the pairing mirror.

## Table

One row per user. The user id is the primary key, so every save overwrites the
previous mirror (last-writer-wins over the whole set).

```sql
create table if not exists public.cowork_mcp_connectors (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  ciphertext text        not null,
  updated_at timestamptz not null default now(),
  primary key (user_id)
);
```

| column       | type          | notes                                                        |
| ------------ | ------------- | ------------------------------------------------------------ |
| `user_id`    | `uuid`        | PK. Owner; FK to `auth.users`. `on delete cascade`.          |
| `ciphertext` | `text`        | AES-256-GCM envelope JSON. Never plaintext.                  |
| `updated_at` | `timestamptz` | Last write. Set by the client on every upsert.               |

## Row-Level Security

RLS must be **on**. Every row is readable and writable only by its owner — the
same owner-only scheme as `cowork_pairings`.

```sql
alter table public.cowork_mcp_connectors enable row level security;

-- Read your own row.
create policy "cowork_mcp_connectors_select_own"
  on public.cowork_mcp_connectors
  for select
  using (auth.uid() = user_id);

-- Insert only a row owned by you.
create policy "cowork_mcp_connectors_insert_own"
  on public.cowork_mcp_connectors
  for insert
  with check (auth.uid() = user_id);

-- Update only your row, and you cannot reassign it to someone else.
create policy "cowork_mcp_connectors_update_own"
  on public.cowork_mcp_connectors
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Delete your row (clearing every connector).
create policy "cowork_mcp_connectors_delete_own"
  on public.cowork_mcp_connectors
  for delete
  using (auth.uid() = user_id);
```

Grants (Supabase's `authenticated` role; RLS still filters every statement):

```sql
grant select, insert, update, delete on public.cowork_mcp_connectors to authenticated;
```

The client upserts with `on_conflict = user_id`, so both the `insert` and
`update` policies must be present.

## Client access pattern

- Save: `upsert({user_id, ciphertext, updated_at}, onConflict: user_id)` after
  every connect / disconnect. Best-effort; failures are swallowed so an offline
  or signed-out client keeps working from its local store.
- Load: `select(ciphertext).eq(user_id, <uid>).maybeSingle()` on start, then
  decrypt and adopt into the local store. Returns nothing usable unless the same
  user is signed in and the encryption key is unlocked (password entered).
- Clear: `delete().eq(user_id, <uid>)` when the last connector is removed.

## Security note (business risk)

Same reasoning as the pairing mirror. The connector blob holds live OAuth tokens
and API keys, so a server-readable copy would hand an attacker working access to
the user's connected third-party accounts (their Stripe, their GitHub, their
mailbox). Client-side, password-derived encryption keeps a database leak
worthless.

---

# Supabase schema — model and system-prompt preferences

`UserPreferencesService` (imported verbatim from chuk_chat) keeps the user's
model choice, the per-model provider choice and the encrypted system prompt in
Supabase, so a fresh install on a new device restores them. Both tables are
optional at runtime: every read and write falls back to the device-local
`ModelCacheService` / `SharedPreferences` copy, so the app works before the
tables exist.

## What Supabase stores

- `selected_model_id` — the model id the user last picked. Plaintext; it is a
  public catalogue id, not user content.
- `system_prompt` — the user's own instructions. **Ciphertext only**, the same
  AES-256-GCM envelope `EncryptionService` uses for chat data.
- `provider_slug` — which provider serves a given model for this user.
  Plaintext; also a public catalogue id.

## Table `user_preferences`

One row per user. The user id is the primary key, so every save overwrites the
previous row (last-writer-wins over the whole set). The client upserts with
`on_conflict = user_id`.

```sql
create table if not exists public.user_preferences (
  user_id           uuid        not null
                    references auth.users (id) on delete cascade,
  selected_model_id text,
  system_prompt     text,
  updated_at        timestamptz not null default now(),
  primary key (user_id)
);
```

| column              | type          | notes                                                          |
| ------------------- | ------------- | -------------------------------------------------------------- |
| `user_id`           | `uuid`        | PK. Owner; FK to `auth.users`. `on delete cascade`.            |
| `selected_model_id` | `text`        | Catalogue model id. Nullable — no choice made yet.             |
| `system_prompt`     | `text`        | AES-256-GCM envelope JSON. Never plaintext. Nullable — cleared. |
| `updated_at`        | `timestamptz` | Last write.                                                    |

### Row-Level Security

RLS must be **on**. Every row is readable and writable only by its owner — the
same owner-only scheme as `cowork_pairings`.

```sql
alter table public.user_preferences enable row level security;

-- Read your own row.
create policy "user_preferences_select_own"
  on public.user_preferences
  for select
  using (auth.uid() = user_id);

-- Insert only a row owned by you.
create policy "user_preferences_insert_own"
  on public.user_preferences
  for insert
  with check (auth.uid() = user_id);

-- Update only your row, and you cannot reassign it to someone else.
create policy "user_preferences_update_own"
  on public.user_preferences
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Delete your row.
create policy "user_preferences_delete_own"
  on public.user_preferences
  for delete
  using (auth.uid() = user_id);
```

Grants (Supabase's `authenticated` role; RLS still filters every statement):

```sql
grant select, insert, update, delete on public.user_preferences to authenticated;
```

## Table `user_model_providers`

One row per (user, model) pair: which provider serves that model for that user.
The client upserts with `on_conflict = user_id,model_id`, so the primary key is
the pair.

```sql
create table if not exists public.user_model_providers (
  user_id       uuid        not null
                references auth.users (id) on delete cascade,
  model_id      text        not null,
  provider_slug text        not null,
  updated_at    timestamptz not null default now(),
  primary key (user_id, model_id)
);
```

| column          | type          | notes                                                   |
| --------------- | ------------- | ------------------------------------------------------- |
| `user_id`       | `uuid`        | PK part 1. Owner; FK to `auth.users`. `on delete cascade`. |
| `model_id`      | `text`        | PK part 2. Catalogue model id.                          |
| `provider_slug` | `text`        | Provider that serves this model for this user.          |
| `updated_at`    | `timestamptz` | Last write.                                             |

### Row-Level Security

Same owner-only scheme.

```sql
alter table public.user_model_providers enable row level security;

-- Read your own rows.
create policy "user_model_providers_select_own"
  on public.user_model_providers
  for select
  using (auth.uid() = user_id);

-- Insert only rows owned by you.
create policy "user_model_providers_insert_own"
  on public.user_model_providers
  for insert
  with check (auth.uid() = user_id);

-- Update only your rows, and you cannot reassign them to someone else.
create policy "user_model_providers_update_own"
  on public.user_model_providers
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Delete your rows (clearing a per-model provider choice).
create policy "user_model_providers_delete_own"
  on public.user_model_providers
  for delete
  using (auth.uid() = user_id);
```

Grants:

```sql
grant select, insert, update, delete on public.user_model_providers to authenticated;
```

## Client access pattern

- Model: `upsert({user_id, selected_model_id}, onConflict: user_id)` on pick;
  `select(selected_model_id).eq(user_id, <uid>).maybeSingle()` on start.
- Provider: `upsert({user_id, model_id, provider_slug}, onConflict:
  'user_id,model_id')`; `delete().eq(user_id).eq(model_id)` to clear one.
- System prompt: encrypted client-side, then written into
  `user_preferences.system_prompt`; cleared with `update({system_prompt: null})`.
- Every call is best-effort. On any failure the service serves the device-local
  cache, so a missing table, an offline client or a locked encryption key never
  blocks the app.

## Security note (business risk)

The system prompt is the user's own writing and can carry names, business
details and credentials they pasted in. Storing it as ciphertext keeps a
database leak worthless, the same reasoning as the pairing and connector
mirrors. The two catalogue ids are deliberately plaintext — they carry no user
content, and keeping them readable lets a query fix a bad model rollout without
touching anything private.

---

# Completion notifications (docs/WIRE_CONTRACT.md, P7)

Two tables. The host writes the notification row with the user's own token;
the Edge Function `notify-run` (supabase/functions/notify-run) pushes it to the
user's registered devices. RLS is the authorization on both; no service-role key
is used. The rows carry no answer content.

## `cowork_device_tokens`

```sql
create table if not exists public.cowork_device_tokens (
  user_id    uuid        not null references auth.users (id) on delete cascade,
  device_id  text        not null,      -- stable per app install (the CoWork device id)
  token      text        not null,      -- FCM registration token
  platform   text        not null,      -- 'android' | 'ios' | 'linux'
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
alter table public.cowork_device_tokens enable row level security;
create policy cowork_device_tokens_select_own on public.cowork_device_tokens
  for select to authenticated using (auth.uid() = user_id);
create policy cowork_device_tokens_insert_own on public.cowork_device_tokens
  for insert to authenticated with check (auth.uid() = user_id);
create policy cowork_device_tokens_update_own on public.cowork_device_tokens
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy cowork_device_tokens_delete_own on public.cowork_device_tokens
  for delete to authenticated using (auth.uid() = user_id);
grant select, insert, update, delete on public.cowork_device_tokens to authenticated;
```

The app upserts `{user_id, device_id, token, platform}` on sign-in and on
`onTokenRefresh`, and deletes its row on sign-out. The function deletes a row
whose token FCM reports as `UNREGISTERED` (a reinstall), so the table heals.

## `cowork_run_notifications`

```sql
create table if not exists public.cowork_run_notifications (
  id           uuid        primary key default gen_random_uuid(),
  user_id      uuid        not null references auth.users (id) on delete cascade,
  run_id       text        not null,    -- host-generated, unique per run
  agent_id     text        not null,
  agent_name   text        not null default '',
  session_key  text        not null,    -- which thread to open on tap
  kind         text        not null,    -- 'completed' | 'failed' | 'approval_needed'
  title        text        not null,    -- generic, no answer content
  body         text        not null default '',
  preview_ciphertext text,              -- reserved (channel-key sealed preview)
  created_at   timestamptz not null default now(),
  pushed_at    timestamptz,
  consumed_at  timestamptz,
  unique (user_id, run_id, kind)        -- the dedup guarantee
);
create index if not exists idx_cowork_run_notifications_open
  on public.cowork_run_notifications (user_id, created_at desc)
  where consumed_at is null;
alter table public.cowork_run_notifications enable row level security;
create policy cowork_run_notifications_select_own on public.cowork_run_notifications
  for select to authenticated using (auth.uid() = user_id);
create policy cowork_run_notifications_insert_own on public.cowork_run_notifications
  for insert to authenticated with check (auth.uid() = user_id);
create policy cowork_run_notifications_update_own on public.cowork_run_notifications
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy cowork_run_notifications_delete_own on public.cowork_run_notifications
  for delete to authenticated using (auth.uid() = user_id);
grant select, insert, update, delete on public.cowork_run_notifications to authenticated;
```

## Access pattern

- Host (`cowork_host.notify.SupabaseNotifier`): `POST /rest/v1/cowork_run_notifications`
  with `Prefer: return=representation,resolution=ignore-duplicates` (a retry is a
  no-op), then `POST /functions/v1/notify-run {"notification_id"}`. On 401 the host
  refreshes its session once and retries; a failed delivery waits in a bounded
  outbox and is retried when the app re-provisions.
- Function: reads the row (RLS → the caller's own), skips when `pushed_at` is
  set, pushes to every device row of the caller, sets `pushed_at`.
- App: on a tap or on reconnect it opens the thread, replays it from the host,
  and sets `consumed_at`.

## Edge Function secrets

`FCM_PROJECT_ID` and `FCM_SERVICE_ACCOUNT` (the service-account JSON with the
`firebase.messaging` scope), set with `supabase secrets set`. Without them the
function still marks the row `pushed_at` and returns `sent: 0` — the desktop
channel and the "answer ready" state on reconnect do not depend on it.

## Security note (business risk)

The push carries a generic title and body only. A leaked table, a leaked FCM
payload or a Google-side log never contains a prompt, an answer or a tool
result; those stay end-to-end between the host and the paired app. The FCM
sender identity is bound to the APK, not to the user's Supabase project: a
self-hoster either uses the shipped Firebase project (the payload has no
content) or rebuilds the app with their own `google-services.json`.

---

# CoWork threads — `cowork_chats` (bead cowork-sha)

The chat rows. CoWork stores a thread the way chuk_chat stores a chat: the
verbatim chuk_chat storage modules (`chat_storage_crud/sync/mutations/sidebar`,
`chat_preload_service`, `chat_sync_service`, `local_chat_cache_native`) are
imported unchanged, with one mechanical rewrite in `scripts/import_chat_ui.sh`:
the table name `encrypted_chats` becomes `cowork_chats`. The DDL is in
`supabase/migrations/20260905000000_cowork_chats.sql`; run it once in the
project's SQL editor.

Three copies of every thread, in this order of authority:

1. **The Python host** (`agent/src/cowork_agent/state.py`) — the truth. The
   app asks for a replay with its cursor (`after_id`, docs/WIRE_CONTRACT.md)
   and folds the answer into the copies below.
2. **The local SQLite cache** (`chat_cache.db` under the app-support
   directory, plaintext gzip rows, same file chuk_chat uses) — what a thread
   paints from the moment it opens, before the host answers.
3. **This table** — encrypted, so a reinstall on another device paints from
   the cloud before the host has been paired again, and `ChatSyncService`
   (30 s poll on `id, updated_at`) pulls what another device wrote.

The write path is `app/lib/services/storage/cowork_chat_store.dart`: memory,
then the SQLite row, then an `upsert` here on `(user_id, id)`, best-effort.
Reads and the sidebar go through the chuk_chat modules unchanged
(`loadFullChat` is cache-first).

## What Supabase stores

Only **ciphertext** for content. `encrypted_payload` is the AES-256-GCM
envelope of `{"v": 2, "messages": [...], "customName"?}`; `encrypted_title`
is the first user line, encrypted separately so the sidebar can list threads
without decrypting payloads. Both use the same per-user password-derived key
as the pairing and connector mirrors (`EncryptionService`). The row id is the
executor's `session_key` in plaintext: it is a routing key, not user content.

## Why not `encrypted_chats`

- `encrypted_chats.id` is a `uuid`; a session key (`default`, an agent id) is
  not one.
- CoWork and chuk_chat share this Supabase project. A shared table would list
  every CoWork thread in chuk_chat's chat sidebar and let either app delete
  the other's rows.

## Table

```sql
create table if not exists public.cowork_chats (
  id                text        not null,      -- executor session_key
  user_id           uuid        not null references auth.users (id) on delete cascade,
  encrypted_payload text        not null,      -- AES-256-GCM envelope JSON
  encrypted_title   text,                      -- AES-256-GCM envelope JSON
  image_paths       text[],                    -- reserved, as in encrypted_chats
  is_starred        boolean     not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (user_id, id)
);
create index if not exists idx_cowork_chats_user_updated
  on public.cowork_chats (user_id, updated_at desc);
```

A `before update` trigger bumps `updated_at` when the client did not, so a
star or rename (chuk_chat's `update … eq id`) re-orders the thread the same
way it does in chuk_chat.

## Row-Level Security

RLS on, owner-only, the same four policies as every other CoWork table:

```sql
alter table public.cowork_chats enable row level security;
create policy cowork_chats_select_own on public.cowork_chats
  for select to authenticated using ((select auth.uid()) = user_id);
create policy cowork_chats_insert_own on public.cowork_chats
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy cowork_chats_update_own on public.cowork_chats
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy cowork_chats_delete_own on public.cowork_chats
  for delete to authenticated using ((select auth.uid()) = user_id);
grant select, insert, update, delete on public.cowork_chats to authenticated;
```

## Client access pattern

- Host replay committed → `CoworkChatStore.replaceThread(sessionKey, rows)`:
  `upsert({id, user_id, encrypted_payload, encrypted_title, updated_at},
  onConflict: 'user_id,id')`, then the server's `created_at`/`updated_at`
  are adopted locally so the sync's "cloud newer?" check compares like with
  like. Fails silently: the SQLite row already holds the thread.
- The imported screen's own persist after a live turn → chuk_chat's
  `ChatStorageCrud.saveChat` (insert) / `updateChat` (update), unchanged.
- Sidebar → `select('id, encrypted_title, created_at, is_starred,
  updated_at')`; a thread → `loadFullChat` (SQLite first, then this table).
- Sync → every 30 s `select('id, updated_at')`, fetch the new/changed rows,
  decrypt in an isolate, merge, refresh the SQLite rows. A row deleted here
  is removed locally and its replay cursor is dropped, so the next open asks
  the host for the full thread again (the host stays the truth).
- Star / rename / delete / export → chuk_chat's mutations, unchanged.

## Security note (business risk)

Same reasoning as the other mirrors: a transcript can carry anything the user
pasted into a task. Ciphertext keeps a database leak worthless. The session
key is plaintext on purpose — it is what the sync compares and what the app
needs to route a row to a thread, and it carries no content.

---

# CoWork secrets — `cowork_secrets` (docs/WIRE_CONTRACT.md, "Secrets")

The user's API keys, the way the agent uses them without ever seeing them.
The device keeps the set in secure storage (`SecretsStore`,
`app/lib/services/secrets/secrets_store.dart`) and mirrors it here so a
fresh install on another device pulls it back, signs in, and forwards it to
the host on its first provision. The host holds its own encrypted copy at
rest (`~/.cowork/secrets.enc`); this table is the cross-device copy.

The DDL is `supabase/migrations/20260905120000_cowork_secrets.sql`; run it
once in the project's SQL editor.

## What Supabase stores

One row per name. `name` is plaintext on purpose: it is a label in the
style of an environment variable (`PEXELS_API_KEY`), and the sync needs to
compare names without decrypting. `ciphertext` is the value as an
`EncryptionService` envelope — the same per-user password-derived
AES-256-GCM key as every other CoWork mirror. A leaked anon key, a dump or
an admin see the names and opaque blobs.

## Table

```sql
create table if not exists public.cowork_secrets (
  user_id    uuid        not null references auth.users (id) on delete cascade,
  name       text        not null,      -- env-style label, plaintext
  ciphertext text        not null,      -- AES-256-GCM envelope JSON of the value
  updated_at timestamptz not null default now(),
  primary key (user_id, name),
  constraint cowork_secrets_name_shape check (name ~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$')
);
```

## Row-Level Security

RLS on, owner-only, the same four policies as every other CoWork table
(`cowork_secrets_{select,insert,update,delete}_own` on `auth.uid() =
user_id`), plus the grant to `authenticated`. See the migration.

## Client access pattern

- Set / change: `upsert({user_id, name, ciphertext, updated_at},
  onConflict: 'user_id,name')` after the local write. Best-effort.
- Delete: `delete().eq(user_id).eq(name)`.
- Load: `select('name, ciphertext')` on start when the local store is
  empty (a reinstall); decrypt each value, adopt into secure storage.
- After every local change the app forwards the WHOLE set to the host as
  one `secrets` frame (docs/WIRE_CONTRACT.md).

## Security note (business risk)

A key here is a live credential for a third-party account the user pays
for (an image API, an LLM provider, a mail server). Client-side encryption
keeps a database leak worthless; the host never writes a value to a log, a
transcript or a workspace file, and the model only ever sees
`[REDACTED:<NAME>]`. Values shorter than 8 characters are stored and
injected like any other but are NOT masked in outputs (too short to be a
real key, too likely to collide with ordinary text) — the settings page
says so next to the value field.
