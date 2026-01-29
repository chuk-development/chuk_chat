# Architecture

## Platform Abstraction

The app uses **platform-specific architecture with tree-shaking**:

```
Desktop Build (--dart-define=PLATFORM_DESKTOP=true):
  main.dart → RootWrapper → RootWrapperDesktop ✓
  (RootWrapperMobile removed by tree-shaker)

Mobile Build (--dart-define=PLATFORM_MOBILE=true):
  main.dart → RootWrapper → RootWrapperMobile ✓
  (RootWrapperDesktop removed by tree-shaker)
```

### Key Files
- `lib/main.dart` - Entry point, theme/auth state management
- `lib/platform_config.dart` - Compile-time flags (`kPlatformMobile`, `kPlatformDesktop`)
- `lib/platform_specific/root_wrapper_*.dart` - Platform layout orchestrators
- `lib/platform_specific/chat/chat_ui_desktop.dart` - Desktop chat
- `lib/platform_specific/chat/chat_ui_mobile.dart` - Mobile chat

### Feature Flags
In `lib/platform_config.dart`, enabled via `--dart-define=FEATURE_X=true`:
- `kFeatureVoiceMode` - Voice Mode button (mic/transcription always works)
- `kFeatureProjects` - Project workspaces
- `kFeatureAssistants` - Custom AI assistants
- `kFeatureImageGen` - AI Image Generation
- Media Manager - always enabled (no feature flag needed)

## Services Architecture

Services in `lib/services/` use singleton-like patterns (static methods or const constructors).

### Auth & Security
| Service | Purpose |
|---------|---------|
| `SupabaseService` | Supabase init, session management |
| `AuthService` | Login, signup, logout |
| `EncryptionService` | AES-256-GCM encryption, PBKDF2 key derivation |
| `PasswordRevisionService` | Password change detection, forced logout |

### Chat & Storage
| Service | Purpose |
|---------|---------|
| `ChatStorageService` | Encrypted chat persistence |
| `ChatSyncService` | Background sync (5s polling) |
| `StreamingChatService` | HTTP SSE streaming |
| `WebSocketChatService` | WebSocket streaming (mobile-friendly) |
| `StreamingManager` | Concurrent stream management |
| `MessageCompositionService` | Prepare messages for API |
| `TitleGenerationService` | AI-powered chat title generation |
| `SessionHelper` | Session validation utilities |

### Model Management
| Service | Purpose |
|---------|---------|
| `ModelPrefetchService` | Preload models on login |
| `ModelCacheService` | In-memory model cache |
| `ModelCapabilitiesService` | Track model features |

### Configuration
| Service | Purpose |
|---------|---------|
| `ThemeSettingsService` | Theme sync (local ↔ Supabase) |
| `CustomizationPreferencesService` | Behavior prefs sync |
| `UserPreferencesService` | User settings persistence |
| `ApiConfigService` | API endpoint config |

### Media
| Service | Purpose |
|---------|---------|
| `ImageStorageService` | Encrypted image storage, listing, deletion |
| `ImageGenerationService` | AI image gen via Z-Image Turbo |
| `ImageCompressionService` | JPEG compression (2MB target) |

## State Management

- **Theme/Customization**: Managed in `ChukChatApp` (`main.dart`), synced via services
- **Auth**: Via Supabase `auth.onAuthStateChange` stream
- **Chat**: `ChatStorageService` with encrypted local storage
- **Platform**: Runtime detection in `root_wrapper_io.dart`

## Auth Flow

1. App inits Supabase in `main.dart`
2. `AuthGate` checks auth state
3. On login:
   - Load encryption key (`EncryptionService.tryLoadKey()`)
   - Load chats (`ChatStorageService.loadSavedChatsForSidebar()`)
   - Start sync (`ChatSyncService.start()`)
   - Prefetch models (`ModelPrefetchService.prefetch()`)
   - Load theme/customization from Supabase
4. On logout: Stop sync, clear sensitive data
