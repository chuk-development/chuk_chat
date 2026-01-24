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

## Building APKs

**IMPORTANT:** Always load `.env` before building to include Supabase credentials!

### Debug APK - Minimal (no extra features)
```bash
source .env
flutter build apk --debug \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=PLATFORM_MOBILE=true \
  --target-platform android-arm64
```

### Debug APK - All Features
```bash
source .env
flutter build apk --debug \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_MEDIA_MANAGER=true \
  --dart-define=FEATURE_VOICE_MODE=true \
  --target-platform android-arm64
```

### Release APK (requires keystore)
```bash
source .env
flutter build apk \
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

### Install via ADB
```bash
# If signature mismatch, uninstall first
adb uninstall dev.chuk.chat
adb install build/app/outputs/flutter-apk/app-debug.apk
```

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
