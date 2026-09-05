-- CoWork secrets: the user's API keys, one row per name, ciphertext only
-- (docs/WIRE_CONTRACT.md "Secrets", docs/SUPABASE_SCHEMA.md).
--
-- The app keeps the set in secure storage and mirrors it here so a fresh
-- install on another device can pull it back and forward it to the host.
-- Every value is an EncryptionService envelope (AES-256-GCM under the
-- user's password-derived key). Supabase, an admin or a dump see only
-- opaque blobs. Owner-only RLS, the same scheme as every CoWork table.
--
-- Run once in the Supabase SQL editor (or `supabase db push`).

create table if not exists public.cowork_secrets (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  name       text        not null,
  ciphertext text        not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, name),
  constraint cowork_secrets_name_shape
    check (name ~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$')
);

comment on column public.cowork_secrets.name is
  'Environment-variable style name (PEXELS_API_KEY). Plaintext: it is a label, not a secret.';
comment on column public.cowork_secrets.ciphertext is
  'AES-256-GCM envelope JSON of the value, encrypted client-side. Never plaintext.';

alter table public.cowork_secrets enable row level security;

drop policy if exists cowork_secrets_select_own on public.cowork_secrets;
create policy cowork_secrets_select_own on public.cowork_secrets
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists cowork_secrets_insert_own on public.cowork_secrets;
create policy cowork_secrets_insert_own on public.cowork_secrets
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists cowork_secrets_update_own on public.cowork_secrets;
create policy cowork_secrets_update_own on public.cowork_secrets
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists cowork_secrets_delete_own on public.cowork_secrets;
create policy cowork_secrets_delete_own on public.cowork_secrets
  for delete to authenticated using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.cowork_secrets to authenticated;
