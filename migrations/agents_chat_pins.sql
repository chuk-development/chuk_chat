-- Pinned chats (coworkers / rooms) in the Agents inbox.
--
-- A pin is a per-user preference, not a per-device one: the same pinned rows
-- show on every signed-in device. Local first (SharedPreferences), remote
-- second — this table is what makes the second device agree with the first.
--
-- Pins are one row per (user, item). item_id is an agent id (the host's
-- roster id) or a room id; both are opaque strings the app already treats as
-- unique across both kinds.

CREATE TABLE IF NOT EXISTS agents_chat_pins (
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  item_id TEXT NOT NULL,
  pinned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, item_id)
);

ALTER TABLE agents_chat_pins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users manage their own chat pins" ON agents_chat_pins;
CREATE POLICY "users manage their own chat pins" ON agents_chat_pins
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_agents_chat_pins_user
  ON agents_chat_pins (user_id);
