# Features

## Free Messages
Non-subscribed users get **10 free messages** (lifetime, never reset).

**Flow:**
1. User sends message
2. Server checks credits (subscribed users)
3. If no credits → check free messages
4. If none → HTTP 402 error
5. On success → decrement count

**Files:**
- `migrations/free_messages.sql` - Database migration

## Projects
Workspaces for organizing chats with custom AI behavior.

**Features:**
- Custom name, description, system prompt
- Add existing chats to projects
- Upload encrypted files as context
- Files included in AI messages (up to 50KB)
- Project panel for managing files and instructions
- Mobile-friendly project management page

**Files:**
- `lib/models/workspace_model.dart` - Data models (`Workspace`, `WorkspaceFile`)
- `lib/services/workspace_storage_service.dart` - CRUD operations
- `lib/services/workspace_message_service.dart` - Inject context into AI
- `lib/pages/workspaces_page.dart` - Workspaces list
- `lib/pages/workspace_detail_page.dart` - Workspace detail (tabs)
- `lib/pages/workspace_management_page.dart` - Mobile workspace management
- `lib/widgets/workspace_panel.dart` - Right-side settings panel (desktop)
- `lib/widgets/workspace_file_viewer.dart` - File viewer dialog
- `lib/widgets/workspace_selection_dropdown.dart` - Workspace dropdown in chat

**Switch:** a user setting, Settings > Personalization > Workspaces, off by
default (`lib/services/settings/workspaces_setting.dart`, stored per device).
There is no build flag: `FEATURE_WORKSPACES` and `FEATURE_PROJECTS` are gone.

## Image Generation
AI image generation through the `generate_image` tool. The API server
(`POST /v1/ai/image/generate`, form field `model`) runs every model on
OpenRouter with Zero Data Retention.

**Models** (`model` key, ~cost per 1 MP image, server bills the real price):
| Key | Model | ~Cost EUR | Use |
|-----|-------|-----------|-----|
| `krea` (default) | Krea 2 Large | 0.06 | Main model, high quality text-to-image |
| `turbo` | Krea 2 Medium Turbo | 0.015 | Fast, cheap |
| `hunyuan` | Hunyuan Image 3.5 | 0.01 | Open weights |
| `seedream` | Seedream 5 Lite | 0.04 | Best text / typography |
| `edit` | Krea K3 Edit | 0.02 per input image + output | Image-to-image only; `image_url` required (up to 8 URLs, one per line) |

Old keys still work as aliases: `quality`/`flux` -> `krea`, `ideogram` ->
`seedream`, `k3` -> `edit` (`normalizeImageModel` in
`lib/tool_handlers/image_tools.dart`).

**Size:** `aspect_ratio` (1:1, 16:9, ...) or an `image_size` preset
(square_hd, landscape_4_3, portrait_4_3, ...).

**Files:**
- `lib/pages/customization_page.dart` - Settings UI

**Flag:** `--dart-define=FEATURE_IMAGE_GEN=true`

## Media Manager
View and manage stored images in Supabase Storage.

**Features:**
- Grid view of all encrypted images
- Multi-select for batch deletion
- Warning if image used in chats
- "Image deleted" placeholder in chats

**Files:**
- `lib/pages/media_manager_page.dart` - Main UI
- `lib/services/image_storage_service.dart` - `listUserImages()`, `findChatsUsingImage()`
- `lib/widgets/encrypted_image_widget.dart` - Deletion listener

**How it works:**
1. Lists `.enc` files in `images/{user_id}/`
2. Decrypts and shows thumbnails
3. On delete: queries `encrypted_chats.image_paths` for references
4. Shows warning with chat names if used
5. After deletion: widgets show "Image deleted" placeholder


## Voice Transcription
Audio recording with transcription.

**Features:**
- Record audio with level monitoring
- Upload for transcription
- Optional auto-send after transcription

**Files:**
- `lib/platform_specific/chat/handlers/audio_recording_handler.dart`
- Auto-send logic: `chat_ui_mobile.dart:~500`

## Theme Customization
Full theme customization with Supabase sync.

**Features:**
- Accent, icon, background colors
- Light/dark/system mode
- Film grain overlay

**Files:**
- `lib/pages/theme_page.dart` - Settings UI
- `lib/services/theme_settings_service.dart` - Sync service

## Auto Title Generation
AI-powered automatic chat title generation.

**Features:**
- Generates concise 2-6 word titles based on first message
- Uses Qwen3-8b model via Fireworks (fast and cheap)
- Customizable system prompt
- Toggle in customization settings

**Files:**
- `lib/services/title_generation_service.dart` - Title generation service
- `lib/pages/customization_page.dart` - Settings toggle

## Security Features

**Certificate Pinning:**
- SSL certificate pinning for API requests
- Protection against MITM attacks in production

**Rate Limiting:**
- API rate limiting to prevent abuse
- Upload rate limiting (10 uploads per 5 minutes)

**Files:**
- `lib/utils/certificate_pinning.dart` - SSL pinning implementation
- `lib/utils/api_rate_limiter.dart` - API rate limiting
- `lib/utils/upload_rate_limiter.dart` - Upload rate limiting

## Desktop tray menu (`FEATURE_SYSTEM_TRAY`)

Menu content is plain data from `buildTrayMenu`
(`lib/services/tray_menu_model.dart`): New chat, Chats/Agents (Agents build
only), the last 5 chats, Show/Hide window, Settings, Quit. The native menu is
rebuilt (debounced) when chats, window state, UI language or app mode change.
Clicks reach the UI through `TrayActionBus`. A left click shows the window.

Trap: nativeapi (tray_manager 0.8) exports the Linux dbusmenu only when the
trigger is `clicked` or `rightClicked`. With the default `none` the item
announces `/NO_DBUSMENU` and the panel shows an empty menu. So
`setContextMenuTrigger` runs on every platform.

Headless check on Linux: own Xvfb, own session bus (`dbus-run-session`), a
fake `org.kde.StatusNotifierWatcher`, then `com.canonical.dbusmenu.GetLayout`
on `/StatusNotifierItem/Menu`. Run the app with `CHUK_MULTI_INSTANCE=1` and a
separate `HOME`, never with the owner's session.
