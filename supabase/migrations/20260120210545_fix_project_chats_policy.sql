-- ============================================================
-- Fix: project_chats INSERT Policy - Add Chat Ownership Check
-- ============================================================
-- This migration updates the project_chats INSERT policy to also
-- verify that the user owns the chat they're adding to the project.
--
-- This prevents users from adding other users' chat IDs to their projects.
--
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- Step 1: Drop the existing policy (if exists)
DROP POLICY IF EXISTS "Users can add chats to their own projects" ON project_chats;

-- Step 2: Create the updated policy with chat ownership check
CREATE POLICY "Users can add chats to their own projects"
  ON project_chats FOR INSERT
  WITH CHECK (
    -- User must own the project
    EXISTS (
      SELECT 1 FROM projects
      WHERE projects.id = project_chats.project_id
      AND projects.user_id = auth.uid()
    )
    AND
    -- User must also own the chat being added
    EXISTS (
      SELECT 1 FROM encrypted_chats
      WHERE encrypted_chats.id = project_chats.chat_id
      AND encrypted_chats.user_id = auth.uid()
    )
  );

-- ============================================================
-- Done! The project_chats INSERT policy now requires both:
--   1. User owns the project
--   2. User owns the chat being added
-- ============================================================
