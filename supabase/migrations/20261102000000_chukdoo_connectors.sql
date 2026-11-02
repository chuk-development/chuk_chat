-- The encrypted cloud copy of the built-in Chukdoo connector
-- (lib/services/chukdoo/chukdoo_connector_sync.dart). One row per user. The
-- client upserts an AES-256-GCM envelope made with the user's chuk_chat key;
-- the plaintext (a chukdoo device token and the chukdoo data key, or a
-- tombstone after a disconnect) never reaches the server. Every install of
-- the account reads it, so the connector is paired once for all of them.
create table if not exists public.chukdoo_connectors (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  ciphertext text        not null,
  updated_at timestamptz not null default now(),
  primary key (user_id)
);

alter table public.chukdoo_connectors enable row level security;

drop policy if exists chukdoo_connectors_select_own on public.chukdoo_connectors;
create policy chukdoo_connectors_select_own on public.chukdoo_connectors
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists chukdoo_connectors_insert_own on public.chukdoo_connectors;
create policy chukdoo_connectors_insert_own on public.chukdoo_connectors
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists chukdoo_connectors_update_own on public.chukdoo_connectors;
create policy chukdoo_connectors_update_own on public.chukdoo_connectors
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists chukdoo_connectors_delete_own on public.chukdoo_connectors;
create policy chukdoo_connectors_delete_own on public.chukdoo_connectors
  for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on public.chukdoo_connectors from anon;
grant select, insert, update, delete on public.chukdoo_connectors to authenticated;
