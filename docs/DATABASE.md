# Supabase Database Schema

All tables use Row Level Security (RLS) - users can only access their own data.

## Setup

Run migrations in order:
1. `migrations/00_base_schema.sql` - Base tables, RLS policies, and RPC functions
2. `migrations/projects.sql` - Projects feature (optional)
3. `migrations/images_storage.sql` - Image bucket RLS policies
4. `migrations/project_files_storage.sql` - Project files bucket RLS policies (if using projects)

## Storage Buckets

Create these buckets in Supabase Dashboard → Storage (all must be **private**):
- `images` - Encrypted chat images
- `project-files` - Encrypted project file attachments (if using projects feature)

## Tables

### profiles
User profile with credits and free messages tracking.
```sql
id                    UUID PRIMARY KEY REFERENCES auth.users
display_name          TEXT
credits_remaining     DECIMAL DEFAULT 0
free_messages_total   INTEGER DEFAULT 10
free_messages_used    INTEGER DEFAULT 0
notifications_enabled BOOLEAN DEFAULT true
weekly_summary_enabled BOOLEAN DEFAULT false
created_at            TIMESTAMPTZ
updated_at            TIMESTAMPTZ
```

**RLS Policies:**
- SELECT: `auth.uid() = id`
- INSERT: `auth.uid() = id`
- UPDATE: `auth.uid() = id`

### encrypted_chats
Stores encrypted chat conversations.
```sql
id                UUID PRIMARY KEY
user_id           UUID REFERENCES auth.users
encrypted_payload TEXT  -- AES-256-GCM encrypted JSON (messages, customName)
created_at        TIMESTAMPTZ
updated_at        TIMESTAMPTZ
is_starred        BOOLEAN DEFAULT false
image_paths       TEXT[]  -- Supabase Storage paths ("user-uuid/image-uuid.enc")
```

**RLS Policies:**
- SELECT: `auth.uid() = user_id`
- INSERT: `auth.uid() = user_id`
- UPDATE: `auth.uid() = user_id`
- DELETE: `auth.uid() = user_id`

When chat deleted → images in `image_paths` should be manually deleted from storage.

### theme_settings
User theme/appearance preferences.
```sql
user_id          UUID PRIMARY KEY REFERENCES auth.users
theme_mode       TEXT  -- 'light', 'dark', 'system'
accent_color     TEXT  -- Hex color
icon_color       TEXT  -- Hex color
background_color TEXT  -- Hex color
grain_enabled    BOOLEAN DEFAULT true
created_at       TIMESTAMPTZ
updated_at       TIMESTAMPTZ
```

**RLS Policies:**
- SELECT: `auth.uid() = user_id`
- INSERT: `auth.uid() = user_id`
- UPDATE: `auth.uid() = user_id`

### customization_preferences
User behavior/functionality preferences.
```sql
user_id                       UUID PRIMARY KEY REFERENCES auth.users
auto_send_voice_transcription BOOLEAN DEFAULT false
show_reasoning_tokens         BOOLEAN DEFAULT true
show_model_info               BOOLEAN DEFAULT true
image_gen_enabled             BOOLEAN DEFAULT false
image_gen_default_size        TEXT DEFAULT 'landscape_4_3'
image_gen_custom_width        INTEGER DEFAULT 1024
image_gen_custom_height       INTEGER DEFAULT 768
image_gen_use_custom_size     BOOLEAN DEFAULT false
onboarding_completed          BOOLEAN DEFAULT false  -- tour shown once per user
created_at                    TIMESTAMPTZ
updated_at                    TIMESTAMPTZ
```

**RLS Policies:**
- SELECT: `auth.uid() = user_id`
- INSERT: `auth.uid() = user_id`
- UPDATE: `auth.uid() = user_id`

### user_preferences
General user settings (model selection, system prompts).
```sql
user_id       UUID PRIMARY KEY REFERENCES auth.users
preferences   JSONB DEFAULT '{}'
created_at    TIMESTAMPTZ
updated_at    TIMESTAMPTZ
```

**RLS Policies:**
- SELECT: `auth.uid() = user_id`
- INSERT: `auth.uid() = user_id`
- UPDATE: `auth.uid() = user_id`

### projects
Project workspaces (requires `projects.sql` migration).
```sql
id                   UUID PRIMARY KEY
user_id              UUID REFERENCES auth.users
name                 TEXT NOT NULL  -- '🔒' placeholder; real name in encrypted_meta
description          TEXT           -- NULL; real value in encrypted_meta
custom_system_prompt TEXT           -- NULL; real value in encrypted_meta
encrypted_meta       TEXT           -- AES-GCM envelope {v, tbl, row, name, description, custom_system_prompt}
created_at           TIMESTAMPTZ
updated_at           TIMESTAMPTZ
is_archived          BOOLEAN DEFAULT false
```

**RLS Policies:**
- SELECT: `auth.uid() = user_id`
- INSERT: `auth.uid() = user_id`
- UPDATE: `auth.uid() = user_id`
- DELETE: `auth.uid() = user_id`

### project_chats
Many-to-many: projects ↔ chats.
```sql
id         UUID PRIMARY KEY
project_id UUID REFERENCES projects ON DELETE CASCADE
chat_id    UUID REFERENCES encrypted_chats ON DELETE CASCADE
added_at   TIMESTAMPTZ
UNIQUE(project_id, chat_id)
```

**RLS Policies:**
- SELECT: User owns the project
- INSERT: User owns BOTH the project AND the chat
- DELETE: User owns the project

### project_files
Encrypted files attached to projects.
```sql
id                UUID PRIMARY KEY
project_id        UUID REFERENCES projects ON DELETE CASCADE
file_name         TEXT NOT NULL  -- '🔒' placeholder; real name in encrypted_meta
storage_path      TEXT NOT NULL  -- Path in Supabase storage bucket
file_type         TEXT NOT NULL
file_size         INTEGER (max 10MB)
uploaded_at       TIMESTAMPTZ
markdown_summary  TEXT  -- NULL; the file text lives in encrypted_meta
encrypted_meta    TEXT  -- AES-GCM envelope {v, tbl, row, file_name, markdown_summary}
updated_at        TIMESTAMPTZ  -- stamped by trigger; re-seal writes guard on it
```

**RLS Policies:**
- SELECT: User owns the project
- INSERT: User owns the project
- DELETE: User owns the project

Files stored encrypted in `project-files` bucket.

### artifacts / artifact_versions
Editable code/markdown/HTML/drawing panels and their version history.
```sql
-- artifacts
id              TEXT PRIMARY KEY  -- random UUID; legacy rows: the AI slug
chat_id         UUID REFERENCES encrypted_chats ON DELETE CASCADE
user_id         UUID REFERENCES auth.users ON DELETE CASCADE
title           TEXT NOT NULL     -- '🔒' placeholder; real title in encrypted_meta
type            TEXT NOT NULL     -- code | markdown | html | ...
language        TEXT              -- NULL; real value in encrypted_meta
content         TEXT NOT NULL     -- AES-GCM envelope
encrypted_meta  TEXT              -- AES-GCM envelope {v, tbl, row, handle, title, language}
version, is_active, message_id, attachment_path, created_at, updated_at
-- artifact_versions
artifact_id     TEXT REFERENCES artifacts(id) ON DELETE CASCADE ON UPDATE CASCADE
content         TEXT NOT NULL     -- AES-GCM envelope
```

The handle is the name the AI uses (`todo-app`). The app resolves it to the
row id on the client and never sends it to the server as a filter.

## Storage RLS Policies

### images bucket
```sql
-- All operations check: bucket_id = 'images' AND auth.uid()::text = folder_name
INSERT: User can upload to their own folder
SELECT: User can read from their own folder
UPDATE: User can update in their own folder
DELETE: User can delete from their own folder
```

### project-files bucket
```sql
-- All operations check: bucket_id = 'project-files' AND auth.uid()::text = folder_name
INSERT: User can upload to their own folder
SELECT: User can read from their own folder
UPDATE: User can update in their own folder
DELETE: User can delete from their own folder
```

## RPC Functions

### Free Messages
- `get_free_messages_remaining(p_user_id)` - Returns remaining count (only for own user)
- `increment_free_messages_used(p_user_id)` - Atomically decrements (service role only)

### Credits
- `get_credits_remaining(p_user_id)` - Returns credit balance (only for own user)

**Security Notes:**
- `get_free_messages_remaining` and `get_credits_remaining` verify `p_user_id = auth.uid()`
- `increment_free_messages_used` is restricted to `service_role` only

## Migrations

Located in `migrations/` folder:

| File | Description | Prerequisites |
|------|-------------|---------------|
| `00_base_schema.sql` | Base tables + RLS + functions | None |
| `projects.sql` | Projects feature | `00_base_schema.sql` |
| `images_storage.sql` | Image bucket RLS | `images` bucket created |
| `project_files_storage.sql` | Project files bucket RLS | `project-files` bucket created |
| `free_messages.sql` | Add free messages to existing profiles | For existing deployments |
| `project_files_markdown.sql` | Add markdown column | For existing projects deployments |
| `image_gen_settings.sql` | Add image gen settings | For existing deployments |

## Encryption

All sensitive data is encrypted client-side using AES-256-GCM before being stored:
- Chat messages (`encrypted_payload`) and titles (`encrypted_title`)
- Images (stored as encrypted blobs in Storage)
- Project files (stored as encrypted blobs in Storage)
- Row metadata in `encrypted_meta` (`lib/services/encrypted_meta.dart`):
  artifact handle/title/language, project name/description/system prompt,
  project file name and text

**`encrypted_meta` and old app builds.** The server cannot encrypt (zero
knowledge), so the app seals rows itself: new rows are written sealed, and
each app re-seals the signed-in user's legacy rows in the background when it
loads them. The plaintext columns keep a `'🔒'` placeholder (they carry
non-empty CHECK constraints, and old builds still read them). Old builds keep
writing plaintext; on read, a real plaintext value (not empty, not `'🔒'`)
wins over the sealed one, and the row is re-sealed on the next load.
Every envelope names its row (`tbl` + `row` = table and row id), and the app
refuses an envelope found on any other row: the server cannot move sealed
metadata between rows of the same user. So a row id is chosen on the client
before the insert, and an artifact that gets a new id is sealed again in the
same write.
Migration: `supabase/migrations/20260930000000_encrypted_meta_artifacts_projects.sql`
(apply it before the app ships; it also contains the progress query) and
`20260930010000_project_files_updated_at.sql`. Every re-seal write filters
on the `updated_at` it read, so it never overwrites a newer edit made on
another device in between.

The encryption key is derived from the user's password using PBKDF2 with 600,000 iterations.
