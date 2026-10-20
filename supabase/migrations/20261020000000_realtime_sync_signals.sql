-- Cross-device realtime sync signals ("Option B").
--
-- A row change on one of the tables below sends a tiny broadcast on the
-- private topic `user:<uid>`: event `changed`, payload {t: table, op, id}.
-- The signal never carries row data. The client
-- (lib/services/user_sync_signal_service.dart) reacts by running the pull
-- that already exists for the table; the 30 s polls stay as the fallback.
--
-- user_preferences / user_model_providers keep their postgres_changes
-- subscription (user_model_prefs_realtime_service.dart) and are not touched.

-- 1. Trigger function --------------------------------------------------------

create or replace function public.notify_user_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  rec jsonb;
  uid text;
begin
  begin
    if tg_op = 'DELETE' then
      rec := to_jsonb(old);
    else
      rec := to_jsonb(new);
    end if;
    uid := rec ->> 'user_id';
    if uid is not null then
      perform realtime.send(
        jsonb_build_object(
          't', tg_table_name,
          'op', tg_op,
          -- agents_chat_pins has no `id` (its key is user_id + item_id);
          -- user_billing has neither, so it sends null.
          'id', coalesce(rec ->> 'id', rec ->> 'item_id')
        ),
        'changed',
        'user:' || uid,
        true
      );
    end if;
  exception when others then
    -- A signal is best effort: it must never break the write.
    null;
  end;
  return null;
end;
$$;

revoke all on function public.notify_user_change() from public, anon, authenticated;

-- 2. Triggers ----------------------------------------------------------------

-- encrypted_chats: inserts and deletes always; updates only when a column
-- the other devices show changes (a no-op upsert sends nothing).
drop trigger if exists encrypted_chats_notify_user_change on public.encrypted_chats;
drop trigger if exists encrypted_chats_notify_user_change_upd on public.encrypted_chats;
create trigger encrypted_chats_notify_user_change
  after insert or delete on public.encrypted_chats
  for each row execute function public.notify_user_change();
create trigger encrypted_chats_notify_user_change_upd
  after update on public.encrypted_chats
  for each row
  when (
    old.updated_at is distinct from new.updated_at
    or old.encrypted_title is distinct from new.encrypted_title
    or old.encrypted_payload is distinct from new.encrypted_payload
    or old.is_starred is distinct from new.is_starred
    or old.image_paths is distinct from new.image_paths
  )
  execute function public.notify_user_change();

-- cowork_chats: same rule. Note: cowork_chats_touch_updated_at bumps
-- updated_at on every update, so in practice every update fires; the client
-- debounces.
drop trigger if exists cowork_chats_notify_user_change on public.cowork_chats;
drop trigger if exists cowork_chats_notify_user_change_upd on public.cowork_chats;
create trigger cowork_chats_notify_user_change
  after insert or delete on public.cowork_chats
  for each row execute function public.notify_user_change();
create trigger cowork_chats_notify_user_change_upd
  after update on public.cowork_chats
  for each row
  when (
    old.updated_at is distinct from new.updated_at
    or old.encrypted_title is distinct from new.encrypted_title
    or old.encrypted_payload is distinct from new.encrypted_payload
    or old.is_starred is distinct from new.is_starred
    or old.image_paths is distinct from new.image_paths
  )
  execute function public.notify_user_change();

drop trigger if exists agents_chat_pins_notify_user_change on public.agents_chat_pins;
create trigger agents_chat_pins_notify_user_change
  after insert or update or delete on public.agents_chat_pins
  for each row execute function public.notify_user_change();

drop trigger if exists user_billing_notify_user_change on public.user_billing;
create trigger user_billing_notify_user_change
  after insert or update or delete on public.user_billing
  for each row execute function public.notify_user_change();

-- 3. Who may receive the signals -------------------------------------------

-- An authenticated user may join only their own private topic, broadcast
-- only. No insert policy: clients cannot send on these topics.
drop policy if exists "user_sync_signal_read_own_topic" on realtime.messages;
create policy "user_sync_signal_read_own_topic"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.topic() = 'user:' || (select auth.uid())::text
    and realtime.messages.extension = 'broadcast'
  );
