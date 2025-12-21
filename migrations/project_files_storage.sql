-- ============================================================
-- Storage Bucket RLS Policies for project-files
-- ============================================================
-- Run this in Supabase Dashboard → SQL Editor
--
-- Prerequisites:
--   1. Create bucket 'project-files' in Dashboard → Storage
--   2. Make sure bucket is PRIVATE (not public)
-- ============================================================

-- Allow users to upload files to their own folder
CREATE POLICY "Users can upload project files"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'project-files'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow users to read their own files
CREATE POLICY "Users can read own project files"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'project-files'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow users to delete their own files
CREATE POLICY "Users can delete own project files"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'project-files'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow users to update their own files
CREATE POLICY "Users can update own project files"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'project-files'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- ============================================================
-- Done! File uploads to project-files bucket should now work.
-- ============================================================
