-- The encrypted MCP connector mirror (docs/SUPABASE_SCHEMA.md). The client
-- (lib/services/mcp/mcp_connector_sync.dart) upserts one AES-256-GCM envelope
-- per user. The schema lived only in the docs; production never got the table.
create table if not exists public.cowork_mcp_connectors (
  user_id    uuid        not null
             references auth.users (id) on delete cascade,
  ciphertext text        not null,
  updated_at timestamptz not null default now(),
  primary key (user_id)
);

alter table public.cowork_mcp_connectors enable row level security;

drop policy if exists agents_mcp_connectors_select_own on public.cowork_mcp_connectors;
create policy agents_mcp_connectors_select_own on public.cowork_mcp_connectors
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists agents_mcp_connectors_insert_own on public.cowork_mcp_connectors;
create policy agents_mcp_connectors_insert_own on public.cowork_mcp_connectors
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists agents_mcp_connectors_update_own on public.cowork_mcp_connectors;
create policy agents_mcp_connectors_update_own on public.cowork_mcp_connectors
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists agents_mcp_connectors_delete_own on public.cowork_mcp_connectors;
create policy agents_mcp_connectors_delete_own on public.cowork_mcp_connectors
  for delete to authenticated using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.cowork_mcp_connectors to authenticated;
