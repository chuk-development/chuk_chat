-- Drop unused tables that were pre-planned but never used in the app or backend.
-- Verified: No references in Flutter app (chuk_chat) or API server (api_server).
-- These can be recreated later if needed.

DROP TABLE IF EXISTS credit_transactions CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS customer_preferences CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS team_settings CASCADE;
DROP VIEW IF EXISTS user_subscriptions CASCADE;
DROP TABLE IF EXISTS user_credits CASCADE;
DROP TABLE IF EXISTS project_status CASCADE;
