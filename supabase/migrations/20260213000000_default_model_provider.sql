-- ============================================================
-- Migration: Default Model & Provider for New Users
-- ============================================================
-- Sets moonshotai/kimi-k2.5 on baseten as the default model
-- for every new user, so they can chat immediately without
-- having to visit the Model Selector Page first.
--
-- Two parts:
--   1. Trigger on profiles INSERT -> auto-create user_preferences
--      and user_model_providers rows
--   2. Backfill for existing users who have no preferences yet
--
-- Run in Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- 1. Function + Trigger: Set defaults on new user signup
-- ============================================================

CREATE OR REPLACE FUNCTION set_default_model_for_new_user()
RETURNS TRIGGER AS $$
BEGIN
  -- Insert default selected model into user_preferences
  INSERT INTO user_preferences (user_id, selected_model_id)
  VALUES (NEW.id, 'moonshotai/kimi-k2.5')
  ON CONFLICT (user_id) DO NOTHING;

  -- Insert default provider preference for the model
  INSERT INTO user_model_providers (user_id, model_id, provider_slug)
  VALUES (NEW.id, 'moonshotai/kimi-k2.5', 'baseten')
  ON CONFLICT (user_id, model_id) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fire after a new profile row is created (happens on signup)
DROP TRIGGER IF EXISTS trigger_set_default_model ON profiles;
CREATE TRIGGER trigger_set_default_model
  AFTER INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION set_default_model_for_new_user();

-- ============================================================
-- 2. Backfill: Existing users without any model preference
-- ============================================================

-- Give existing users the default selected model if they don't have one
INSERT INTO user_preferences (user_id, selected_model_id)
SELECT p.id, 'moonshotai/kimi-k2.5'
FROM profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM user_preferences up WHERE up.user_id = p.id
)
ON CONFLICT (user_id) DO NOTHING;

-- Give existing users the default provider if they have no providers at all
INSERT INTO user_model_providers (user_id, model_id, provider_slug)
SELECT p.id, 'moonshotai/kimi-k2.5', 'baseten'
FROM profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM user_model_providers ump WHERE ump.user_id = p.id
)
ON CONFLICT (user_id, model_id) DO NOTHING;

-- ============================================================
-- Migration Complete
-- ============================================================
--
-- New users: Trigger fires on profiles INSERT, auto-creates
--   user_preferences.selected_model_id = 'moonshotai/kimi-k2.5'
--   user_model_providers(model_id, provider_slug) = ('moonshotai/kimi-k2.5', 'baseten')
--
-- Existing users without preferences: Backfilled with same defaults
--
-- Users who already have preferences: NOT touched (ON CONFLICT DO NOTHING)
--
-- ============================================================
