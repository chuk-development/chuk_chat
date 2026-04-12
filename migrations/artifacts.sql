-- Artifact system tables

BEGIN;

CREATE TABLE IF NOT EXISTS artifacts (
  id TEXT PRIMARY KEY,
  chat_id UUID NOT NULL REFERENCES encrypted_chats(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  message_id TEXT,
  title TEXT NOT NULL,
  type TEXT NOT NULL,
  language TEXT,
  content TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT artifacts_id_format CHECK (id ~ '^[A-Za-z0-9-]+$'),
  CONSTRAINT artifacts_type_valid CHECK (
    type IN ('code', 'markdown', 'html', 'mermaid', 'svg', 'technical_drawing')
  ),
  CONSTRAINT artifacts_version_positive CHECK (version > 0),
  CONSTRAINT artifacts_content_size CHECK (octet_length(content) <= 512000)
);

CREATE INDEX IF NOT EXISTS idx_artifacts_chat_id
  ON artifacts(chat_id);

CREATE INDEX IF NOT EXISTS idx_artifacts_chat_updated
  ON artifacts(chat_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_artifacts_user_id
  ON artifacts(user_id);

CREATE OR REPLACE FUNCTION set_artifacts_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_artifacts_updated_at ON artifacts;
CREATE TRIGGER trg_set_artifacts_updated_at
  BEFORE UPDATE ON artifacts
  FOR EACH ROW
  EXECUTE FUNCTION set_artifacts_updated_at();

CREATE TABLE IF NOT EXISTS artifact_versions (
  id BIGSERIAL PRIMARY KEY,
  artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES encrypted_chats(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  version INTEGER NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT artifact_versions_unique_version UNIQUE (artifact_id, version),
  CONSTRAINT artifact_versions_version_positive CHECK (version > 0),
  CONSTRAINT artifact_versions_content_size CHECK (octet_length(content) <= 512000)
);

CREATE INDEX IF NOT EXISTS idx_artifact_versions_artifact_version
  ON artifact_versions(artifact_id, version DESC);

CREATE INDEX IF NOT EXISTS idx_artifact_versions_chat_id
  ON artifact_versions(chat_id);

ALTER TABLE artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE artifact_versions ENABLE ROW LEVEL SECURITY;

-- RLS policies for artifacts
DROP POLICY IF EXISTS "Users can view their own artifacts" ON artifacts;
CREATE POLICY "Users can view their own artifacts"
  ON artifacts FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert their own artifacts" ON artifacts;
CREATE POLICY "Users can insert their own artifacts"
  ON artifacts FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own artifacts" ON artifacts;
CREATE POLICY "Users can update their own artifacts"
  ON artifacts FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete their own artifacts" ON artifacts;
CREATE POLICY "Users can delete their own artifacts"
  ON artifacts FOR DELETE
  USING (auth.uid() = user_id);

-- RLS policies for artifact_versions
DROP POLICY IF EXISTS "Users can view their own artifact versions"
  ON artifact_versions;
CREATE POLICY "Users can view their own artifact versions"
  ON artifact_versions FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert their own artifact versions"
  ON artifact_versions;
CREATE POLICY "Users can insert their own artifact versions"
  ON artifact_versions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own artifact versions"
  ON artifact_versions;
CREATE POLICY "Users can update their own artifact versions"
  ON artifact_versions FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete their own artifact versions"
  ON artifact_versions;
CREATE POLICY "Users can delete their own artifact versions"
  ON artifact_versions FOR DELETE
  USING (auth.uid() = user_id);

COMMIT;
