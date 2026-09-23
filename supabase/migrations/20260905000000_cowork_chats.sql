-- CoWork threads, stored the way chuk_chat stores chats (bead cowork-sha).
--
-- Same columns and the same owner-only RLS as chuk_chat's `encrypted_chats`.
-- Two differences, both deliberate:
--   * `id` is `text`, not `uuid`: the row id is the executor's `session_key`
--     (the agent's thread key), which is not a UUID.
--   * the primary key is `(user_id, id)`: the client upserts on that pair.
-- A separate table keeps CoWork threads out of chuk_chat's sidebar (both apps
-- share this Supabase project) and lets each app delete on its own terms.
--
-- Run once in the Supabase SQL editor (or `supabase db push`).

create table if not exists public.cowork_chats (
  id                text        not null,
  user_id           uuid        not null
                    references auth.users (id) on delete cascade,
  encrypted_payload text        not null,
  encrypted_title   text,
  image_paths       text[],
  is_starred        boolean     not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (user_id, id)
);

comment on column public.cowork_chats.id is
  'The CoWork executor session_key (agent thread key). Not a UUID.';
comment on column public.cowork_chats.encrypted_payload is
  'AES-256-GCM envelope JSON of {"v":2,"messages":[...],"customName"?}. Never plaintext.';
comment on column public.cowork_chats.encrypted_title is
  'Separately encrypted title for the sidebar, as in encrypted_chats.';

create index if not exists idx_cowork_chats_user_updated
  on public.cowork_chats (user_id, updated_at desc);

-- `updated_at` is set by the client on every upsert; keep a server-side
-- guard so a plain UPDATE (star, rename) bumps it too, like encrypted_chats.
create or replace function public.cowork_chats_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  if new.updated_at is null or new.updated_at = old.updated_at then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists cowork_chats_touch_updated_at on public.cowork_chats;
create trigger cowork_chats_touch_updated_at
  before update on public.cowork_chats
  for each row execute function public.cowork_chats_touch_updated_at();

alter table public.cowork_chats enable row level security;

drop policy if exists cowork_chats_select_own on public.cowork_chats;
create policy cowork_chats_select_own on public.cowork_chats
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists cowork_chats_insert_own on public.cowork_chats;
create policy cowork_chats_insert_own on public.cowork_chats
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists cowork_chats_update_own on public.cowork_chats;
create policy cowork_chats_update_own on public.cowork_chats
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists cowork_chats_delete_own on public.cowork_chats;
create policy cowork_chats_delete_own on public.cowork_chats
  for delete to authenticated using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.cowork_chats to authenticated;
