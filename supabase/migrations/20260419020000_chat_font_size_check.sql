-- Defence-in-depth bounds for chat_font_size; client already clamps to
-- [kMinChatFontSize, kMaxChatFontSize]. Range kept wider than the UI so a
-- future slider extension does not require a new migration.
ALTER TABLE public.customization_preferences
  DROP CONSTRAINT IF EXISTS customization_preferences_chat_font_size_range;

ALTER TABLE public.customization_preferences
  ADD CONSTRAINT customization_preferences_chat_font_size_range
    CHECK (chat_font_size BETWEEN 8 AND 72);
