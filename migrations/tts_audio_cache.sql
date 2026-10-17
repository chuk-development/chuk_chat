-- Private, client-encrypted cache for chat read-aloud audio.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('tts-audio', 'tts-audio', false, 52428800, ARRAY['application/octet-stream'])
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "Users can read own TTS audio" ON storage.objects;
CREATE POLICY "Users can read own TTS audio"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'tts-audio'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

DROP POLICY IF EXISTS "Users can upload own TTS audio" ON storage.objects;
CREATE POLICY "Users can upload own TTS audio"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'tts-audio'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

DROP POLICY IF EXISTS "Users can update own TTS audio" ON storage.objects;
CREATE POLICY "Users can update own TTS audio"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'tts-audio'
  AND auth.uid()::text = (storage.foldername(name))[1]
)
WITH CHECK (
  bucket_id = 'tts-audio'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

DROP POLICY IF EXISTS "Users can delete own TTS audio" ON storage.objects;
CREATE POLICY "Users can delete own TTS audio"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'tts-audio'
  AND auth.uid()::text = (storage.foldername(name))[1]
);
