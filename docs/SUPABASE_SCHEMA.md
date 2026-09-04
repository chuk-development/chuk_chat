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
