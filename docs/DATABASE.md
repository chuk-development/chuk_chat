# Supabase Database Schema

All tables use Row Level Security (RLS) - users can only access their own data.

## Tables

### encrypted_chats
Stores encrypted chat conversations.
```sql
id              UUID PRIMARY KEY
user_id         UUID REFERENCES auth.users
encrypted_payload TEXT  -- AES-256-GCM encrypted JSON (messages, customName)
created_at      TIMESTAMP
updated_at      TIMESTAMP
is_starred      BOOLEAN
image_paths     TEXT[]  -- Supabase Storage paths ("user-uuid/image-uuid.enc")
```
When chat deleted → images in `image_paths` auto-deleted from storage.

### theme_settings
User theme/appearance preferences.
```sql
user_id          UUID PRIMARY KEY REFERENCES auth.users
theme_mode       TEXT  -- 'light', 'dark', 'system'
accent_color     TEXT  -- Hex color
icon_color       TEXT  -- Hex color
background_color TEXT  -- Hex color
grain_enabled    BOOLEAN
```

### customization_preferences
User behavior/functionality preferences.
```sql
user_id                      UUID PRIMARY KEY REFERENCES auth.users
auto_send_voice_transcription BOOLEAN DEFAULT false
show_reasoning_tokens        BOOLEAN DEFAULT true
show_model_info              BOOLEAN DEFAULT true
image_gen_enabled            BOOLEAN DEFAULT false
image_gen_default_size       TEXT DEFAULT 'landscape_4_3'
image_gen_custom_width       INTEGER DEFAULT 1024
image_gen_custom_height      INTEGER DEFAULT 768
image_gen_use_custom_size    BOOLEAN DEFAULT false
```

### user_preferences
General user settings (model selection, system prompts).
```sql
user_id       UUID PRIMARY KEY REFERENCES auth.users
preferences   JSONB
```

### profiles
User profile with credits/free messages.
```sql
user_id              UUID PRIMARY KEY REFERENCES auth.users
display_name         TEXT
credits_remaining    DECIMAL
free_messages_total  INTEGER DEFAULT 10
free_messages_used   INTEGER DEFAULT 0
```

### projects
Project workspaces.
```sql
id                   UUID PRIMARY KEY
user_id              UUID REFERENCES auth.users
name                 TEXT
description          TEXT
custom_system_prompt TEXT
created_at           TIMESTAMP
updated_at           TIMESTAMP
is_archived          BOOLEAN DEFAULT false
```

### project_chats
Many-to-many: projects ↔ chats.
```sql
id         UUID PRIMARY KEY
project_id UUID REFERENCES projects
chat_id    UUID REFERENCES encrypted_chats
added_at   TIMESTAMP
```

### project_files
Encrypted files attached to projects.
```sql
id                UUID PRIMARY KEY
project_id        UUID REFERENCES projects
file_name         TEXT
encrypted_content TEXT
file_type         TEXT
file_size         INTEGER
uploaded_at       TIMESTAMP
```

## RPC Functions

### Free Messages
- `get_free_messages_remaining(p_user_id)` - Returns remaining count
- `increment_free_messages_used(p_user_id)` - Atomically decrements (server-only)

### Credits
- `get_credits_remaining(p_user_id)` - Returns credit balance

## Migrations
Located in `migrations/` folder:
- `free_messages.sql` - Free messages feature
- `projects.sql` - Projects feature
- `image_gen_settings.sql` - Image generation settings
