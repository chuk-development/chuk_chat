-- ============================================================
-- Free Messages Feature Migration
-- ============================================================
-- This migration adds support for 10 free messages per account
-- for non-subscribed users. Free messages never reset.
--
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- Step 1: Add columns to profiles table
-- ============================================================
-- free_messages_total: Maximum free messages (default 10)
-- free_messages_used: Number of free messages consumed
-- ============================================================

ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS free_messages_total INTEGER DEFAULT 10,
ADD COLUMN IF NOT EXISTS free_messages_used INTEGER DEFAULT 0;

-- Set default values for existing users
UPDATE profiles
SET
  free_messages_total = COALESCE(free_messages_total, 10),
  free_messages_used = COALESCE(free_messages_used, 0)
WHERE free_messages_total IS NULL OR free_messages_used IS NULL;

-- Add constraints to prevent invalid values (skip if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'free_messages_total_positive'
  ) THEN
    ALTER TABLE profiles
    ADD CONSTRAINT free_messages_total_positive CHECK (free_messages_total >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'free_messages_used_non_negative'
  ) THEN
    ALTER TABLE profiles
    ADD CONSTRAINT free_messages_used_non_negative CHECK (free_messages_used >= 0);
  END IF;
END $$;

-- ============================================================
-- Step 2: Create RPC function to get remaining free messages
-- ============================================================
-- Returns the number of free messages remaining for a user
-- Returns 0 if user not found
-- ============================================================

CREATE OR REPLACE FUNCTION get_free_messages_remaining(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total integer;
  v_used integer;
BEGIN
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

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION get_free_messages_remaining(uuid) TO authenticated;

-- ============================================================
-- Step 3: Create RPC function to increment free messages used
-- ============================================================
-- Atomically increments free_messages_used by 1
-- Returns remaining count after increment
-- Returns -1 if no free messages remaining (atomic check)
-- ============================================================

CREATE OR REPLACE FUNCTION increment_free_messages_used(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_remaining integer;
BEGIN
  -- Atomically increment only if messages remain
  UPDATE profiles
  SET free_messages_used = free_messages_used + 1
  WHERE id = p_user_id
    AND free_messages_used < free_messages_total;

  -- Check if update succeeded (had messages remaining)
  IF NOT FOUND THEN
    RETURN -1; -- No free messages remaining or user not found
  END IF;

  -- Get new remaining count
  SELECT free_messages_total - free_messages_used
  INTO v_remaining
  FROM profiles
  WHERE id = p_user_id;

  RETURN COALESCE(v_remaining, 0);
END;
$$;

-- Grant execute permission to service role only (server-side use)
-- This prevents client from calling it directly
REVOKE EXECUTE ON FUNCTION increment_free_messages_used(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION increment_free_messages_used(uuid) FROM authenticated;

-- ============================================================
-- Step 4: Create index for performance (optional)
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_profiles_free_messages
  ON profiles(free_messages_used, free_messages_total)
  WHERE free_messages_used < free_messages_total;

-- ============================================================
-- Migration Complete
-- ============================================================
--
-- Columns added to profiles:
--   - free_messages_total (default 10)
--   - free_messages_used (default 0)
--
-- Functions created:
--   - get_free_messages_remaining(uuid) - callable by authenticated users
--   - increment_free_messages_used(uuid) - callable by service role only
--
-- Security notes:
--   - increment_free_messages_used is server-side only (service role)
--   - This prevents client-side manipulation of free message count
--   - Server verifies credits first, then falls back to free messages
--
-- How it works:
--   1. User sends message
--   2. Server checks credits (subscribed users)
--   3. If no credits, server checks free_messages_remaining
--   4. If free messages available, process request
--   5. On success, server calls increment_free_messages_used
--   6. User sees updated count in UI
--
-- ============================================================
