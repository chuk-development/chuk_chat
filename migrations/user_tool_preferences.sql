-- Migration: per-tool enabled state sync (Supabase)
-- Run in Supabase SQL Editor.

BEGIN;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS public.user_tool_preferences (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tool_name TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, tool_name)
);

CREATE INDEX IF NOT EXISTS idx_user_tool_preferences_user_id
  ON public.user_tool_preferences(user_id);

ALTER TABLE public.user_tool_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own tool preferences"
  ON public.user_tool_preferences;
CREATE POLICY "Users can view their own tool preferences"
  ON public.user_tool_preferences FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert their own tool preferences"
  ON public.user_tool_preferences;
CREATE POLICY "Users can insert their own tool preferences"
  ON public.user_tool_preferences FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own tool preferences"
  ON public.user_tool_preferences;
CREATE POLICY "Users can update their own tool preferences"
  ON public.user_tool_preferences FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete their own tool preferences"
  ON public.user_tool_preferences;
CREATE POLICY "Users can delete their own tool preferences"
  ON public.user_tool_preferences FOR DELETE
  USING (auth.uid() = user_id);

DROP TRIGGER IF EXISTS trigger_user_tool_preferences_updated_at
  ON public.user_tool_preferences;
CREATE TRIGGER trigger_user_tool_preferences_updated_at
  BEFORE UPDATE ON public.user_tool_preferences
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

COMMIT;
