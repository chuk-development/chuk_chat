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
