-- CHAT-128: the sealed answer preview of a push, and UnifiedPush devices.
--
-- docs/agents/NOTIFICATIONS.md is the contract.
--
-- 1. `cowork_run_notifications.preview_sealed` (jsonb): {channel_id: sealed}.
--    The host seals the answer preview once per stored pairing (AES-256-GCM
--    under a key from the pairing's channel key). Supabase and FCM see only
--    ciphertext. `title` and `body` stay generic as the fallback.
-- 2. `cowork_run_notifications.consumed_at`: the app PATCHes it after it
--    opened the thread. The first migration (20260910050000) did not create
--    it.
-- 3. `cowork_device_tokens.platform` also allows 'unifiedpush'. Then `token`
--    is the endpoint URL of the phone's UnifiedPush distributor.
--
-- Idempotent. Apply through the Management API query endpoint
-- (docs/DATABASE.md), not with `supabase db push`.

alter table public.cowork_run_notifications
  add column if not exists preview_sealed jsonb;

alter table public.cowork_run_notifications
  add column if not exists consumed_at timestamptz;

comment on column public.cowork_run_notifications.preview_sealed is
  'The answer preview, sealed per pairing: {channel_id: base64(nonce || AES-256-GCM ciphertext || tag)}. Only the paired app can open it.';
comment on column public.cowork_run_notifications.consumed_at is
  'Set by the app when it opened the thread of this notification.';

alter table public.cowork_device_tokens
  drop constraint if exists cowork_device_tokens_platform_shape;

alter table public.cowork_device_tokens
  add constraint cowork_device_tokens_platform_shape
  check (platform in ('android', 'ios', 'web', 'linux', 'macos', 'windows', 'unifiedpush'));

comment on column public.cowork_device_tokens.token is
  'The FCM registration token, or for platform unifiedpush the distributor endpoint URL. Never a secret of the user''s.';
