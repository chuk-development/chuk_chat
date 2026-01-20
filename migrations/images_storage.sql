-- ============================================================
-- Storage Bucket RLS Policies for images
-- ============================================================
-- Run this in Supabase Dashboard → SQL Editor
--
-- Prerequisites:
--   1. Create bucket 'images' in Dashboard → Storage
--   2. Make sure bucket is PRIVATE (not public)
--
-- Note: Images are E2E encrypted client-side, so even without
-- RLS policies the data would be unreadable. However, RLS adds
-- defense-in-depth by preventing unauthorized access attempts.
-- ============================================================

-- Allow users to upload images to their own folder
CREATE POLICY "Users can upload images"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'images'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow users to read their own images
CREATE POLICY "Users can read own images"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'images'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow users to delete their own images
CREATE POLICY "Users can delete own images"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'images'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Allow users to update their own images (for re-uploads)
CREATE POLICY "Users can update own images"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'images'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- ============================================================
-- Done! Image uploads to images bucket should now work.
-- ============================================================
