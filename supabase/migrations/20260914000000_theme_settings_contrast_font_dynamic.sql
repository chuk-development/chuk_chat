-- The theme pack a user picks carries five values: three colours, the contrast
-- strength and the app font. Only the colours were synced, so a second device
-- got the pack's colours but kept its own contrast and font — the theme page
-- then could not recognise the pack any more and showed "Custom" next to a
-- palette that clearly was the pack. Dynamic colour has the same problem: it
-- overrides the palette, so it belongs with the rest of the look.

-- The columns are nullable on purpose. A row written before this migration has
-- no value for them, and NULL is how the client tells "never stored" apart from
-- "stored as the default". Without that distinction the first sync after the
-- upgrade would overwrite a device's own contrast and font with the defaults.
ALTER TABLE public.theme_settings
  ADD COLUMN IF NOT EXISTS contrast DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS ui_font TEXT,
  ADD COLUMN IF NOT EXISTS dynamic_color BOOLEAN;

-- Applied earlier in this migration's life with NOT NULL DEFAULT; undo that so
-- a re-run and an already-migrated database end in the same state.
ALTER TABLE public.theme_settings
  ALTER COLUMN contrast DROP NOT NULL,
  ALTER COLUMN contrast DROP DEFAULT,
  ALTER COLUMN ui_font DROP NOT NULL,
  ALTER COLUMN ui_font DROP DEFAULT,
  ALTER COLUMN dynamic_color DROP NOT NULL,
  ALTER COLUMN dynamic_color DROP DEFAULT;

COMMENT ON COLUMN public.theme_settings.contrast IS
  'Surface/outline separation strength, 0..1. Part of a theme pack, so it travels with the colours. NULL means the user never stored one.';

COMMENT ON COLUMN public.theme_settings.ui_font IS
  'App-chrome font family id (see kSupportedUiFontFamilies). Part of a theme pack. NULL means never stored.';

COMMENT ON COLUMN public.theme_settings.dynamic_color IS
  'Material You. It overrides the explicit palette, so it is part of the look and syncs with it. NULL means never stored.';
