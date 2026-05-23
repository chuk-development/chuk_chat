ALTER TABLE public.customization_preferences
  ADD COLUMN IF NOT EXISTS include_tool_results_in_history BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN public.customization_preferences.include_tool_results_in_history IS
  'Include prior assistant tool calls and their results in API history so the model can reuse already-fetched data on follow-up questions.';
