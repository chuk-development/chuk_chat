-- Migration: add identity sync columns to user_preferences
-- Run in Supabase SQL Editor.

BEGIN;

ALTER TABLE public.user_preferences
  ADD COLUMN IF NOT EXISTS selected_model_id TEXT,
  ADD COLUMN IF NOT EXISTS system_prompt TEXT,
  ADD COLUMN IF NOT EXISTS identity_soul TEXT,
  ADD COLUMN IF NOT EXISTS identity_user TEXT,
  ADD COLUMN IF NOT EXISTS identity_memory TEXT,
  ADD COLUMN IF NOT EXISTS identity_enabled BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN public.user_preferences.identity_soul IS
  'Encrypted Soul text (AI personality and boundaries), client-managed';

COMMENT ON COLUMN public.user_preferences.identity_user IS
  'Encrypted User info text (facts and preferences), client-managed';

COMMENT ON COLUMN public.user_preferences.identity_memory IS
  'Encrypted long-term Memory text, client-managed';

COMMENT ON COLUMN public.user_preferences.identity_enabled IS
  'Master toggle for identity system (Soul/User/Memory)';

-- Optional one-time backfill from legacy JSONB keys in preferences.
-- Runs only if the legacy preferences column exists.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_preferences'
      AND column_name = 'preferences'
  ) THEN
    EXECUTE $sql$
      UPDATE public.user_preferences
      SET
        identity_soul = COALESCE(
          identity_soul,
          NULLIF(BTRIM(preferences ->> 'identity_soul'), '')
        ),
        identity_user = COALESCE(
          identity_user,
          NULLIF(BTRIM(preferences ->> 'identity_user'), '')
        ),
        identity_memory = COALESCE(
          identity_memory,
          NULLIF(BTRIM(preferences ->> 'identity_memory'), '')
        ),
        identity_enabled = CASE
          WHEN LOWER(COALESCE(preferences ->> 'identity_enabled', '')) IN ('true', 'false')
            THEN (preferences ->> 'identity_enabled')::BOOLEAN
          ELSE identity_enabled
        END
      WHERE preferences IS NOT NULL;
    $sql$;
  END IF;
END
$$;

COMMIT;
