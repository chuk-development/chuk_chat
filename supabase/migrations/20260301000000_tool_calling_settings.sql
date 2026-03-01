ALTER TABLE public.customization_preferences
  ADD COLUMN IF NOT EXISTS tool_calling_enabled BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS tool_discovery_mode BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_tool_calls BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS allow_markdown_tool_calls BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN public.customization_preferences.tool_calling_enabled IS
  'Master toggle for client-side tool calling loop';

COMMENT ON COLUMN public.customization_preferences.tool_discovery_mode IS
  'Require find_tools discovery before invoking other tools';

COMMENT ON COLUMN public.customization_preferences.show_tool_calls IS
  'Display tool execution chips in assistant message bubbles';

COMMENT ON COLUMN public.customization_preferences.allow_markdown_tool_calls IS
  'Allow parsing markdown fenced tool_call blocks as fallback';
