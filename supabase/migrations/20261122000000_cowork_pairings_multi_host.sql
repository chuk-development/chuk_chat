-- CHAT-177: several computers per account (docs/agents/MULTI_HOST.md).
--
-- The encrypted pairing mirror held one row per user. It now holds one row
-- per user AND computer: `host_id` is the host's relay device id (the uuid4
-- in `cw_device`). The ciphertext stays per row, sealed with the account key.
--
-- Existing rows get `host_id = 'legacy'`. The app re-keys such a row once it
-- has decrypted it: it writes the row again under the real host id and then
-- deletes the legacy row (lib/services/agents/supabase_pairing_sync.dart).
--
-- The RLS policies check only `user_id`, so they stay as they are.
-- Idempotent.

alter table public.cowork_pairings
  add column if not exists host_id text not null default 'legacy';

do $$
declare
  pk_name text;
  pk_cols text[];
begin
  select c.conname,
         array_agg(a.attname::text order by a.attnum)
    into pk_name, pk_cols
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
   where c.conrelid = 'public.cowork_pairings'::regclass
     and c.contype = 'p'
   group by c.conname;

  if pk_cols is distinct from array['user_id', 'host_id'] then
    if pk_name is not null then
      execute format(
        'alter table public.cowork_pairings drop constraint %I', pk_name
      );
    end if;
    alter table public.cowork_pairings
      add constraint cowork_pairings_pkey primary key (user_id, host_id);
  end if;
end
$$;
