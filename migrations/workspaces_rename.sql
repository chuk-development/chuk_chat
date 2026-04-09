-- ============================================================
-- Workspaces Migration: Add assistant fields + migrate data
-- ============================================================
-- Run this in Supabase Dashboard > SQL Editor
-- Prerequisite: projects, project_chats, project_files tables exist
-- ============================================================

-- Step 1: Add assistant persona fields to projects table
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
DROP POLICY IF EXISTS "Users can view own or public workspaces" ON projects;
CREATE POLICY "Users can view own or public workspaces"
  ON projects FOR SELECT
  USING (auth.uid() = user_id OR is_public = true);

-- Step 4: Migrate assistant data into projects table
-- Each assistant becomes a workspace with its system_prompt, avatar, etc.
DO $$
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'assistants') THEN
    -- Only insert assistants not already migrated (idempotent)
    INSERT INTO projects (
      user_id, name, description, custom_system_prompt,
      memory_enabled, model_id, avatar_color, avatar_icon,
      avatar_image_path, is_public, is_archived
    )
    SELECT
      a.user_id, a.name, a.description, a.system_prompt,
      a.memory_enabled, a.model_id, a.avatar_color, a.avatar_icon,
      a.avatar_image_path, a.is_public, a.is_archived
    FROM assistants a
    WHERE NOT EXISTS (
      SELECT 1 FROM projects p
      WHERE p.user_id = a.user_id
        AND p.name IS NOT DISTINCT FROM a.name
        AND p.custom_system_prompt IS NOT DISTINCT FROM a.system_prompt
    );

    RAISE NOTICE 'Migrated assistants to workspaces (skipped duplicates)';
  ELSE
    RAISE NOTICE 'No assistants table found — skipping migration';
  END IF;
END $$;

-- Step 5: Migrate assistant_chats links to project_chats
DO $$
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'assistant_chats')
     AND EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'assistants') THEN
    INSERT INTO project_chats (project_id, chat_id)
    SELECT p.id, ac.chat_id
    FROM assistant_chats ac
    JOIN assistants a ON a.id = ac.assistant_id
    JOIN projects p ON p.user_id = a.user_id
      AND p.name IS NOT DISTINCT FROM a.name
      AND p.custom_system_prompt IS NOT DISTINCT FROM a.system_prompt
    ON CONFLICT DO NOTHING;

    RAISE NOTICE 'Migrated assistant-chat links to workspace-chat links';
  END IF;
END $$;

-- Step 6: Clean up old tables (optional — uncomment when ready)
-- DROP TABLE IF EXISTS assistant_chats CASCADE;
-- DROP TABLE IF EXISTS assistants CASCADE;

-- ============================================================
-- Migration Complete
-- ============================================================
-- The Dart code references tables as:
--   projects → "workspaces" in code
--   project_chats → workspace chat links
--   project_files → workspace files
-- Table names in Postgres remain unchanged for safety.
-- ============================================================
