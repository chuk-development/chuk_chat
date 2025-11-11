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
   - `StreamingChatService` - Real-time chat message streaming
   - `LocalChatCacheService` - Local caching of chat data
   - `ChatApiService` (platform_specific) - API communication layer

3. **Model Management**:
   - `ModelPrefetchService` - Preloads available AI models on login
   - `ModelCacheService` - Caches model data locally
   - `ModelCapabilitiesService` - Tracks model features and limits

4. **Configuration & State**:
   - `ThemeSettingsService` - Syncs theme preferences between local and Supabase
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
   - `ModelPrefetchService.prefetch()` loads available models
   - Theme settings loaded from Supabase
5. Platform-appropriate root wrapper is displayed

### Data Models

Key models in `lib/models/`:
- `ModelItem` - Represents an AI model with name, id, and optional badge/toggle
- `AttachedFile` - Represents file attachments with upload state and markdown content
- Chat models stored as encrypted JSON via `ChatStorageService`

### Supabase Configuration

- Configuration in `lib/supabase_config.dart`
- Supports compile-time environment variables: `SUPABASE_URL`, `SUPABASE_ANON_KEY`
- Falls back to hardcoded values if env vars not provided

## Key Files to Understand

- `lib/main.dart:109` - App initialization and theme bootstrapping
- `lib/main.dart:397` - AuthGate and platform detection logic
- `lib/constants.dart` - Theme builder and default colors/breakpoints
- `lib/services/supabase_service.dart` - Supabase initialization
- `lib/services/encryption_service.dart` - Client-side encryption implementation
- `lib/services/chat_storage_service.dart` - Chat persistence layer
- `lib/platform_specific/root_wrapper_*.dart` - Platform-specific layout orchestration

## Development Notes

- **No Tests Currently**: The project has no test files yet. Consider adding tests when implementing new features.
- **Platform-Specific Code**: When adding new UI features, ensure both desktop and mobile variants are implemented in their respective platform_specific directories.
- **Encryption**: All chat data is encrypted client-side. Never commit unencrypted sensitive data.
- **Theme Sync**: Theme changes must update both SharedPreferences (local) and Supabase (remote) via the callbacks in main.dart.
- **Build Artifacts**: `releases/`, `debian/`, `rpm/`, and `AppDir/` directories are git-ignored.
- **Dependencies**: Uses flutter_lints for code quality. Run `flutter analyze` before committing.

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
1. Update `lib/constants.dart` for new theme properties
2. Add state management in `_ChukChatAppState` in `main.dart`
3. Update `ThemeSettings` model in `ThemeSettingsService`
4. Update Supabase schema if adding server-synced properties
5. Pass new callbacks to both root wrappers (desktop and mobile)

### Updating Build Configuration
1. Modify version in `pubspec.yaml` (version field)
2. Update `BUILD.md` if adding new build targets or requirements
3. Modify `build.sh` if changing build process
4. Test builds on target platforms before committing
