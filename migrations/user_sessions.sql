-- Migration: user_sessions table for remote session management
-- Tracks active sessions across devices so users can view and revoke them.

CREATE TABLE IF NOT EXISTS user_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_name TEXT,
  platform TEXT,
  app_version TEXT,
  last_seen_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now(),
  is_active BOOLEAN DEFAULT true,
  refresh_token_hash TEXT,
  UNIQUE(user_id, refresh_token_hash)
);

-- RLS: Users can only see/manage their own sessions
ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_sessions_select" ON user_sessions
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "users_own_sessions_insert" ON user_sessions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "users_own_sessions_update" ON user_sessions
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "users_own_sessions_delete" ON user_sessions
  FOR DELETE USING (auth.uid() = user_id);

-- Index for fast lookups by user
CREATE INDEX idx_user_sessions_user_active ON user_sessions (user_id, is_active)
  WHERE is_active = true;
