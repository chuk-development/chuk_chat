-- ============================================================
-- Assistants V2: Add avatar_image_path column
-- ============================================================
-- Adds support for custom uploaded avatar images for assistants.
-- Images are stored encrypted in the existing 'images' storage bucket.
-- This column stores the Supabase Storage path (e.g. "user_id/uuid.enc").
--
-- Run this in Supabase Dashboard > SQL Editor
-- ============================================================

ALTER TABLE assistants ADD COLUMN IF NOT EXISTS avatar_image_path TEXT;

-- ============================================================
-- Migration Complete
-- ============================================================
