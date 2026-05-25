-- ============================================================
-- Migration: Enable realtime for user model preference tables
-- ============================================================
-- Adds user_model_providers and user_preferences to the
-- supabase_realtime publication so the client can subscribe to
-- INSERT / UPDATE / DELETE events and sync the active model list
-- across devices (desktop ↔ mobile) instantly.
--
-- Run in Supabase Dashboard → SQL Editor.
-- Safe to re-run; conditional checks avoid "already member" errors.
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'user_model_providers'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.user_model_providers';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'user_preferences'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.user_preferences';
  END IF;
END $$;

-- Ensure DELETE / UPDATE payloads include the old row so the client
-- can identify which row was removed when no new row exists.
ALTER TABLE public.user_model_providers REPLICA IDENTITY FULL;
ALTER TABLE public.user_preferences REPLICA IDENTITY FULL;
