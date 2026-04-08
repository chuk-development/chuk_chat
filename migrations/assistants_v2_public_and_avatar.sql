-- ============================================================
-- Assistants V2: Avatar Images + Public Sharing
-- ============================================================
-- Run this in Supabase Dashboard > SQL Editor
-- ============================================================

-- 1. Add avatar image storage path
ALTER TABLE assistants ADD COLUMN IF NOT EXISTS avatar_image_path TEXT;

-- 2. Add public sharing flag
ALTER TABLE assistants ADD COLUMN IF NOT EXISTS is_public BOOLEAN NOT NULL DEFAULT FALSE;

-- 3. Index for fast public assistant queries
CREATE INDEX IF NOT EXISTS idx_assistants_public ON assistants(is_public) WHERE is_public = TRUE;

-- 4. Update SELECT policy to allow reading public assistants
DROP POLICY IF EXISTS "Users can view their own assistants" ON assistants;
CREATE POLICY "Users can view own or public assistants"
  ON assistants FOR SELECT
  USING (auth.uid() = user_id OR is_public = true);

-- ============================================================
-- Migration Complete
-- ============================================================
-- Added: avatar_image_path TEXT (encrypted image storage path)
-- Added: is_public BOOLEAN (default false, allows sharing)
-- Updated: SELECT RLS policy now allows reading public assistants
-- ============================================================
