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
- `lib/widgets/free_message_display.dart` - UI widgets
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
- `lib/models/project_model.dart` - Data models
- `lib/services/project_storage_service.dart` - CRUD operations
- `lib/services/project_message_service.dart` - Inject context into AI
- `lib/pages/projects_page.dart` - Projects list
- `lib/pages/project_detail_page.dart` - Project detail (tabs)
- `lib/pages/project_management_page.dart` - Mobile project management
- `lib/widgets/project_panel.dart` - Right-side settings panel (desktop)
- `lib/widgets/project_file_viewer.dart` - File viewer dialog
- `lib/widgets/project_selection_dropdown.dart` - Project dropdown in chat

**Flag:** `--dart-define=FEATURE_PROJECTS=true`

## Image Generation
AI Image Generation via Z-Image Turbo API (fal.ai).

**Features:**
- Generate from text prompts in chat
- Toggle button (sparkle icon) switches modes
- Size presets or custom dimensions
- Images encrypted and stored in Supabase

**Size Presets:**
| Preset | Dimensions | ~Cost EUR |
|--------|------------|-----------|
| square_hd | 1024×1024 | 0.01 |
| landscape_4_3 | 1024×768 | 0.01 |
| portrait_4_3 | 768×1024 | 0.01 |

**Files:**
- `lib/services/image_generation_service.dart` - API calls, storage
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

**Flag:** `--dart-define=FEATURE_MEDIA_MANAGER=true`

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
- `lib/utils/grain_overlay.dart` - Grain effect

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
