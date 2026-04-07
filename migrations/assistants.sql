-- ============================================================
-- Assistants Feature Migration
-- ============================================================
-- This migration adds support for custom AI assistants with
-- configurable system prompts and isolated memory settings.
--
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- Table: assistants
-- ============================================================
-- Stores custom AI assistant configurations.
-- Each assistant has its own system prompt and memory settings.
-- ============================================================

CREATE TABLE IF NOT EXISTS assistants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  system_prompt TEXT NOT NULL,
  memory_enabled BOOLEAN NOT NULL DEFAULT true,
  model_id TEXT,                    -- Optional: preferred model for this assistant
  avatar_color TEXT,                -- Optional: hex color for UI
  avatar_icon TEXT,               -- Optional: icon name for UI
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Constraints
  CONSTRAINT name_not_empty CHECK (LENGTH(TRIM(name)) > 0),
  CONSTRAINT system_prompt_not_empty CHECK (LENGTH(TRIM(system_prompt)) > 0)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_assistants_user_id ON assistants(user_id);
CREATE INDEX IF NOT EXISTS idx_assistants_created_at ON assistants(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_assistants_archived ON assistants(is_archived) WHERE is_archived = FALSE;

-- Enable Row Level Security
ALTER TABLE assistants ENABLE ROW LEVEL SECURITY;

-- RLS Policies for assistants table
CREATE POLICY "Users can view their own assistants"
  ON assistants FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own assistants"
  ON assistants FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own assistants"
  ON assistants FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own assistants"
  ON assistants FOR DELETE
  USING (auth.uid() = user_id);

-- ============================================================
-- Table: assistant_chats
-- ============================================================
-- Links chats to specific assistants.
-- A chat can optionally be associated with one assistant.
-- When memory_enabled is false for the assistant, history is
-- stored but not sent to the model.
-- ============================================================

CREATE TABLE IF NOT EXISTS assistant_chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assistant_id UUID NOT NULL REFERENCES assistants(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES encrypted_chats(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Ensure a chat can only be associated with one assistant
  CONSTRAINT unique_chat_assistant UNIQUE(chat_id)
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_assistant_chats_assistant_id ON assistant_chats(assistant_id);
CREATE INDEX IF NOT EXISTS idx_assistant_chats_chat_id ON assistant_chats(chat_id);

-- Enable Row Level Security
ALTER TABLE assistant_chats ENABLE ROW LEVEL SECURITY;

-- RLS Policies for assistant_chats table
CREATE POLICY "Users can view assistant chats for their own assistants"
  ON assistant_chats FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM assistants
      WHERE assistants.id = assistant_chats.assistant_id
      AND assistants.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can link chats to their own assistants"
  ON assistant_chats FOR INSERT
  WITH CHECK (
    -- User must own the assistant
    EXISTS (
      SELECT 1 FROM assistants
      WHERE assistants.id = assistant_chats.assistant_id
      AND assistants.user_id = auth.uid()
    )
    AND
    -- User must also own the chat being linked
    EXISTS (
      SELECT 1 FROM encrypted_chats
      WHERE encrypted_chats.id = assistant_chats.chat_id
      AND encrypted_chats.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can unlink chats from their own assistants"
  ON assistant_chats FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM assistants
      WHERE assistants.id = assistant_chats.assistant_id
      AND assistants.user_id = auth.uid()
    )
  );

-- ============================================================
-- Trigger: Auto-update updated_at timestamp
-- ============================================================

CREATE TRIGGER trigger_assistants_updated_at
  BEFORE UPDATE ON assistants
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- Helper Views (Optional - for analytics/debugging)
-- ============================================================

-- View: Assistant statistics
CREATE OR REPLACE VIEW assistant_stats AS
SELECT
  a.id,
  a.user_id,
  a.name,
  a.memory_enabled,
  a.is_archived,
  COUNT(DISTINCT ac.chat_id) AS chat_count,
  a.created_at,
  a.updated_at
FROM assistants a
LEFT JOIN assistant_chats ac ON a.id = ac.assistant_id
GROUP BY a.id, a.user_id, a.name, a.memory_enabled, a.is_archived, a.created_at, a.updated_at;

-- RLS for view
ALTER VIEW assistant_stats SET (security_invoker = true);

-- ============================================================
-- Migration Complete
-- ============================================================
--
-- Tables created:
--   - assistants (with RLS)
--   - assistant_chats (with RLS)
--
-- Indexes created for optimal query performance
-- Triggers created for auto-updating timestamps
-- Views created for analytics
--
-- Next steps:
--   1. Verify tables in Supabase Dashboard → Database → Tables
--   2. Test RLS policies with sample data
--   3. Implement Flutter services (AssistantStorageService)
--   4. Implement UI pages (AssistantsListPage, AssistantEditorPage)
--
-- ============================================================
