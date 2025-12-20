# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**chuk_chat** is a cross-platform Flutter chat application (v1.0.1) with multi-platform support for Linux (DEB, RPM, AppImage), Android (APK), and mobile platforms. The app features:

- Real-time chat with AI models
- End-to-end encryption for chat storage
- Supabase backend for authentication and data persistence
- Platform-adaptive UI (separate desktop and mobile implementations)
- Theme customization with film grain overlay support
- File attachments and image handling
- Model selection with prefetching and caching

## Build Commands

### Development
```bash
# Run the app (auto-detects platform)
flutter run

# Run with specific device
flutter run -d linux
flutter run -d android

# Run with platform-specific optimization (smaller binary)
flutter run -d linux --dart-define=PLATFORM_DESKTOP=true
flutter run -d android --dart-define=PLATFORM_MOBILE=true

# Clean build artifacts
flutter clean

# Get dependencies
flutter pub get

# Analyze code for issues
flutter analyze

# Format code
dart format .
```

### Testing
```bash
# Run tests (currently no test files present)
flutter test

# Run with coverage
flutter test --coverage
```

### Release Builds

All release builds are handled by the unified `build.sh` script with **automatic tree-shaking optimization**:

```bash
# FAST: Build single APK for arm64-v8a only (recommended for development/testing - ~30 seconds)
flutter build apk --dart-define=PLATFORM_MOBILE=true --tree-shake-icons --target-platform android-arm64

# Build all packages (Linux + Android) - OPTIMIZED (~2 minutes)
./build.sh all

# Build specific targets - OPTIMIZED
./build.sh linux      # All Linux packages (DEB, RPM, AppImage) - Mobile code excluded
./build.sh deb        # DEB packages only (amd64, arm64) - Mobile code excluded
./build.sh rpm        # RPM packages only (amd64, arm64) - Mobile code excluded
./build.sh appimage   # AppImage packages only (amd64, arm64) - Mobile code excluded
./build.sh apk        # Android APKs with --split-per-abi (all architectures) - Desktop code excluded (~2 minutes)
```

**IMPORTANT**: For iterative development and testing, use the fast single-architecture build command above. Only use `./build.sh apk` for final releases.

**Tree-Shaking Optimization:**
- Linux builds: Mobile-specific code (root_wrapper_mobile.dart, chat_ui_mobile.dart, etc.) is automatically excluded
- Android builds: Desktop-specific code (root_wrapper_desktop.dart, chat_ui_desktop.dart, etc.) is automatically excluded
- Result: Smaller binaries and faster load times!
- See TREE_SHAKING.md for detailed documentation

**Output Location**: All built packages are placed in `releases/linux/` and `releases/android/`

**Build Requirements**:
- For Linux packages: `dpkg-dev`, optionally `rpm` and `appimagetool`
- For Android: Android SDK, NDK 26.3.11579264+, compileSdkVersion 36, minSdkVersion 24
- See BUILD.md for complete setup instructions

**Manual Optimized Builds:**
```bash
# Linux with tree-shaking (mobile code excluded)
flutter build linux --dart-define=PLATFORM_DESKTOP=true --tree-shake-icons

# Android with tree-shaking (desktop code excluded)
flutter build apk --dart-define=PLATFORM_MOBILE=true --tree-shake-icons --split-per-abi
```

## Architecture

### Platform Abstraction Layer

The app uses a **platform-specific architecture with tree-shaking optimization** to adapt UI and behavior across desktop and mobile:

- **Entry Point**: `lib/main.dart` - Uses unified `RootWrapper` for all platforms
- **Platform Configuration**: `lib/platform_config.dart` - Compile-time constants for tree-shaking
  - `kPlatformMobile` - Set via `--dart-define=PLATFORM_MOBILE=true`
  - `kPlatformDesktop` - Set via `--dart-define=PLATFORM_DESKTOP=true`
  - `kAutoDetectPlatform` - Runtime detection when not explicitly set

- **Feature Flags**: `lib/platform_config.dart` - Compile-time feature toggles
  - `kFeatureVoiceMode` - Voice Mode "Coming Soon" button (default: false) - Note: Mic/transcription always works
  - `kFeatureProjects` - Project workspaces (default: false)
  - `kFeatureAssistants` - Custom AI assistants (default: false)
  - `kFeatureImageGen` - AI Image Generation via Z-Image Turbo (default: false)
  - Enable with: `--dart-define=FEATURE_VOICE_MODE=true --dart-define=FEATURE_PROJECTS=true --dart-define=FEATURE_IMAGE_GEN=true`

- **Root Wrappers** (Conditional Imports with Tree-Shaking):
  - `lib/platform_specific/root_wrapper.dart` - Export with conditional imports
  - `lib/platform_specific/root_wrapper_io.dart` - Platform detection with tree-shaking
  - `lib/platform_specific/root_wrapper_desktop.dart` - Desktop layout orchestrator
  - `lib/platform_specific/root_wrapper_mobile.dart` - Mobile layout orchestrator
  - `lib/platform_specific/root_wrapper_stub.dart` - Fallback (unused)

- **UI Components**:
  - `lib/platform_specific/chat/chat_ui_desktop.dart` - Desktop chat interface
  - `lib/platform_specific/chat/chat_ui_mobile.dart` - Mobile chat interface
  - `lib/platform_specific/sidebar_desktop.dart` - Desktop navigation sidebar
  - `lib/platform_specific/sidebar_mobile.dart` - Mobile navigation drawer

**Tree-Shaking Flow:**
```
Desktop Build (--dart-define=PLATFORM_DESKTOP=true):
  main.dart → RootWrapper → root_wrapper_io.dart
    → [kPlatformDesktop=true] → RootWrapperDesktop ✓
    → [kPlatformMobile=false] → RootWrapperMobile ✗ (removed by tree-shaker)

Mobile Build (--dart-define=PLATFORM_MOBILE=true):
  main.dart → RootWrapper → root_wrapper_io.dart
    → [kPlatformMobile=true] → RootWrapperMobile ✓
    → [kPlatformDesktop=false] → RootWrapperDesktop ✗ (removed by tree-shaker)
```

**Key Breakpoint**: `kTabletBreakpoint = 800.0` - Screens below this width on mobile platforms use mobile UI (in auto-detect mode)

### Core Services Architecture

Services are organized in `lib/services/` and follow a **singleton-like pattern** with static methods or const constructors:

1. **Authentication & Security**:
   - `SupabaseService` - Core Supabase initialization and auth management (initialized in main.dart)
   - `AuthService` - Login, signup, and authentication flows
   - `EncryptionService` - Client-side encryption for chat storage using cryptography package
   - `PasswordRevisionService` - Password change detection and forced logout
   - `PasswordChangeService` - Password update functionality

2. **Chat & Storage**:
   - `ChatStorageService` - Local chat persistence with encryption
   - `ChatSyncService` - Background sync between devices (polls every 5s)
   - `StreamingChatService` - Real-time chat message streaming
   - `LocalChatCacheService` - Local caching of chat data
   - `ChatApiService` (platform_specific) - API communication layer

3. **Model Management**:
   - `ModelPrefetchService` - Preloads available AI models on login
   - `ModelCacheService` - Caches model data locally
   - `ModelCapabilitiesService` - Tracks model features and limits

4. **Configuration & State**:
   - `ThemeSettingsService` - Syncs theme/appearance preferences between local and Supabase
   - `CustomizationPreferencesService` - Syncs customization/behavior preferences between local and Supabase
   - `UserPreferencesService` - User settings persistence
   - `ApiConfigService` - API configuration management
   - `ApiStatusService` - API health monitoring
   - `NetworkStatusService` - Network connectivity monitoring
   - `ProfileService` - User profile management

### State Management

- **Theme State**: Managed at `ChukChatApp` level in `main.dart`
  - Uses `SharedPreferences` for local persistence
  - Syncs with Supabase via `ThemeSettingsService`
  - Includes accent color, icon color, background color, theme mode, and grain overlay
- **Customization State**: Managed at `ChukChatApp` level in `main.dart`
  - Uses `SharedPreferences` for local persistence
  - Syncs with Supabase via `CustomizationPreferencesService`
  - Includes auto-send voice transcription, show reasoning tokens, and show model info
  - Settings accessible via Settings → Customization page
- **Auth State**: Managed via Supabase `auth.onAuthStateChange` stream in `main.dart`
  - Automatically loads encryption keys and chat data on login
  - Clears sensitive data on logout
  - Enforces password revision checks
- **Chat State**: Managed in `ChatStorageService` with encrypted local storage
- **Platform State**: Determined at runtime in `AuthGate` based on `defaultTargetPlatform` and screen width

### Authentication Flow

1. App initializes Supabase in `main.dart`
2. `AuthGate` widget checks authentication state
3. If unauthenticated: Shows `LoginPage`
4. On successful login:
   - `PasswordRevisionService` checks for forced logout conditions
   - `EncryptionService.tryLoadKey()` loads encryption key
   - `ChatStorageService.loadSavedChatsForSidebar()` loads encrypted chats
   - `ChatSyncService.start()` begins background sync (5s polling interval)
   - `ModelPrefetchService.prefetch()` loads available models
   - Theme settings loaded from Supabase via `ThemeSettingsService`
   - Customization preferences loaded from Supabase via `CustomizationPreferencesService`
5. Platform-appropriate root wrapper is displayed
6. On logout: `ChatSyncService.stop()` stops background sync

### Data Models

Key models in `lib/models/`:
- `ModelItem` - Represents an AI model with name, id, and optional badge/toggle
- `AttachedFile` - Represents file attachments with upload state and markdown content
- Chat models stored as encrypted JSON via `ChatStorageService`

### Supabase Configuration

- Configuration in `lib/supabase_config.dart`
- Supports compile-time environment variables: `SUPABASE_URL`, `SUPABASE_ANON_KEY`
- Falls back to hardcoded values if env vars not provided

### Supabase Database Schema

The app uses the following Supabase tables:

1. **theme_settings** - Stores user theme/appearance preferences
   - Columns: `user_id`, `theme_mode`, `accent_color`, `icon_color`, `background_color`, `grain_enabled`
   - Synced via `ThemeSettingsService`

2. **customization_preferences** - Stores user customization/behavior preferences
   - Columns: `user_id`, `auto_send_voice_transcription`, `show_reasoning_tokens`, `show_model_info`
   - Synced via `CustomizationPreferencesService`
   - Defaults: `auto_send_voice_transcription=false`, `show_reasoning_tokens=true`, `show_model_info=true`

3. **user_preferences** - Stores user settings (model selection, system prompts, etc.)
   - Managed via `UserPreferencesService`

4. **projects** - Stores project workspaces (NEW)
   - Columns: `id`, `user_id`, `name`, `description`, `custom_system_prompt`, `created_at`, `updated_at`, `is_archived`
   - Managed via `ProjectStorageService`
   - See `migrations/projects.sql` for full schema

5. **project_chats** - Many-to-many relationship between projects and chats (NEW)
   - Columns: `id`, `project_id`, `chat_id`, `added_at`
   - Links chats to project workspaces

6. **project_files** - Encrypted file attachments for projects (NEW)
   - Columns: `id`, `project_id`, `file_name`, `encrypted_content`, `file_type`, `file_size`, `uploaded_at`
   - Files are encrypted client-side before upload

7. **encrypted_chats** - Stores encrypted chat conversations
   - Columns: `id`, `user_id`, `encrypted_payload`, `created_at`, `is_starred`, `image_paths`
   - `encrypted_payload`: AES-256-GCM encrypted JSON containing messages and customName
   - `image_paths`: text[] array of Supabase Storage paths for images (e.g., "user-uuid/image-uuid.enc")
   - When a chat is deleted, images in `image_paths` are automatically deleted from storage
   - Managed via `ChatStorageService`

All tables use Row Level Security (RLS) with policies ensuring users can only access their own data.

### Free Messages Feature

Non-subscribed users get **10 free messages** (lifetime, never reset). Once a user subscribes, they use credits instead.

**Database Columns (in `profiles` table)**:
- `free_messages_total` (INTEGER, default 10) - Maximum free messages
- `free_messages_used` (INTEGER, default 0) - Messages consumed

**RPC Functions**:
- `get_free_messages_remaining(p_user_id)` - Returns remaining count (callable by authenticated users)
- `increment_free_messages_used(p_user_id)` - Atomically decrements (server-only via service role)

**Flow**:
1. User sends message
2. Server checks credits first (subscribed users)
3. If no credits → check free messages
4. If no free messages → HTTP 402 "You have used all 10 free messages"
5. On success → decrement free message count

**Implementation**:
- Migration: `migrations/free_messages.sql`
- API server: `main.py` - `check_free_messages_remaining()`, `decrement_free_message()`
- Flutter widget: `lib/widgets/free_message_display.dart` - `FreeMessageDisplay`, `FreeMessageBadge`
- Chat UI check: Both desktop and mobile check free messages before sending

### Projects Feature

The app includes a **Projects** feature that allows users to create workspaces for organizing chats and files with custom AI behavior:

**Key Features**:
- Create project workspaces with name, description, and custom system prompt
- Add existing chats to one or more projects
- Upload files to projects (encrypted, accessible to AI as context)
- Projects UI works on both desktop and mobile platforms

**Architecture**:
- `lib/models/project_model.dart` - `Project` and `ProjectFile` data models
- `lib/services/project_storage_service.dart` - CRUD operations, chat/file management
- `lib/services/project_message_service.dart` - Inject project context into AI messages
- `lib/pages/projects_page.dart` - Projects list (adaptive desktop/mobile UI)
- `lib/pages/project_detail_page.dart` - Project detail with tabs (Chats, Files, Settings)

**How It Works**:
1. User creates a project with optional custom system prompt
2. User adds chats to the project (many-to-many relationship)
3. User uploads files to the project (encrypted before storage)
4. When chatting in a project context, `ProjectMessageService.injectProjectContext()` prepends:
   - Project name and description
   - Custom system prompt
   - Decrypted file contents (up to 50KB total)
5. AI receives full project context with each message

**Database Migration**: Run `migrations/projects.sql` in Supabase SQL Editor to create tables

**Documentation**: See `PROJECTS_PLAN.md` for detailed implementation plan and feature spec

### Image Generation Feature

The app includes **AI Image Generation** using the Z-Image Turbo API (fal.ai):

**Feature Flag**: Enable with `--dart-define=FEATURE_IMAGE_GEN=true`

**Key Features**:
- Generate images from text prompts directly in chat
- Toggle button (sparkle icon) in input area to switch between chat and image gen mode
- Configurable size presets (square, portrait, landscape) or custom dimensions
- Generated images are encrypted and stored in Supabase storage
- Billing: $0.005/megapixel, converted to EUR, rounded UP to nearest cent

**Size Presets**:
| Preset | Dimensions | ~Cost EUR |
|--------|------------|-----------|
| square_hd | 1024×1024 | 0.01 |
| square | 512×512 | 0.01 |
| portrait_4_3 | 768×1024 | 0.01 |
| portrait_16_9 | 576×1024 | 0.01 |
| landscape_4_3 | 1024×768 | 0.01 |
| landscape_16_9 | 1024×576 | 0.01 |

**Architecture**:
- `lib/services/image_generation_service.dart` - API calls, download, encrypt, store
- `lib/pages/customization_page.dart` - Settings UI (enable toggle, size presets, custom dimensions)
- `lib/platform_specific/chat/chat_ui_desktop.dart` - Desktop toggle button and `_generateImage()`
- `lib/platform_specific/chat/chat_ui_mobile.dart` - Mobile toggle button and `_generateImage()`

**User Settings** (stored in `customization_preferences` table):
- `image_gen_enabled` - Master toggle (default: false)
- `image_gen_default_size` - Size preset (default: 'landscape_4_3')
- `image_gen_custom_width` - Custom width in pixels (default: 1024)
- `image_gen_custom_height` - Custom height in pixels (default: 768)
- `image_gen_use_custom_size` - Use custom dimensions instead of preset (default: false)

**API Endpoint**: `POST /v1/ai/generate-image` on api_server
- Requires credits (no free messages for image gen)
- Returns: `{ success, image_url, width, height, seed, billing: { cost_eur } }`

**Database Migration**: Run `migrations/image_gen_settings.sql` in Supabase SQL Editor

## Key Files to Understand

- `lib/main.dart:109` - App initialization and theme bootstrapping
- `lib/main.dart:397` - AuthGate and platform detection logic
- `lib/constants.dart` - Theme builder and default colors/breakpoints
- `lib/services/supabase_service.dart` - Supabase initialization
- `lib/services/theme_settings_service.dart` - Theme/appearance preferences sync
- `lib/services/customization_preferences_service.dart` - Customization/behavior preferences sync
- `lib/services/encryption_service.dart` - Client-side encryption implementation
- `lib/services/chat_storage_service.dart` - Chat persistence layer
- `lib/pages/theme_page.dart` - Theme/appearance settings UI
- `lib/pages/customization_page.dart` - Customization/behavior settings UI
- `lib/platform_specific/root_wrapper_*.dart` - Platform-specific layout orchestration
- `lib/platform_specific/chat/chat_ui_mobile.dart:500` - Voice transcription auto-send logic

---

## Complete File Directory (89 Files)

This section provides a comprehensive map of ALL Dart files in the codebase, organized by directory. Use this to quickly locate files and understand their purpose.

### Root Level Files (`lib/`)

#### **lib/main.dart**
- **Purpose**: Application entry point and central state management
- **Key Components**:
  - `main()` - Async Supabase initialization and app launch
  - `ChukChatApp` - Root widget managing theme, customization, auth state
  - `_ChukChatAppState` - Theme/customization state with Supabase sync
- **What to Look For**: App initialization, theme callbacks, auth stream handling

#### **lib/constants.dart**
- **Purpose**: Global constants and theme builder
- **Key Elements**: Default colors, theme mode, `buildAppTheme()` function
- **What to Look For**: Default values, Material theme configuration

#### **lib/platform_config.dart**
- **Purpose**: Compile-time platform flags for tree-shaking
- **Key Constants**: `kPlatformMobile`, `kPlatformDesktop`, `kAutoDetectPlatform`
- **What to Look For**: Platform detection logic

#### **lib/supabase_config.dart**
- **Purpose**: Supabase backend configuration
- **Key Class**: `SupabaseConfig` with URL and anon key
- **What to Look For**: Environment variable overrides

#### **lib/progress_bar.dart**
- **Purpose**: Demo/utility widget (likely unused)
- **What to Look For**: Example animated progress implementation

#### **lib/model_selector_page.dart**
- **Purpose**: Full-page model/provider selection interface
- **Key Classes**: `PricingDetails`, `ModelSelectorPage`
- **What to Look For**: Alternative to dropdown model selection

---

### Pages Directory (`lib/pages/`)

#### **lib/pages/login_page.dart**
- **Purpose**: Authentication UI (login/signup)
- **Features**: Email/password forms, password strength meter, display name input
- **What to Look For**: Auth flows, form validation

#### **lib/pages/settings_page.dart**
- **Purpose**: Main settings navigation hub
- **Navigation To**: Theme, Customization, Account, System Prompt, Model Selector, Pricing, About
- **What to Look For**: Settings menu structure

#### **lib/pages/theme_page.dart**
- **Purpose**: Theme/appearance customization UI
- **Features**: Color pickers (accent, icon, background), theme mode toggle, grain overlay
- **What to Look For**: Theme state updates, Supabase sync

#### **lib/pages/customization_page.dart**
- **Purpose**: Behavior/functionality preferences UI
- **Features**: Auto-send voice, show reasoning tokens, show model info toggles
- **What to Look For**: Customization callbacks, Supabase sync

#### **lib/pages/account_settings_page.dart**
- **Purpose**: User account management
- **Features**: Display name editing, email display, password change
- **What to Look For**: Profile updates, password change flow

#### **lib/pages/system_prompt_page.dart**
- **Purpose**: System prompt/instruction management
- **Features**: Edit and save custom system prompts
- **What to Look For**: User preferences persistence

#### **lib/pages/about_page.dart**
- **Purpose**: App information and links
- **Features**: Version display, GitHub/website/docs links
- **What to Look For**: App metadata

#### **lib/pages/pricing_page.dart**
- **Purpose**: Model pricing and credit information
- **What to Look For**: Pricing display logic

#### **lib/pages/pricing_page_old_backup.dart**
- **Purpose**: Backup of old pricing implementation

#### **lib/pages/projects_page.dart**
- **Purpose**: Projects list and management
- **Features**: Create/delete projects, search, adaptive desktop/mobile layout
- **What to Look For**: Project CRUD operations, navigation to project detail

#### **lib/pages/project_detail_page.dart**
- **Purpose**: Project detail with tabs
- **Features**: Manage chats, files, and settings for a project
- **What to Look For**: Chat assignment, file upload (coming soon), project settings

#### **lib/pages/coming_soon_page.dart**
- **Purpose**: Placeholder for unimplemented features
- **What to Look For**: Simple placeholder UI

#### **lib/pages/model_selector/models/model_info.dart**
- **Purpose**: Data model for model selection
- **What to Look For**: Model information structure

---

### Models Directory (`lib/models/`)

#### **lib/models/chat_model.dart**
- **Purpose**: Core chat data models
- **Key Classes**:
  - `ModelItem` - AI model representation (name, id, badge, toggle)
  - `AttachedFile` - File attachment state (id, fileName, content, upload state, encryption path)
- **What to Look For**: Model and attachment data structures

#### **lib/models/chat_stream_event.dart**
- **Purpose**: Event types for streaming chat responses
- **Key Types**: `ContentEvent`, `ReasoningEvent`, `UsageEvent`, `MetaEvent`, `ErrorEvent`, `DoneEvent`
- **What to Look For**: Stream event handling patterns

#### **lib/models/project_model.dart**
- **Purpose**: Project workspace data models
- **Key Classes**:
  - `Project` - Project metadata (name, description, custom prompt, chat IDs, files)
  - `ProjectFile` - File attachment with encryption, type, size
- **What to Look For**: Project data structures, file type detection

---

### Services Directory (`lib/services/`)

#### Authentication & Security Services

**lib/services/supabase_service.dart**
- **Purpose**: Supabase initialization and session management
- **Key Methods**: `initialize()`, session refresh with debouncing
- **What to Look For**: Supabase client access, PKCE auth flow

**lib/services/auth_service.dart**
- **Purpose**: Authentication operations
- **Key Methods**: Sign-in, sign-up, logout
- **What to Look For**: Auth flows, encryption key cleanup

**lib/services/encryption_service.dart**
- **Purpose**: Client-side AES-256-GCM encryption
- **Key Features**: PBKDF2 key derivation (600k iterations), secure storage
- **What to Look For**: Key lifecycle, encryption/decryption logic

**lib/services/password_change_service.dart**
- **Purpose**: Password update functionality
- **What to Look For**: Password change flow

**lib/services/password_revision_service.dart**
- **Purpose**: Password change detection and forced logout
- **What to Look For**: Password revision checks

**lib/services/profile_service.dart**
- **Purpose**: User profile management
- **Key Classes**: `ProfileRecord`, static methods
- **What to Look For**: Profile data operations

#### Chat & Storage Services

**lib/services/chat_storage_service.dart**
- **Purpose**: Encrypted local chat persistence
- **Key Classes**: `ChatMessage` (with images, attachments fields), `ChatStorageService`, `StoredChat`
- **What to Look For**: Chat CRUD, encryption integration, message fields preservation, sync support methods

**lib/services/chat_sync_service.dart**
- **Purpose**: Background sync between devices
- **Key Features**: Polls every 5 seconds, compares `id` + `updated_at` timestamps, fetches only changed chats
- **Key Methods**: `start()`, `stop()`, `pause()`, `resume()`, `syncNow()`
- **What to Look For**: Lightweight polling, app lifecycle integration, conflict handling

**lib/services/streaming_chat_service.dart**
- **Purpose**: HTTP Server-Sent Events (SSE) streaming
- **Key Methods**: Send streaming requests, yield `ChatStreamEvent`s
- **What to Look For**: HTTP streaming logic, event parsing

**lib/services/websocket_chat_service.dart**
- **Purpose**: WebSocket streaming (mobile-friendly)
- **Key Features**: Persistent connections, better backgrounding
- **What to Look For**: WebSocket lifecycle, event streaming

**lib/services/streaming_manager.dart**
- **Purpose**: Manage concurrent chat streams
- **Key Features**: Track streams per chat, buffer content, handle cancellation
- **What to Look For**: Stream coordination, callbacks

**lib/services/message_composition_service.dart**
- **Purpose**: Prepare messages for API
- **Key Classes**: `MessageCompositionResult`, composition methods
- **What to Look For**: Input validation, token estimation

**lib/services/local_chat_cache_service.dart**
- **Purpose**: In-memory chat caching
- **What to Look For**: Cache operations

#### Project Management Services

**lib/services/project_storage_service.dart**
- **Purpose**: Project workspace CRUD and management
- **Key Features**: Create/update/delete projects, chat assignment, file upload/download
- **What to Look For**: Project operations, encryption integration for files

**lib/services/project_message_service.dart**
- **Purpose**: Inject project context into AI messages
- **Key Methods**: `buildProjectSystemMessage()`, `injectProjectContext()`
- **What to Look For**: Context composition, file content inclusion

#### Model Management Services

**lib/services/model_prefetch_service.dart**
- **Purpose**: Preload available models on login
- **What to Look For**: Model fetching, caching integration

**lib/services/model_cache_service.dart**
- **Purpose**: Cache models in memory
- **What to Look For**: Model list storage

**lib/services/model_capabilities_service.dart**
- **Purpose**: Track model features
- **What to Look For**: Capability data

#### Configuration & Preferences Services

**lib/services/theme_settings_service.dart**
- **Purpose**: Theme preferences sync (local ↔ Supabase)
- **Key Classes**: `ThemeSettings` model, sync methods
- **What to Look For**: Theme save/load, Supabase integration

**lib/services/customization_preferences_service.dart**
- **Purpose**: Behavioral preferences sync (local ↔ Supabase)
- **Key Classes**: `CustomizationPreferences` model, sync methods
- **What to Look For**: Preference save/load, defaults

**lib/services/user_preferences_service.dart**
- **Purpose**: User settings persistence
- **What to Look For**: Settings storage

**lib/services/api_config_service.dart**
- **Purpose**: API endpoint configuration
- **What to Look For**: Base URL management

**lib/services/api_status_service.dart**
- **Purpose**: API health monitoring
- **What to Look For**: Status checks

**lib/services/network_status_service.dart**
- **Purpose**: Network connectivity monitoring
- **What to Look For**: Connection status

#### Media & File Services

**lib/services/image_storage_service.dart**
- **Purpose**: Encrypted image storage
- **What to Look For**: Image save/load with encryption

**lib/services/image_generation_service.dart**
- **Purpose**: AI image generation via Z-Image Turbo API
- **Key Classes**: `ImageGenerationResult`, `ImageSizePresets`, `ImageGenerationService`
- **What to Look For**: API calls, image download, encryption, storage

**lib/services/image_compression_service.dart**
- **Purpose**: Image optimization for API
- **Key Features**: JPEG compression, 2MB target, 1920x1920 max
- **What to Look For**: Compression logic, quality adjustment

**lib/services/file_conversion_service.dart**
- **Purpose**: Document format conversion
- **What to Look For**: File-to-text conversion

#### Utility Services

**lib/services/session_helper.dart**
- **Purpose**: Session validation utilities
- **Key Classes**: `SessionValidationResult`, validation methods
- **What to Look For**: Session checking logic

---

### Widgets Directory (`lib/widgets/`)

#### **lib/widgets/auth_gate.dart**
- **Purpose**: Authentication guard/middleware
- **Features**: Auth state listening, conditional rendering
- **What to Look For**: Signed-in/signed-out builder logic

#### **lib/widgets/message_bubble.dart**
- **Purpose**: Message display and interaction
- **Key Classes**: `DocumentAttachment`, `MessageBubbleAction`, `MessageBubble`
- **Features**: Markdown rendering, images, documents, actions (copy/edit/delete), reasoning display
- **What to Look For**: Message rendering, action handling

#### **lib/widgets/markdown_message.dart**
- **Purpose**: Markdown-to-Flutter with syntax highlighting
- **Features**: Code highlighting, link detection, copy-to-clipboard, widget caching
- **What to Look For**: Markdown parsing, code block handling

#### **lib/widgets/image_viewer.dart**
- **Purpose**: Full-screen image viewer
- **Features**: Multi-image gallery, pinch zoom, pan gestures
- **What to Look For**: Image navigation, gesture handling

#### **lib/widgets/encrypted_image_widget.dart**
- **Purpose**: Display encrypted images
- **Features**: Load/decrypt from storage, caching
- **What to Look For**: Decryption integration

#### **lib/widgets/document_viewer.dart**
- **Purpose**: Document preview
- **Features**: Content display, copy functionality
- **What to Look For**: Document rendering

#### **lib/widgets/attachment_preview_bar.dart**
- **Purpose**: Pre-send attachment preview
- **Features**: Thumbnails, remove attachments, upload progress, image previews
- **What to Look For**: Attachment UI, state management

#### **lib/widgets/model_selection_dropdown.dart**
- **Purpose**: Model/provider dropdown UI
- **Features**: Searchable list, provider categorization, badges, pricing
- **What to Look For**: Dropdown logic, model filtering

#### **lib/widgets/credit_display.dart**
- **Purpose**: Credit/token balance display for subscribed users
- **Key Classes**: `CreditBalances`, `CreditDisplay`, `CreditBadge`
- **What to Look For**: Credit UI, realtime updates

#### **lib/widgets/free_message_display.dart**
- **Purpose**: Free message quota display for non-subscribed users
- **Key Classes**: `FreeMessageQuota`, `FreeMessageDisplay`, `FreeMessageBadge`, `FreeMessageService`
- **What to Look For**: Free message UI, realtime updates, service helper

#### **lib/widgets/password_strength_meter.dart**
- **Purpose**: Password strength indicator
- **Features**: Strength calculation, visual bar
- **What to Look For**: Strength algorithm

---

### Platform-Specific Code (`lib/platform_specific/`)

#### Root Wrappers

**lib/platform_specific/root_wrapper.dart**
- **Purpose**: Platform-agnostic export with conditional imports
- **What to Look For**: Export pattern

**lib/platform_specific/root_wrapper_io.dart**
- **Purpose**: Runtime platform detection
- **Features**: Detect desktop vs mobile via screen width and platform
- **What to Look For**: Platform selection logic, tablet breakpoint (800.0)

**lib/platform_specific/root_wrapper_desktop.dart**
- **Purpose**: Desktop UI layout orchestrator
- **Layout**: Sidebar (left) + Chat UI (center) + Settings (conditional)
- **What to Look For**: Desktop layout structure, callbacks

**lib/platform_specific/root_wrapper_mobile.dart**
- **Purpose**: Mobile UI layout orchestrator
- **Layout**: Drawer navigation + Full-screen chat
- **Features**: Permission handling (mic, camera, photos)
- **What to Look For**: Mobile layout, permission requests

**lib/platform_specific/root_wrapper_stub.dart**
- **Purpose**: Fallback for web (unused)

#### Sidebar Components

**lib/platform_specific/sidebar_desktop.dart**
- **Purpose**: Desktop sidebar navigation
- **Features**: Chat list, new chat, settings, deletion/renaming
- **What to Look For**: Desktop nav structure

**lib/platform_specific/sidebar_mobile.dart**
- **Purpose**: Mobile drawer navigation
- **Features**: Chat list in drawer, new chat, settings
- **What to Look For**: Mobile nav structure

---

### Chat Platform-Specific (`lib/platform_specific/chat/`)

#### Main Chat UIs

**lib/platform_specific/chat/chat_ui_desktop.dart**
- **Purpose**: Desktop chat interface
- **Features**: Message list, input box, attachments, model selection, streaming
- **What to Look For**: Desktop chat flow, message rendering

**lib/platform_specific/chat/chat_ui_mobile.dart**
- **Purpose**: Mobile chat interface
- **Features**: Message list, mobile input, audio recording, attachments, voice auto-send
- **What to Look For**: Mobile chat flow, audio transcription, auto-send logic (line ~500)

**lib/platform_specific/chat/chat_api_service.dart**
- **Purpose**: API communication layer
- **Features**: File upload, model fetching
- **What to Look For**: API abstractions

#### Chat Handlers (Modular Functionality)

**lib/platform_specific/chat/handlers/streaming_message_handler.dart**
- **Purpose**: Manage message streaming and sending
- **Features**: Send with streaming, state management, error handling, callbacks
- **What to Look For**: Message send flow, stream handling

**lib/platform_specific/chat/handlers/chat_persistence_handler.dart**
- **Purpose**: Chat saving and loading
- **Features**: Persist to encrypted storage, offline handling, chat ID assignment
- **What to Look For**: Save/load logic, encryption integration

**lib/platform_specific/chat/handlers/file_attachment_handler.dart**
- **Purpose**: File and image attachments
- **Features**: Pick files/images, track upload state, remove attachments, image encryption
- **What to Look For**: File picking, attachment state

**lib/platform_specific/chat/handlers/audio_recording_handler.dart**
- **Purpose**: Audio recording and transcription
- **Features**: Mic permissions, record with level monitoring, upload for transcription
- **What to Look For**: Recording flow, transcription API

**lib/platform_specific/chat/handlers/message_actions_handler.dart**
- **Purpose**: Message interactions
- **Features**: Copy, edit, delete messages, custom actions
- **What to Look For**: Action implementations

#### Chat Widgets

**lib/platform_specific/chat/widgets/mobile_chat_widgets.dart**
- **Purpose**: Mobile-specific chat components
- **What to Look For**: Mobile message bubbles, input styling

**lib/platform_specific/chat/widgets/desktop_chat_widgets.dart**
- **Purpose**: Desktop-specific chat components
- **What to Look For**: Desktop message bubbles, formatting toolbar

---

### Utilities Directory (`lib/utils/`)

#### **lib/utils/grain_overlay.dart**
- **Purpose**: Film grain visual effect
- **Features**: Procedural noise, flickering animation, configurable opacity
- **What to Look For**: Overlay rendering, animation

#### **lib/utils/color_extensions.dart**
- **Purpose**: Color utility extensions
- **Features**: Hex parsing ("#FF5733" → Color), color-to-hex
- **What to Look For**: Color conversion methods

#### **lib/utils/theme_extensions.dart**
- **Purpose**: Theme utility extensions
- **What to Look For**: Theme-based helpers

#### **lib/utils/input_validator.dart**
- **Purpose**: Input validation
- **Key Classes**: `PasswordValidationResult`, validation methods
- **What to Look For**: Password strength, email validation

#### **lib/utils/token_estimator.dart**
- **Purpose**: Token count estimation
- **What to Look For**: Token counting logic

#### **lib/utils/secure_token_handler.dart**
- **Purpose**: Secure access token handling
- **What to Look For**: Token refresh, secure storage

#### **lib/utils/api_rate_limiter.dart**
- **Purpose**: API rate limiting
- **Key Classes**: `RateLimitConfig`, `RateLimiter`
- **What to Look For**: Rate limit logic

#### **lib/utils/api_request_queue.dart**
- **Purpose**: Queue API requests
- **Key Classes**: `QueuedRequest<T>`, queue processing
- **What to Look For**: Request queuing

#### **lib/utils/exponential_backoff.dart**
- **Purpose**: Retry with exponential backoff
- **Key Classes**: `BackoffConfig`, retry logic
- **What to Look For**: Backoff algorithm

#### **lib/utils/file_upload_validator.dart**
- **Purpose**: File validation before upload
- **Key Classes**: `FileValidationResult`, validation methods
- **What to Look For**: Size, type, format checks

#### **lib/utils/upload_rate_limiter.dart**
- **Purpose**: Rate limit file uploads
- **What to Look For**: Upload throttling

#### **lib/utils/certificate_pinning.dart**
- **Purpose**: SSL certificate pinning
- **Key Classes**: `CertificatePin`, `CertificateValidationResult`
- **What to Look For**: Security implementation

#### **lib/utils/service_logger.dart**
- **Purpose**: Centralized service logging
- **Features**: Debug, Info, Warning, Error, Success levels with emojis
- **What to Look For**: Logging patterns

#### **lib/utils/service_error_handler.dart**
- **Purpose**: Unified error handling
- **What to Look For**: Error parsing, context

#### **lib/utils/highlight_registry.dart**
- **Purpose**: Syntax highlighting setup
- **What to Look For**: Language definitions

---

### Constants Directory (`lib/constants/`)

#### **lib/constants/file_constants.dart**
- **Purpose**: File handling constants
- **Key Class**: `FileConstants`
- **Constants**: `maxFileSizeBytes` (10MB), `maxConcurrentUploads` (5), `allowedExtensions` (comprehensive list)
- **What to Look For**: File limits, allowed types

---

### Core Directory (`lib/core/`)

#### **lib/core/model_selection_events.dart**
- **Purpose**: Event bus for model selection
- **Key Class**: `ModelSelectionEventBus` (singleton)
- **Streams**: `refreshStream`, `modelSelectedStream`
- **What to Look For**: Event broadcasting patterns

---

## Quick Reference: Where to Find Things

### Authentication & Security
- Login/Signup UI: `lib/pages/login_page.dart`
- Auth operations: `lib/services/auth_service.dart`
- Encryption: `lib/services/encryption_service.dart`
- Password changes: `lib/services/password_change_service.dart`

### Chat Functionality
- Desktop chat: `lib/platform_specific/chat/chat_ui_desktop.dart`
- Mobile chat: `lib/platform_specific/chat/chat_ui_mobile.dart`
- Message storage: `lib/services/chat_storage_service.dart`
- Streaming (HTTP): `lib/services/streaming_chat_service.dart`
- Streaming (WebSocket): `lib/services/websocket_chat_service.dart`
- Message handlers: `lib/platform_specific/chat/handlers/`

### Theme & Customization
- Theme settings UI: `lib/pages/theme_page.dart`
- Customization UI: `lib/pages/customization_page.dart`
- Theme service: `lib/services/theme_settings_service.dart`
- Customization service: `lib/services/customization_preferences_service.dart`
- Theme builder: `lib/constants.dart`

### File & Media Handling
- Attachment preview: `lib/widgets/attachment_preview_bar.dart`
- Image compression: `lib/services/image_compression_service.dart`
- Image storage: `lib/services/image_storage_service.dart`
- Image generation: `lib/services/image_generation_service.dart`
- File constants: `lib/constants/file_constants.dart`
- Attachment handler: `lib/platform_specific/chat/handlers/file_attachment_handler.dart`

### Platform Abstraction
- Platform config: `lib/platform_config.dart`
- Desktop wrapper: `lib/platform_specific/root_wrapper_desktop.dart`
- Mobile wrapper: `lib/platform_specific/root_wrapper_mobile.dart`
- Platform detection: `lib/platform_specific/root_wrapper_io.dart`

### Models & Data
- AI models: `lib/models/chat_model.dart` (`ModelItem`, `AttachedFile`)
- Stream events: `lib/models/chat_stream_event.dart`
- Chat messages: `lib/services/chat_storage_service.dart` (`ChatMessage`)

### Configuration
- App entry: `lib/main.dart`
- Supabase config: `lib/supabase_config.dart`
- Constants: `lib/constants.dart`

---

## Development Notes

- **No Tests Currently**: The project has no test files yet. Consider adding tests when implementing new features.
- **Platform-Specific Code**: When adding new UI features, ensure both desktop and mobile variants are implemented in their respective platform_specific directories.
- **Encryption**: All chat data is encrypted client-side. Never commit unencrypted sensitive data.
- **Theme Sync**: Theme changes must update both SharedPreferences (local) and Supabase (remote) via the callbacks in main.dart.
- **Customization Sync**: Customization changes must update both SharedPreferences (local) and Supabase (remote) via the callbacks in main.dart.
- **Message Fields Preservation**: When loading messages from storage (in `_loadChatFromIndex()` or `_handleRealtimeChatUpdate()`), ALWAYS preserve ALL fields from `ChatMessage` including `images` and `attachments`. Failure to do so causes data loss and message duplication due to realtime sync loops. Both desktop and mobile UIs must handle these fields identically.
- **Image Persistence in Messages**: When sending messages with images, ALWAYS store images in the user message using `MessageCompositionService.prepareMessage()` result. Extract `displayMessageText` and `images` from the validation result, then store images as JSON-encoded string in the message map. See mobile UI fix at chat_ui_mobile.dart:832-865 and compare with desktop UI implementation.
- **Mobile Streaming Focus**: During streaming updates in mobile UI, DO NOT refocus the text field on every token arrival. This creates a keyboard focus fight when users try to dismiss the keyboard while AI is responding. Only focus text field when user initiates send (chat_ui_mobile.dart:884), not during streaming updates (chat_ui_mobile.dart:714).
- **Build Artifacts**: `releases/`, `debian/`, `rpm/`, and `AppDir/` directories are git-ignored.
- **Dependencies**: Uses flutter_lints for code quality. Run `flutter analyze` before committing.
- **Documentation**: Do NOT create separate markdown documentation files. All documentation should be in this CLAUDE.md file.
- **IMPORTANT: Always commit AND PUSH changes after completing a task**. Update this CLAUDE.md file with any new features or changes, then commit with a descriptive message and push to remote.

## Common Tasks

### Adding a New Service
1. Create service file in `lib/services/`
2. Use const constructor or static methods for singleton-like behavior
3. Add initialization to `main.dart` if needed at app startup
4. Update both platform-specific UIs if the service affects UI state

### Adding a New Page
1. Create page in `lib/pages/`
2. Add navigation in appropriate sidebar (desktop or mobile)
3. Ensure theme colors are applied consistently using `Theme.of(context)`
4. Test on both platforms if cross-platform

### Modifying Theme System
1. Update `lib/constants.dart` for new theme properties (if adding visual defaults)
2. Add state management in `_ChukChatAppState` in `main.dart`
3. Update `ThemeSettings` model in `ThemeSettingsService`
4. Update Supabase `theme_settings` table schema if adding new columns
5. Pass new callbacks to both root wrappers (desktop and mobile)
6. Update `ThemePage` UI to expose new settings

### Modifying Customization/Behavior Settings
1. Add state management in `_ChukChatAppState` in `main.dart`
2. Update `CustomizationPreferences` model in `CustomizationPreferencesService`
3. Update Supabase `customization_preferences` table schema if adding new columns
4. Pass new callbacks to both root wrappers (desktop and mobile)
5. Update `CustomizationPage` UI to expose new settings
6. Implement behavior logic in relevant components (e.g., `chat_ui_mobile.dart` for voice transcription)

Note: Theme settings are for visual/appearance preferences, while customization settings are for behavioral/functionality preferences.

### Updating Build Configuration
1. Modify version in `pubspec.yaml` (version field)
2. Update `BUILD.md` if adding new build targets or requirements
3. Modify `build.sh` if changing build process
4. Test builds on target platforms before committing
