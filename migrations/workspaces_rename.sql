-- ============================================================
-- Workspaces Migration: Merge Projects + Assistants
-- ============================================================
-- This migration renames the projects tables to workspaces and
-- adds the assistant persona fields. Run AFTER the original
-- projects migration and assistants migration.
--
-- Run this in Supabase Dashboard > SQL Editor
-- ============================================================

-- Step 1: Add assistant fields to projects table
ALTER TABLE projects ADD COLUMN IF NOT EXISTS memory_enabled BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS model_id TEXT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS avatar_color TEXT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS avatar_icon TEXT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS avatar_image_path TEXT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS is_public BOOLEAN NOT NULL DEFAULT FALSE;

-- Step 2: Index for public workspaces
CREATE INDEX IF NOT EXISTS idx_projects_public ON projects(is_public) WHERE is_public = TRUE;

-- Step 3: Update SELECT policy to include public workspaces
DROP POLICY IF EXISTS "Users can view own projects" ON projects;
CREATE POLICY "Users can view own or public workspaces"
  ON projects FOR SELECT
  USING (auth.uid() = user_id OR is_public = true);

-- Step 4: Migrate assistant data into projects table (if assistants exist)
-- This copies each assistant as a new workspace/project entry
DO $$
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'assistants') THEN
    INSERT INTO projects (user_id, name, description, custom_system_prompt, memory_enabled, model_id, avatar_color, avatar_icon, avatar_image_path, is_public, is_archived)
    SELECT user_id, name, description, system_prompt, memory_enabled, model_id, avatar_color, avatar_icon, avatar_image_path, is_public, is_archived
    FROM assistants
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- ============================================================
-- NOTE: The Dart code now references these tables as "workspaces"
-- but the actual Postgres table names remain "projects",
-- "project_chats", and "project_files". This is intentional —
-- renaming tables in production requires careful coordination.
-- The Dart code uses the old table names in SQL queries.
-- ============================================================
