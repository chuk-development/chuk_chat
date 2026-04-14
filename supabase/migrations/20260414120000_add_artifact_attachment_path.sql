-- Optional attachment stored in Supabase Storage (encrypted, client-side).
-- Used for artifact types whose "rendered" form is a binary blob that we
-- want to keep alongside the source — e.g. a Typst source + the compiled
-- PDF. The client is responsible for writing/reading the blob; the server
-- only stores the path here.
ALTER TABLE artifacts
  ADD COLUMN IF NOT EXISTS attachment_path text;

-- Versions table mirrors the attachment per-version so the UI can reopen
-- a specific snapshot without recompiling.
ALTER TABLE artifact_versions
  ADD COLUMN IF NOT EXISTS attachment_path text;
