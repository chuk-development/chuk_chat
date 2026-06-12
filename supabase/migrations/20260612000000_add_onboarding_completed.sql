-- Onboarding tour completion is per-user, not per-device. Persisting it in
-- customization_preferences means a user who finished (or skipped) the tour
-- never sees it again on a fresh install or another device.
ALTER TABLE customization_preferences
  ADD COLUMN IF NOT EXISTS onboarding_completed BOOLEAN NOT NULL DEFAULT false;
