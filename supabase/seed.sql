-- ============================================================
-- Local E2E seed. Runs ONLY against the local Supabase stack
-- (scripts/e2e_stack.sh, `supabase db reset --local`). Never run it
-- against production. See docs/E2E_STACK.md.
--
-- Test user:  e2e@example.test / E2eTest-Passw0rd
-- Fixed id:   00000000-0000-4000-8000-0000000000e2
--
-- The app creates the encryption salt (user_metadata.chat_kdf_salt) and
-- the key version on the first sign-in, so the seed leaves the metadata
-- empty. Theme, customization and other settings rows are upserted by the
-- app on demand.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- GoTrue reads the token columns as strings: NULL there breaks sign-in
-- ("converting NULL to string is unsupported"), so they are ''.
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, recovery_token,
  email_change_token_new, email_change, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token,
  is_sso_user, is_anonymous
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-4000-8000-0000000000e2',
  'authenticated', 'authenticated',
  'e2e@example.test',
  extensions.crypt('E2eTest-Passw0rd', extensions.gen_salt('bf')),
  now(), NULL,
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(), now(),
  '', '', '', '', '', '', '', '',
  false, false
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.identities (
  id, provider_id, user_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at
) VALUES (
  '00000000-0000-4000-8000-0000000001e2',
  '00000000-0000-4000-8000-0000000000e2',
  '00000000-0000-4000-8000-0000000000e2',
  jsonb_build_object(
    'sub', '00000000-0000-4000-8000-0000000000e2',
    'email', 'e2e@example.test',
    'email_verified', true,
    'phone_verified', false
  ),
  'email',
  now(), now(), now()
)
ON CONFLICT (provider_id, provider) DO NOTHING;

-- Production creates the profile on sign-up. The insert also fires
-- trigger_set_default_model, which writes the default user_preferences
-- and user_model_providers rows.
INSERT INTO public.profiles (id, display_name)
VALUES ('00000000-0000-4000-8000-0000000000e2', 'E2E Test')
ON CONFLICT (id) DO NOTHING;

-- Skip the first-run onboarding so tests land in the chat.
INSERT INTO public.customization_preferences (user_id, onboarding_completed)
VALUES ('00000000-0000-4000-8000-0000000000e2', true)
ON CONFLICT (user_id) DO UPDATE SET onboarding_completed = true;
