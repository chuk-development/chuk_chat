ALTER TABLE public.customization_preferences
  ADD COLUMN IF NOT EXISTS chat_font_family TEXT NOT NULL DEFAULT 'arimo';

COMMENT ON COLUMN public.customization_preferences.chat_font_family IS
  'User-selected chat body font family identifier (system, arimo, merriweather, jetbrains_mono).';
