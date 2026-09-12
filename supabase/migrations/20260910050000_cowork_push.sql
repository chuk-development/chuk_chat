-- CoWork push: the run notification the host writes, and the device it goes to.
--
-- Both tables were used by code that shipped and by
-- `supabase/functions/notify-run`, and neither was ever created. The host
-- therefore POSTed every completion to a table that does not exist and logged
--
--   notify: cloud delivery failed: HTTPStatusError: Client error '404 Not Found'
--   for url '.../rest/v1/cowork_run_notifications'
--
-- so the phone never got a push when a run finished while the app was away —
-- exactly the case the notification exists for (bead cowork-b55k).
--
-- Owner-only RLS, the same scheme as every other CoWork table. Run once in the
-- Supabase SQL editor, or `supabase db push`.

-- ---------------------------------------------------------------- devices

create table if not exists public.cowork_device_tokens (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  device_id  text        not null,
  token      text        not null,
  platform   text        not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id),
  constraint cowork_device_tokens_platform_shape
    check (platform in ('android', 'ios', 'web', 'linux', 'macos', 'windows'))
);

comment on table public.cowork_device_tokens is
  'One row per signed-in device: where a push for this user can be delivered.';
comment on column public.cowork_device_tokens.device_id is
  'The app''s own stable id for the install. The upsert key, with user_id.';
comment on column public.cowork_device_tokens.token is
  'The FCM registration token. Rotated by onTokenRefresh; never a secret of the user''s.';

alter table public.cowork_device_tokens enable row level security;

drop policy if exists cowork_device_tokens_select_own on public.cowork_device_tokens;
create policy cowork_device_tokens_select_own on public.cowork_device_tokens
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists cowork_device_tokens_insert_own on public.cowork_device_tokens;
create policy cowork_device_tokens_insert_own on public.cowork_device_tokens
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists cowork_device_tokens_update_own on public.cowork_device_tokens;
create policy cowork_device_tokens_update_own on public.cowork_device_tokens
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists cowork_device_tokens_delete_own on public.cowork_device_tokens;
create policy cowork_device_tokens_delete_own on public.cowork_device_tokens
  for delete to authenticated using ((select auth.uid()) = user_id);

-- ---------------------------------------------------- run notifications

create table if not exists public.cowork_run_notifications (
  id          uuid        not null default gen_random_uuid(),
  user_id     uuid        not null
              references auth.users (id) on delete cascade,
  run_id      text        not null,
  agent_id    text        not null,
  agent_name  text        not null,
  session_key text        not null,
  kind        text        not null,
  title       text        not null,
  body        text        not null,
  created_at  timestamptz not null default now(),
  pushed_at   timestamptz,
  primary key (id),
  -- One notification per run: the host retries a failed delivery from its own
  -- outbox, and a retry must not become a second push.
  constraint cowork_run_notifications_run_once unique (user_id, run_id)
);

comment on table public.cowork_run_notifications is
  'A finished run the user was not watching. Carries labels only: no prompt, no answer, no tool output.';
comment on column public.cowork_run_notifications.kind is
  'What ended: a normal run, a fired automation, a run that needs an approval.';
comment on column public.cowork_run_notifications.pushed_at is
  'Set by the notify-run function once it has handed the row to FCM. Its own idempotency guard.';

create index if not exists cowork_run_notifications_pending_idx
  on public.cowork_run_notifications (user_id, created_at desc)
  where pushed_at is null;

alter table public.cowork_run_notifications enable row level security;

drop policy if exists cowork_run_notifications_select_own on public.cowork_run_notifications;
create policy cowork_run_notifications_select_own on public.cowork_run_notifications
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists cowork_run_notifications_insert_own on public.cowork_run_notifications;
create policy cowork_run_notifications_insert_own on public.cowork_run_notifications
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists cowork_run_notifications_update_own on public.cowork_run_notifications;
create policy cowork_run_notifications_update_own on public.cowork_run_notifications
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists cowork_run_notifications_delete_own on public.cowork_run_notifications;
create policy cowork_run_notifications_delete_own on public.cowork_run_notifications
  for delete to authenticated using ((select auth.uid()) = user_id);
