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
-- Also fix get_credits_remaining if it exists
-- ============================================================

CREATE OR REPLACE FUNCTION get_credits_remaining(p_user_id uuid)
RETURNS decimal
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_credits decimal;
BEGIN
  -- Security check: Only allow users to query their own data
  IF p_user_id != auth.uid() THEN
    RETURN 0;
  END IF;

  SELECT credits_remaining
  INTO v_credits
  FROM profiles
  WHERE id = p_user_id;

  RETURN COALESCE(v_credits, 0);
END;
$$;

-- Ensure authenticated users can execute
GRANT EXECUTE ON FUNCTION get_credits_remaining(uuid) TO authenticated;

-- ============================================================
-- Done! Both functions now verify auth.uid() = p_user_id
-- ============================================================
