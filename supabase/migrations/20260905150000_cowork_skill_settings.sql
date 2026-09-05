-- CoWork skill switches: which of the host's skills the user turned off
-- (docs/WIRE_CONTRACT.md "Skills").
--
-- The host keeps the truth in its own state database (skill_settings). The
-- app mirrors every switch here so a reinstalled app, or a host whose state
-- database was reset, gets the user's choices back from the account. A skill
-- name is a label (`youtube-transcript`), not a secret, so the row is
-- plaintext. Owner-only RLS, the same scheme as every CoWork table.
--
-- Run once in the Supabase SQL editor (or `supabase db push`). The app runs
-- without the table: the mirror is best-effort, a failed read or write is
-- logged and the host list still works.

create table if not exists public.cowork_skill_settings (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  name       text        not null,
  enabled    boolean     not null default true,
  updated_at timestamptz not null default now(),
  primary key (user_id, name),
  constraint cowork_skill_settings_name_shape
    check (name ~ '^[a-z0-9][a-z0-9._-]{0,63}$')
);

comment on column public.cowork_skill_settings.name is
  'The SKILL.md frontmatter name on the host. Plaintext: it is a label, not a secret.';
comment on column public.cowork_skill_settings.enabled is
  'false = the user switched the skill off; the agent does not get it.';

alter table public.cowork_skill_settings enable row level security;

drop policy if exists cowork_skill_settings_select_own on public.cowork_skill_settings;
create policy cowork_skill_settings_select_own on public.cowork_skill_settings
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists cowork_skill_settings_insert_own on public.cowork_skill_settings;
create policy cowork_skill_settings_insert_own on public.cowork_skill_settings
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists cowork_skill_settings_update_own on public.cowork_skill_settings;
create policy cowork_skill_settings_update_own on public.cowork_skill_settings
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists cowork_skill_settings_delete_own on public.cowork_skill_settings;
create policy cowork_skill_settings_delete_own on public.cowork_skill_settings
  for delete to authenticated using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.cowork_skill_settings to authenticated;
