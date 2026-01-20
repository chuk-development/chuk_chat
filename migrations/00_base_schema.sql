-- ============================================================
-- Base Schema Migration
-- ============================================================
-- This migration creates all base tables required for chuk_chat.
-- Run this FIRST before any other migrations.
--
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- Table: profiles
-- ============================================================
-- User profile with credits and free messages tracking.
-- Primary key is user_id referencing auth.users.
-- ============================================================

CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT,
  credits_remaining DECIMAL DEFAULT 0,
  free_messages_total INTEGER DEFAULT 10,
  free_messages_used INTEGER DEFAULT 0,
  notifications_enabled BOOLEAN DEFAULT true,
  weekly_summary_enabled BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Constraints
  CONSTRAINT credits_non_negative CHECK (credits_remaining >= 0),
  CONSTRAINT free_messages_total_positive CHECK (free_messages_total >= 0),
  CONSTRAINT free_messages_used_non_negative CHECK (free_messages_used >= 0)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_profiles_free_messages
  ON profiles(free_messages_used, free_messages_total)
  WHERE free_messages_used < free_messages_total;

-- Enable Row Level Security
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own profile"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can insert their own profile"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update their own profile"
  ON profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- ============================================================
-- Table: encrypted_chats
-- ============================================================
-- Stores encrypted chat conversations.
-- All message content is E2E encrypted client-side.
-- ============================================================

CREATE TABLE IF NOT EXISTS encrypted_chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  encrypted_payload TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_starred BOOLEAN NOT NULL DEFAULT FALSE,
  image_paths TEXT[] DEFAULT '{}',

  -- Constraints
  CONSTRAINT encrypted_payload_not_empty CHECK (LENGTH(encrypted_payload) > 0)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_encrypted_chats_user_id ON encrypted_chats(user_id);
CREATE INDEX IF NOT EXISTS idx_encrypted_chats_created_at ON encrypted_chats(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_encrypted_chats_starred ON encrypted_chats(is_starred) WHERE is_starred = TRUE;

-- Enable Row Level Security
ALTER TABLE encrypted_chats ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own chats"
  ON encrypted_chats FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own chats"
  ON encrypted_chats FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own chats"
  ON encrypted_chats FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own chats"
  ON encrypted_chats FOR DELETE
  USING (auth.uid() = user_id);

-- ============================================================
-- Table: theme_settings
-- ============================================================
-- User theme and appearance preferences.
-- ============================================================

CREATE TABLE IF NOT EXISTS theme_settings (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  theme_mode TEXT NOT NULL DEFAULT 'dark',
  accent_color TEXT,
  icon_color TEXT,
  background_color TEXT,
  grain_enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Constraints
  CONSTRAINT valid_theme_mode CHECK (theme_mode IN ('light', 'dark', 'system'))
);

-- Enable Row Level Security
ALTER TABLE theme_settings ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own theme settings"
  ON theme_settings FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own theme settings"
  ON theme_settings FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own theme settings"
  ON theme_settings FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- Table: customization_preferences
-- ============================================================
-- User behavior and functionality preferences.
-- ============================================================

CREATE TABLE IF NOT EXISTS customization_preferences (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  auto_send_voice_transcription BOOLEAN NOT NULL DEFAULT false,
  show_reasoning_tokens BOOLEAN NOT NULL DEFAULT true,
  show_model_info BOOLEAN NOT NULL DEFAULT true,
  image_gen_enabled BOOLEAN NOT NULL DEFAULT false,
  image_gen_default_size TEXT NOT NULL DEFAULT 'landscape_4_3',
  image_gen_custom_width INTEGER NOT NULL DEFAULT 1024,
  image_gen_custom_height INTEGER NOT NULL DEFAULT 768,
  image_gen_use_custom_size BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Constraints
  CONSTRAINT valid_image_gen_size CHECK (
    image_gen_default_size IN ('square_hd', 'square', 'portrait_4_3', 'portrait_16_9', 'landscape_4_3', 'landscape_16_9')
  ),
  CONSTRAINT valid_custom_width CHECK (image_gen_custom_width BETWEEN 256 AND 2048),
  CONSTRAINT valid_custom_height CHECK (image_gen_custom_height BETWEEN 256 AND 2048)
);

-- Enable Row Level Security
ALTER TABLE customization_preferences ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own customization preferences"
  ON customization_preferences FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own customization preferences"
  ON customization_preferences FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own customization preferences"
  ON customization_preferences FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- Table: user_preferences
-- ============================================================
-- General user settings stored as JSONB (model selection, etc).
-- ============================================================

CREATE TABLE IF NOT EXISTS user_preferences (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  preferences JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enable Row Level Security
ALTER TABLE user_preferences ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own preferences"
  ON user_preferences FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own preferences"
  ON user_preferences FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own preferences"
  ON user_preferences FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- Trigger: Auto-update updated_at timestamps
-- ============================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to all tables with updated_at
CREATE TRIGGER trigger_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_encrypted_chats_updated_at
  BEFORE UPDATE ON encrypted_chats
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_theme_settings_updated_at
  BEFORE UPDATE ON theme_settings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_customization_preferences_updated_at
  BEFORE UPDATE ON customization_preferences
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_user_preferences_updated_at
  BEFORE UPDATE ON user_preferences
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- RPC Functions for Credits and Free Messages
-- ============================================================

-- Get remaining free messages for a user
-- SECURITY: Only returns data for the calling user
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

  RETURN GREATEST(0, COALESCE(v_total, 10) - COALESCE(v_used, 0));
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION get_free_messages_remaining(uuid) TO authenticated;

-- Increment free messages used (server-side only)
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

  IF NOT FOUND THEN
    RETURN -1;
  END IF;

  SELECT free_messages_total - free_messages_used
  INTO v_remaining
  FROM profiles
  WHERE id = p_user_id;

  RETURN COALESCE(v_remaining, 0);
END;
$$;

-- Restrict to service role only (server-side use)
REVOKE EXECUTE ON FUNCTION increment_free_messages_used(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION increment_free_messages_used(uuid) FROM authenticated;

-- Get credits remaining for a user
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

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION get_credits_remaining(uuid) TO authenticated;

-- ============================================================
-- Migration Complete
-- ============================================================
--
-- Tables created:
--   - profiles (with RLS)
--   - encrypted_chats (with RLS)
--   - theme_settings (with RLS)
--   - customization_preferences (with RLS)
--   - user_preferences (with RLS)
--
-- Functions created:
--   - get_free_messages_remaining(uuid) - authenticated users
--   - increment_free_messages_used(uuid) - service role only
--   - get_credits_remaining(uuid) - authenticated users
--
-- Triggers:
--   - Auto-update updated_at on all tables
--
-- Next steps:
--   1. Run projects.sql for project workspace feature
--   2. Run images_storage.sql for image bucket RLS
--   3. Run project_files_storage.sql for project files bucket RLS
--
-- ============================================================
