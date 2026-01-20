-- ============================================================
-- Fix Supabase Security Linter Errors and Warnings
-- ============================================================
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- ERROR 1 & 2: Fix SECURITY DEFINER Views
-- Change to SECURITY INVOKER so RLS of calling user applies
-- ============================================================

-- Fix user_credit_summary view - use ALTER to preserve existing definition
ALTER VIEW public.user_credit_summary SET (security_invoker = true);

-- Fix user_subscriptions view - use ALTER to preserve existing definition
ALTER VIEW public.user_subscriptions SET (security_invoker = true);

-- ============================================================
-- ERROR 3: Enable RLS on webhook_events
-- ============================================================

ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;

-- Webhook events should only be accessible by service_role (backend)
-- No policies = no access for authenticated users (only service_role can access)
-- If you need user access, add a policy like:
-- CREATE POLICY "Users can view their own webhook events"
--   ON webhook_events FOR SELECT
--   USING (auth.uid() = user_id);

-- ============================================================
-- WARNINGS: Fix function search_path
-- Set search_path = '' to prevent search path hijacking
-- ============================================================

-- Fix update_project_updated_at
CREATE OR REPLACE FUNCTION public.update_project_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Fix get_free_messages_remaining
CREATE OR REPLACE FUNCTION public.get_free_messages_remaining(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  FROM public.profiles
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  RETURN GREATEST(0, COALESCE(v_total, 10) - COALESCE(v_used, 0));
END;
$$;

-- Fix increment_free_messages_used
CREATE OR REPLACE FUNCTION public.increment_free_messages_used(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_remaining integer;
BEGIN
  UPDATE public.profiles
  SET free_messages_used = free_messages_used + 1
  WHERE id = p_user_id
    AND free_messages_used < free_messages_total;

  IF NOT FOUND THEN
    RETURN -1;
  END IF;

  SELECT free_messages_total - free_messages_used
  INTO v_remaining
  FROM public.profiles
  WHERE id = p_user_id;

  RETURN COALESCE(v_remaining, 0);
END;
$$;

-- Fix get_credits_remaining
CREATE OR REPLACE FUNCTION public.get_credits_remaining(p_user_id uuid)
RETURNS decimal
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  FROM public.profiles
  WHERE id = p_user_id;

  RETURN COALESCE(v_credits, 0);
END;
$$;

-- Fix update_customization_preferences_updated_at
CREATE OR REPLACE FUNCTION public.update_customization_preferences_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Fix update_timestamp
CREATE OR REPLACE FUNCTION public.update_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Fix check_and_reserve_credits
-- Drop by OID to handle any signature
DO $$
DECLARE
  func_oid oid;
BEGIN
  FOR func_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' AND p.proname = 'check_and_reserve_credits'
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || func_oid::regprocedure;
  END LOOP;
END $$;

CREATE FUNCTION public.check_and_reserve_credits(
  p_user_id uuid,
  p_amount numeric
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_balance numeric;
BEGIN
  -- Get current balance with row lock
  SELECT balance INTO v_balance
  FROM public.user_credits
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_balance < p_amount THEN
    RETURN false;
  END IF;

  -- Deduct credits
  UPDATE public.user_credits
  SET balance = balance - p_amount
  WHERE user_id = p_user_id;

  RETURN true;
END;
$$;

-- Ensure proper permissions
GRANT EXECUTE ON FUNCTION public.get_free_messages_remaining(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_credits_remaining(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.increment_free_messages_used(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.increment_free_messages_used(uuid) FROM authenticated;

-- ============================================================
-- Done!
--
-- Remaining manual steps in Supabase Dashboard:
-- 1. Authentication → Settings → Enable "Leaked password protection"
-- 2. Authentication → MFA → Enable TOTP or other MFA methods
-- ============================================================
