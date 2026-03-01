-- Show compact tool-call stack by default for new preference rows.
ALTER TABLE public.customization_preferences
  ADD COLUMN IF NOT EXISTS tool_calling_enabled BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS tool_discovery_mode BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_tool_calls BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS allow_markdown_tool_calls BOOLEAN NOT NULL DEFAULT true;

UPDATE public.customization_preferences
SET show_tool_calls = true
WHERE show_tool_calls IS NULL;

ALTER TABLE public.customization_preferences
  ALTER COLUMN show_tool_calls SET NOT NULL,
  ALTER COLUMN show_tool_calls SET DEFAULT true;

COMMENT ON COLUMN public.customization_preferences.show_tool_calls IS
  'Whether to show the tool-calling activity stack in chat messages (default true).';
