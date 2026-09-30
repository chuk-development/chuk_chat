-- A version stamp for project_files, like projects and artifacts have.
-- The app re-seals a row only if it is unchanged since it read it
-- (`.eq('updated_at', <read value>)`), so a background re-seal never writes
-- stale values over another device's newer edit. Old app builds select `*`
-- and ignore the extra column.

ALTER TABLE project_files
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION public.set_project_files_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_project_files_updated_at ON project_files;
CREATE TRIGGER trg_set_project_files_updated_at
  BEFORE UPDATE ON project_files
  FOR EACH ROW EXECUTE FUNCTION public.set_project_files_updated_at();
