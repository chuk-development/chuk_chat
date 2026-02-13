-- ============================================================
-- Fix: get_free_messages_remaining Security
-- ============================================================
-- This migration updates the get_free_messages_remaining function
-- to verify that users can only query their own data.
--
-- This prevents enumeration attacks where users could check
-- other users' free message counts.
--
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- Recreate the function with auth.uid() check
CREATE OR REPLACE FUNCTION get_free_messages_remaining(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total integer;
  v_used integer;
BEGIN
  -- Security check: Only allow users to query their own data
  IF p_user_id != auth.uid() THEN
    RETURN 0;
  END IF;

  SELECT free_messages_total, free_messages_used
  INTO v_total, v_used
  FROM profiles
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- Return remaining, minimum 0
  RETURN GREATEST(0, COALESCE(v_total, 10) - COALESCE(v_used, 0));
END;
$$;

-- Ensure authenticated users can execute
GRANT EXECUTE ON FUNCTION get_free_messages_remaining(uuid) TO authenticated;

-- ============================================================
-- Also fix get_credits_remaining
-- NOTE: The canonical version of this function lives in the
-- api_server repo (20260124_get_credits_remaining.sql) which
-- calculates credits from total_credits_allocated - SUM(usage).
-- This stub is kept for migration history only.
-- ============================================================
-- See api_server/supabase/migrations/20260124_get_credits_remaining.sql
-- for the authoritative CREATE OR REPLACE.
-- ============================================================
