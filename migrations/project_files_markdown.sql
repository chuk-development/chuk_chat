-- ============================================================
-- Add markdown_summary to project_files
-- ============================================================
-- Run this if you already have the project_files table created.
-- This adds the markdown_summary column for AI-generated summaries.
-- ============================================================

-- Add markdown_summary column if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'project_files' AND column_name = 'markdown_summary'
  ) THEN
    ALTER TABLE project_files ADD COLUMN markdown_summary TEXT;
  END IF;
END $$;

-- ============================================================
-- Done! The markdown_summary column has been added.
-- ============================================================
