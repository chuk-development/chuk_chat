-- Ensure tool-call stack is shown (collapsed) by default.
ALTER TABLE public.customization_preferences
  ADD COLUMN IF NOT EXISTS show_tool_calls BOOLEAN NOT NULL DEFAULT true;

ALTER TABLE public.customization_preferences
  ALTER COLUMN show_tool_calls SET DEFAULT true;

UPDATE public.customization_preferences
SET show_tool_calls = true
WHERE show_tool_calls IS NULL;
