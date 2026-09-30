-- Move row metadata that was stored as plaintext into one E2E-encrypted
-- envelope per row (`encrypted_meta`). The server cannot encrypt (zero
-- knowledge), so the app seals the rows itself: new rows are written sealed,
-- and each app re-seals the signed-in user's legacy rows when it loads them.
--
--   artifacts      handle (the AI-chosen slug), title, language
--   projects       name, description, custom_system_prompt
--   project_files  file_name, markdown_summary (the full text of the file)
--
-- The plaintext columns stay: a sealed row writes the placeholder '🔒' into
-- the NOT NULL / non-empty ones (projects.name, project_files.file_name,
-- artifacts.title) and NULL into the others. Older app builds still read
-- them. This migration is additive and safe to apply before the app ships.

ALTER TABLE artifacts     ADD COLUMN IF NOT EXISTS encrypted_meta text;
ALTER TABLE projects      ADD COLUMN IF NOT EXISTS encrypted_meta text;
ALTER TABLE project_files ADD COLUMN IF NOT EXISTS encrypted_meta text;

-- artifacts.id was the AI-chosen slug and a global primary key: it leaked
-- the name and collided across users. Sealed rows use a random UUID. The app
-- rewrites a legacy row's id in place; its version rows must follow.
ALTER TABLE artifact_versions
  DROP CONSTRAINT IF EXISTS artifact_versions_artifact_id_fkey;
-- NOT VALID + VALIDATE splits the add from the table scan. Inside one
-- transaction (as here) the scan still runs under the add's lock, which
-- blocks writes; artifact_versions is small, so that is a short pause.
ALTER TABLE artifact_versions
  ADD CONSTRAINT artifact_versions_artifact_id_fkey
  FOREIGN KEY (artifact_id) REFERENCES artifacts(id)
  ON DELETE CASCADE ON UPDATE CASCADE
  NOT VALID;
ALTER TABLE artifact_versions
  VALIDATE CONSTRAINT artifact_versions_artifact_id_fkey;

-- Re-sealing a row is not an edit: it must not move the artifact to the top
-- of "most recently updated". A write that changes only the id and the
-- metadata columns keeps the old updated_at; every other write stamps now().
CREATE OR REPLACE FUNCTION public.set_artifacts_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- Compare every column except the ones a re-seal writes, so the check
  -- does not depend on the exact column list of this deployment.
  IF NEW.encrypted_meta IS DISTINCT FROM OLD.encrypted_meta
     AND (to_jsonb(NEW) - 'id' - 'title' - 'language' - 'encrypted_meta'
          - 'updated_at')
       = (to_jsonb(OLD) - 'id' - 'title' - 'language' - 'encrypted_meta'
          - 'updated_at') THEN
    NEW.updated_at = OLD.updated_at;
    RETURN NEW;
  END IF;
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Same for projects: the first seal of a legacy row keeps its updated_at.
-- update_timestamp() is shared with customization_preferences, so projects
-- get their own function.
CREATE OR REPLACE FUNCTION public.set_projects_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF OLD.encrypted_meta IS NULL
     AND NEW.encrypted_meta IS NOT NULL
     AND (to_jsonb(NEW) - 'name' - 'description' - 'custom_system_prompt'
          - 'encrypted_meta' - 'updated_at')
       = (to_jsonb(OLD) - 'name' - 'description' - 'custom_system_prompt'
          - 'encrypted_meta' - 'updated_at') THEN
    NEW.updated_at = OLD.updated_at;
    RETURN NEW;
  END IF;
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_project_timestamp ON projects;
CREATE TRIGGER trigger_update_project_timestamp
  BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION public.set_projects_updated_at();

-- Progress check (run by hand, not part of the migration):
--   SELECT
--     (SELECT count(*) FROM artifacts     WHERE encrypted_meta IS NULL) AS artifacts_left,
--     (SELECT count(*) FROM projects      WHERE encrypted_meta IS NULL) AS projects_left,
--     (SELECT count(*) FROM project_files WHERE encrypted_meta IS NULL) AS files_left;
