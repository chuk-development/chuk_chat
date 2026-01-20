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
name                 TEXT NOT NULL
description          TEXT
custom_system_prompt TEXT
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
file_name         TEXT NOT NULL
storage_path      TEXT NOT NULL  -- Path in Supabase storage bucket
file_type         TEXT NOT NULL
file_size         INTEGER (max 10MB)
uploaded_at       TIMESTAMPTZ
markdown_summary  TEXT  -- AI-generated markdown summary (optional)
```

**RLS Policies:**
- SELECT: User owns the project
- INSERT: User owns the project
- DELETE: User owns the project

Files stored encrypted in `project-files` bucket.

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
- Chat messages (`encrypted_payload`)
- Images (stored as encrypted blobs in Storage)
- Project files (stored as encrypted blobs in Storage)

The encryption key is derived from the user's password using PBKDF2 with 600,000 iterations.
