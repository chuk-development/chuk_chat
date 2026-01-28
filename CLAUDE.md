# CLAUDE.md

**chuk_chat** - Cross-platform Flutter chat app with E2E encryption, Supabase backend, AI chat.

## Quick Start

```bash
# Setup (first time only)
cp .env.example .env
# Edit .env with your Supabase credentials

# Run (uses .env automatically)
./run.sh linux
./run.sh android

# Analyze
flutter analyze
```

## Building Android APKs

### CRITICAL: NEVER USE --debug FOR ANDROID!

Debug builds are 3-10x slower and will make the app feel broken/laggy.
**ALWAYS use --release for Android builds.**

```
DEBUG MODE = UNUSABLE PERFORMANCE (JIT, no optimization)
RELEASE MODE = NORMAL PERFORMANCE (AOT, fully optimized)
```

### Build Android APK (ALWAYS Release!)

```bash
source .env && flutter build apk --release \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_MEDIA_MANAGER=true \
  --dart-define=FEATURE_VOICE_MODE=true \
  --tree-shake-icons \
  --target-platform android-arm64
```

Output: `build/app/outputs/flutter-apk/app-release.apk` (~26MB)

### Install via ADB

```bash
# Update existing app (preserves data, login, icon position)
adb install -r build/app/outputs/flutter-apk/app-release.apk

# Only if signature mismatch error:
adb uninstall dev.chuk.chat && adb install build/app/outputs/flutter-apk/app-release.apk
```

### Profile Mode (Only for DevTools/Performance Analysis)

If you need Flutter DevTools for debugging, use profile mode (still fast, but has debugging support):

```bash
source .env && flutter build apk --profile \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=true \
  --target-platform android-arm64
```

### Android Signing Setup

The build system supports 3 methods (in priority order):

**1. Environment Variables (CI/CD)**
```bash
export ANDROID_KEYSTORE_PATH=/path/to/keystore.keystore
export ANDROID_KEYSTORE_PASSWORD=your_password
export ANDROID_KEY_PASSWORD=your_password
export ANDROID_KEY_ALIAS=chuk_chat
```

**2. key.properties File (Local Development)**
```bash
# Copy template and edit with your paths
cp android/key.properties.example android/key.properties
# Edit android/key.properties with your keystore path
```

**3. Debug Keystore (Fallback)**
If neither is configured, uses debug signing (not for Play Store).

**For new team members:**
1. Get the keystore file from team lead (never commit it!)
2. Place it somewhere on your system
3. Copy `android/key.properties.example` to `android/key.properties`
4. Edit `storeFile=` to point to your keystore location

## Building Linux Packages

### Quick: Using Fastlane (All Formats)

```bash
# Install dependencies (first time)
cd linux && bundle install

# Build all formats (Flatpak, AppImage, DEB, RPM)
bundle exec fastlane release

# Or build specific format
bundle exec fastlane build_flatpak
bundle exec fastlane build_appimage
bundle exec fastlane build_deb
bundle exec fastlane build_rpm
```

### Quick: Flatpak Only

```bash
# Build and install locally
./build_flatpak.sh --install

# Create distributable bundle
./build_flatpak.sh --bundle

# Run
flatpak run dev.chuk.chat
```

See `docs/LINUX_BUILDS.md` for Fastlane lanes and `docs/FLATPAK.md` for Flatpak details.

## Read These Docs

Before working on the codebase, read the relevant docs:

| Doc | When to Read |
|-----|--------------|
| `docs/ARCHITECTURE.md` | Understanding services, state, platform abstraction |
| `docs/FILE_MAP.md` | Finding files, understanding structure |
| `docs/FEATURES.md` | Working on Projects, Image Gen, Media Manager, etc. |
| `docs/DATABASE.md` | Working with Supabase tables, schema |
| `docs/COMMON_TASKS.md` | Adding services, pages, features, building |
| `docs/GOTCHAS.md` | **CRITICAL** - Bugs to avoid, important fixes |
| `docs/LINUX_BUILDS.md` | Building all Linux packages with Fastlane |
| `docs/FLATPAK.md` | Flatpak-specific packaging details |

## Key Entry Points

| What | Where |
|------|-------|
| App entry | `lib/main.dart` |
| Desktop chat | `lib/platform_specific/chat/chat_ui_desktop.dart` |
| Mobile chat | `lib/platform_specific/chat/chat_ui_mobile.dart` |
| Platform flags | `lib/platform_config.dart` |
| Encryption | `lib/services/encryption_service.dart` |
| Chat storage | `lib/services/chat_storage_service.dart` |

## Feature Flags

Enable with `--dart-define=FEATURE_X=true`:
- `FEATURE_PROJECTS` - Project workspaces
- `FEATURE_IMAGE_GEN` - AI image generation
- `FEATURE_MEDIA_MANAGER` - Media management
- `FEATURE_VOICE_MODE` - Voice mode button

## Privacy: Logging Policy

**This is a privacy-focused app. ALL logs are disabled in release builds.**

### Rules for Logging:
1. **ALWAYS** wrap `debugPrint()` in `if (kDebugMode)` check
2. **NEVER** log user message content, chat text, or titles
3. **NEVER** log tokens, passwords, or email addresses
4. **OK** to log: lengths, counts, IDs, status codes, timing

```dart
// WRONG - logs in release!
debugPrint('User message: $message');

// CORRECT - only logs in debug
if (kDebugMode) {
  debugPrint('Message length: ${message.length} chars');
}
```

### Alternative: Use PrivacyLogger
```dart
import 'package:chuk_chat/utils/privacy_logger.dart';
pLog('Safe log message');  // Auto-disabled in release
```

## Creating a New Release

When the user says "mach ein neues release" or "create a new release":

### Build Strategy

| Platform | Build Location | Reason |
|----------|---------------|--------|
| Android | **LOCAL** | Fast (2 min vs 20 min on CI) |
| Linux | **LOCAL** | Fast, needs local deps |
| Web | **LOCAL** | Fast, easy |
| Windows | GitHub Actions | Needs Windows runner |
| macOS | GitHub Actions | Needs macOS runner |
| iOS | GitHub Actions | Needs macOS + Xcode |

### Local Builds (Android, Linux, Web)

```bash
# Android APK (~2 min)
source .env && flutter build apk --release \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_MEDIA_MANAGER=true \
  --dart-define=FEATURE_VOICE_MODE=true \
  --tree-shake-icons
# Output: build/app/outputs/flutter-apk/app-release.apk

# Linux binary (~1 min)
source .env && flutter build linux --release \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_MEDIA_MANAGER=true \
  --dart-define=FEATURE_VOICE_MODE=true
# Output: build/linux/x64/release/bundle/

# Web (~3 min)
source .env && flutter build web --release \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_MEDIA_MANAGER=true \
  --dart-define=FEATURE_VOICE_MODE=true
# Output: build/web/
# Run: cd build/web && python3 -m http.server 8080
```

### Release Steps (When user says "mach ein Release")

1. **Bump version** in pubspec.yaml (e.g., `1.0.18+18`)
2. **Run local build script**:
   ```bash
   ./scripts/build-release.sh all
   ```
   This builds Android, Linux, Web automatically.

3. **Commit and tag**:
   ```bash
   git add -A
   git commit -m "chore: bump version to 1.0.18"
   git tag v1.0.18
   git push origin master --tags
   ```

4. **Upload local builds** to GitHub Release:
   ```bash
   VERSION=1.0.18
   gh release create v$VERSION \
     build/app/outputs/flutter-apk/app-release.apk \
     chuk_chat-$VERSION-linux-x64.tar.gz \
     chuk_chat-$VERSION-web.zip \
     --title "Release $VERSION" \
     --generate-notes
   ```

5. **CI builds automatically**:
   - **Windows**: GitHub Actions (triggers on tag)
   - **iOS**: Codemagic (triggers on tag)

### CI Platforms

| Platform | CI Service | Trigger | Config File |
|----------|-----------|---------|-------------|
| Windows | GitHub Actions | Tag push | `.github/workflows/release-windows.yml` |
| iOS | Codemagic | Tag push | `codemagic.yaml` |
| macOS | Codemagic or GitHub | Tag push | `codemagic.yaml` |

### Monitor CI Builds

```bash
# GitHub Actions (Windows)
gh run list --workflow=release-windows.yml --limit=3

# Codemagic (iOS) - check dashboard or use API
# https://codemagic.io/apps
```

### Codemagic Setup (one-time)

1. Go to https://codemagic.io and connect GitHub repo
2. Add environment variables in Codemagic dashboard:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `GITHUB_TOKEN` (for uploading to releases)
3. Configure iOS signing (certificates, provisioning profiles)

## IMPORTANT: After Every Task

1. **Commit** your changes with descriptive message
2. **Push** to remote
3. **Update docs** if you changed architecture/features

```bash
git add -A
git commit -m "feat/fix: description"
git push
```

If you added a new feature or fixed a significant bug, update the relevant doc in `docs/`.
