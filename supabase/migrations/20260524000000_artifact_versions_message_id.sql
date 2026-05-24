-- Track which chat message produced each artifact version snapshot.
--
-- Used by the resend / regenerate flow to roll back versions emitted by
-- the discarded AI message(s): the rollback finds snapshots whose
-- `message_id` is in the discarded set, deletes those snapshot rows,
-- then resets `artifacts.content/version/attachment_path` to the latest
-- remaining snapshot (or deletes the artifact entirely if no prior
-- snapshot exists).
--
-- `ON DELETE SET NULL` keeps history intact when the originating message
-- is hard-deleted via other paths — the snapshot is still valid, just
-- no longer attributable to a live message.
ALTER TABLE artifact_versions
  ADD COLUMN IF NOT EXISTS message_id text;

-- Index supports the per-rollback `WHERE message_id IN (...)` lookup.
CREATE INDEX IF NOT EXISTS artifact_versions_message_id_idx
  ON artifact_versions (message_id)
  WHERE message_id IS NOT NULL;
