-- ============================================================
-- Projects Feature Migration
-- ============================================================
-- This migration adds support for project workspaces that group
-- chats, files, and custom system prompts.
--
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- Table: projects
-- ============================================================
-- Stores project metadata and configuration
-- ============================================================

CREATE TABLE IF NOT EXISTS projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  custom_system_prompt TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,

  -- Constraints
  CONSTRAINT name_not_empty CHECK (LENGTH(TRIM(name)) > 0)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_projects_user_id ON projects(user_id);
CREATE INDEX IF NOT EXISTS idx_projects_created_at ON projects(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_projects_archived ON projects(is_archived) WHERE is_archived = FALSE;

-- Enable Row Level Security
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

-- RLS Policies for projects table
CREATE POLICY "Users can view their own projects"
  ON projects FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own projects"
  ON projects FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own projects"
  ON projects FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own projects"
  ON projects FOR DELETE
  USING (auth.uid() = user_id);

-- ============================================================
-- Table: project_chats
-- ============================================================
-- Many-to-many relationship between projects and chats
-- A chat can belong to multiple projects
-- ============================================================

CREATE TABLE IF NOT EXISTS project_chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  chat_id TEXT NOT NULL REFERENCES encrypted_chats(id) ON DELETE CASCADE,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Ensure a chat can only be added once per project
  CONSTRAINT unique_project_chat UNIQUE(project_id, chat_id)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_project_chats_project_id ON project_chats(project_id);
CREATE INDEX IF NOT EXISTS idx_project_chats_chat_id ON project_chats(chat_id);

-- Enable Row Level Security
ALTER TABLE project_chats ENABLE ROW LEVEL SECURITY;

-- RLS Policies for project_chats table
CREATE POLICY "Users can view project chats for their own projects"
  ON project_chats FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_chats.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can add chats to their own projects"
  ON project_chats FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_chats.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can remove chats from their own projects"
  ON project_chats FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_chats.project_id
      AND projects.user_id = auth.uid()
    )
  );

-- ============================================================
-- Table: project_files
-- ============================================================
-- Stores encrypted file attachments for projects
-- Files are encrypted client-side before upload
-- ============================================================

CREATE TABLE IF NOT EXISTS project_files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  file_name TEXT NOT NULL,
  encrypted_content TEXT NOT NULL,
  file_type TEXT NOT NULL,
  file_size BIGINT NOT NULL,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Constraints
  CONSTRAINT file_name_not_empty CHECK (LENGTH(TRIM(file_name)) > 0),
  CONSTRAINT file_size_positive CHECK (file_size > 0),
  CONSTRAINT file_size_limit CHECK (file_size <= 10485760) -- 10MB max
);

-- Index for performance
CREATE INDEX IF NOT EXISTS idx_project_files_project_id ON project_files(project_id);

-- Enable Row Level Security
ALTER TABLE project_files ENABLE ROW LEVEL SECURITY;

-- RLS Policies for project_files table
CREATE POLICY "Users can view files in their own projects"
  ON project_files FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_files.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can upload files to their own projects"
  ON project_files FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_files.project_id
      AND projects.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can delete files from their own projects"
  ON project_files FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_files.project_id
      AND projects.user_id = auth.uid()
    )
  );

-- ============================================================
-- Function: Update project updated_at timestamp
-- ============================================================
-- Automatically updates the updated_at field when a project is modified
-- ============================================================

CREATE OR REPLACE FUNCTION update_project_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-update updated_at
CREATE TRIGGER trigger_update_project_timestamp
  BEFORE UPDATE ON projects
  FOR EACH ROW
  EXECUTE FUNCTION update_project_updated_at();

-- ============================================================
-- Helper Views (Optional - for analytics/debugging)
-- ============================================================

-- View: Project statistics
CREATE OR REPLACE VIEW project_stats AS
SELECT
  p.id,
  p.user_id,
  p.name,
  p.is_archived,
  COUNT(DISTINCT pc.chat_id) AS chat_count,
  COUNT(DISTINCT pf.id) AS file_count,
  COALESCE(SUM(pf.file_size), 0) AS total_file_size,
  p.created_at,
  p.updated_at
FROM projects p
LEFT JOIN project_chats pc ON p.id = pc.project_id
LEFT JOIN project_files pf ON p.id = pf.project_id
GROUP BY p.id, p.user_id, p.name, p.is_archived, p.created_at, p.updated_at;

-- RLS for view
ALTER VIEW project_stats SET (security_invoker = true);

-- ============================================================
-- Migration Complete
-- ============================================================
--
-- Tables created:
--   - projects (with RLS)
--   - project_chats (with RLS)
--   - project_files (with RLS)
--
-- Indexes created for optimal query performance
-- Triggers created for auto-updating timestamps
-- Views created for analytics
--
-- Next steps:
--   1. Verify tables in Supabase Dashboard → Database → Tables
--   2. Test RLS policies with sample data
--   3. Implement Flutter services (ProjectStorageService)
--
-- ============================================================
