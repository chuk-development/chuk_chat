-- Migration: align customization_preferences with app settings sync
-- Run in Supabase SQL Editor.

BEGIN;

ALTER TABLE public.customization_preferences
  ADD COLUMN IF NOT EXISTS show_reasoning_tokens BOOLEAN,
  ADD COLUMN IF NOT EXISTS show_model_info BOOLEAN,
  ADD COLUMN IF NOT EXISTS image_gen_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS image_gen_default_size TEXT NOT NULL DEFAULT 'landscape_4_3',
  ADD COLUMN IF NOT EXISTS image_gen_custom_width INTEGER NOT NULL DEFAULT 1024,
  ADD COLUMN IF NOT EXISTS image_gen_custom_height INTEGER NOT NULL DEFAULT 768,
  ADD COLUMN IF NOT EXISTS image_gen_use_custom_size BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS auto_generate_titles BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS title_gen_system_prompt TEXT;

-- Backfill reasoning/model flags from theme_settings when available.
UPDATE public.customization_preferences cp
SET
  show_reasoning_tokens = COALESCE(ts.show_reasoning_tokens, true),
  show_model_info = COALESCE(ts.show_model_info, true)
FROM public.theme_settings ts
WHERE ts.user_id = cp.user_id;

UPDATE public.customization_preferences
SET
  show_reasoning_tokens = COALESCE(show_reasoning_tokens, true),
  show_model_info = COALESCE(show_model_info, true)
WHERE show_reasoning_tokens IS NULL OR show_model_info IS NULL;

ALTER TABLE public.customization_preferences
  ALTER COLUMN show_reasoning_tokens SET DEFAULT true,
  ALTER COLUMN show_reasoning_tokens SET NOT NULL,
  ALTER COLUMN show_model_info SET DEFAULT true,
  ALTER COLUMN show_model_info SET NOT NULL;

COMMENT ON COLUMN public.customization_preferences.auto_generate_titles IS
  'Whether AI should auto-generate titles for new chats';

COMMENT ON COLUMN public.customization_preferences.title_gen_system_prompt IS
  'Encrypted custom system prompt used for title generation';

COMMIT;
