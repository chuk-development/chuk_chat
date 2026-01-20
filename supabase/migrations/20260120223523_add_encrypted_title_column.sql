-- Add encrypted_title column for instant sidebar loading
-- This allows loading only titles (~5KB) instead of full payloads (~1.1MB)
-- for 57+ chats, reducing startup time from ~500-2000ms to ~50ms

ALTER TABLE encrypted_chats
ADD COLUMN IF NOT EXISTS encrypted_title TEXT;

-- Index for efficient title-only queries
CREATE INDEX IF NOT EXISTS idx_encrypted_chats_title_lookup
ON encrypted_chats (user_id, created_at DESC)
INCLUDE (id, encrypted_title, is_starred, updated_at);

COMMENT ON COLUMN encrypted_chats.encrypted_title IS 'Separately encrypted chat title for fast sidebar loading without decrypting full payload';
