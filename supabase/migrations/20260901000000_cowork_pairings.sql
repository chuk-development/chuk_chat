-- The encrypted pairing mirror (lib/services/agents/supabase_pairing_sync.dart):
-- one AES-256-GCM envelope per user, so a fresh install restores the pairing
-- after sign-in. The table existed in production with no migration; this file
-- records it exactly as deployed (owner-only RLS). Idempotent.
create table if not exists public.cowork_pairings (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  ciphertext text        not null,
  updated_at timestamptz not null default now(),
  primary key (user_id)
);

alter table public.cowork_pairings enable row level security;

drop policy if exists cowork_pairings_select_own on public.cowork_pairings;
create policy cowork_pairings_select_own on public.cowork_pairings
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists cowork_pairings_insert_own on public.cowork_pairings;
create policy cowork_pairings_insert_own on public.cowork_pairings
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists cowork_pairings_update_own on public.cowork_pairings;
create policy cowork_pairings_update_own on public.cowork_pairings
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists cowork_pairings_delete_own on public.cowork_pairings;
create policy cowork_pairings_delete_own on public.cowork_pairings
  for delete to authenticated using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.cowork_pairings to authenticated;
