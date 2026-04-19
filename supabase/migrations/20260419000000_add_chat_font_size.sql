ALTER TABLE public.customization_preferences
  ADD COLUMN IF NOT EXISTS chat_font_size DOUBLE PRECISION NOT NULL DEFAULT 15;

COMMENT ON COLUMN public.customization_preferences.chat_font_size IS
  'User-selected chat body font size in logical pixels (applies to user and AI message text).';
