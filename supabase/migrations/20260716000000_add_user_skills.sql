-- User-authored Agent Skills, stored E2E-encrypted.
--
-- Zero knowledge: the whole SKILL.md source (frontmatter + body) lives in one
-- encrypted column. There is deliberately NO plaintext `name` column —
--   * the server would otherwise learn what the user's skills are called, which
--     breaks the same posture the chats table holds (encrypted_payload /
--     encrypted_title), and
--   * AES-GCM uses a random nonce, so a ciphertext name could not carry a
--     UNIQUE constraint anyway.
-- Name uniqueness is enforced client-side against the decrypted set. A user has
-- a handful of skills, all of which are already decrypted into the local cache.
--
-- The `encrypted_` prefix is load-bearing: it is the convention that keeps
-- plaintext from being sent to Supabase by accident (see CLAUDE.md, "Local
-- Cache Architecture").

BEGIN;

-- Idempotent: defined by migrations/user_tool_preferences.sql too, but this
-- migration must not assume that one was applied to this database.
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS public.user_skills (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  encrypted_source TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON COLUMN public.user_skills.encrypted_source IS
  'Encrypted SKILL.md source (YAML frontmatter + markdown body), client-managed. '
  'Never plaintext. Parsed by skill_frontmatter_parser.dart after decryption.';

CREATE INDEX IF NOT EXISTS idx_user_skills_user_id
  ON public.user_skills(user_id);

ALTER TABLE public.user_skills ENABLE ROW LEVEL SECURITY;

-- Policies use `(select auth.uid())`, not bare `auth.uid()`: the bare form is
-- re-evaluated per row and trips the Supabase auth_rls_initplan linter, which
-- 20260129000001_fix_rls_initplan_performance.sql retrofitted every other table
-- to avoid.

DROP POLICY IF EXISTS "Users can view their own skills" ON public.user_skills;
CREATE POLICY "Users can view their own skills"
  ON public.user_skills FOR SELECT
  USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can insert their own skills" ON public.user_skills;
CREATE POLICY "Users can insert their own skills"
  ON public.user_skills FOR INSERT
  WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update their own skills" ON public.user_skills;
CREATE POLICY "Users can update their own skills"
  ON public.user_skills FOR UPDATE
  USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can delete their own skills" ON public.user_skills;
CREATE POLICY "Users can delete their own skills"
  ON public.user_skills FOR DELETE
  USING (user_id = (select auth.uid()));

DROP TRIGGER IF EXISTS trigger_user_skills_updated_at ON public.user_skills;
CREATE TRIGGER trigger_user_skills_updated_at
  BEFORE UPDATE ON public.user_skills
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

COMMIT;
