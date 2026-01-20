-- ============================================================
-- Fix credits functions - use correct column name
-- ============================================================

-- Fix check_and_reserve_credits - use credits_remaining instead of balance
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
  v_credits numeric;
BEGIN
  -- Get current credits with row lock
  SELECT credits_remaining INTO v_credits
  FROM public.user_credits
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_credits < p_amount THEN
    RETURN false;
  END IF;

  -- Deduct credits
  UPDATE public.user_credits
  SET credits_remaining = credits_remaining - p_amount
  WHERE user_id = p_user_id;

  RETURN true;
END;
$$;

-- Fix get_credits_remaining - use user_credits table instead of profiles
CREATE OR REPLACE FUNCTION public.get_credits_remaining(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_credits numeric;
BEGIN
  -- Security check: Only allow users to query their own data
  IF p_user_id != auth.uid() THEN
    RETURN 0;
  END IF;

  SELECT credits_remaining
  INTO v_credits
  FROM public.user_credits
  WHERE user_id = p_user_id;

  RETURN COALESCE(v_credits, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_credits_remaining(uuid) TO authenticated;
