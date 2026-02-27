# CLAUDE.md

**chuk_chat** — Cross-platform Flutter chat app with E2E encryption, Supabase backend, AI chat.

## Workflow Rules

**After completing any task, ALWAYS do this in order:**

1. `flutter test` — all must pass
2. `coderabbit review --plain` (timeout 300s) — fix any findings
3. Commit with descriptive message
4. `git push`

**Do NOT push if tests fail or CodeRabbit finds issues. Fix first.**

## Build Rules

- **ALWAYS** `--release` for Android (debug = unusable performance)
- **ALWAYS** `--dart-define-from-file=.env` for Supabase credentials
- **NEVER** `source .env` or manual `--dart-define=SUPABASE_*`
- If app shows "Supabase credentials are not configured" → `flutter clean` and rebuild

## Quick Start

```bash
cp .env.example .env       # First time: add Supabase credentials
./run.sh linux             # Run desktop
./run.sh android           # Run mobile
flutter test               # Run tests
flutter analyze            # Static analysis
```

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

Pass via `--dart-define=FLAG=value`. Defined in `lib/platform_config.dart`.

| Flag | Android | Linux/Web | Notes |
|------|---------|-----------|-------|
| `FEATURE_PROJECTS` | `false` | `true` | Project workspaces |
| `FEATURE_IMAGE_GEN` | **always on** | **always on** | Hardcoded, no flag needed |
| `FEATURE_VOICE_MODE` | `false` | `true` | Voice mode button |
| `PLATFORM_MOBILE` | `true` | omit | Mobile UI layout |

## Building Android

```bash
# Single-arch APK (~26MB)
flutter build apk --release \
  --dart-define-from-file=.env \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=false \
  --dart-define=FEATURE_VOICE_MODE=false \
  --tree-shake-icons \
  --target-platform android-arm64
# Output: build/app/outputs/flutter-apk/app-release.apk

# Split APK (per architecture)
flutter build apk --release --split-per-abi \
  --dart-define-from-file=.env \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=false \
  --dart-define=FEATURE_VOICE_MODE=false \
  --tree-shake-icons
# Outputs: app-arm64-v8a-release.apk (~26MB), app-armeabi-v7a-release.apk (~24MB), app-x86_64-release.apk (~28MB)
```

Install: `adb install -r build/app/outputs/flutter-apk/app-release.apk`
Signature mismatch: `adb uninstall dev.chuk.chat && adb install ...`

**Signing:** Env vars > `android/key.properties` > debug keystore. See `android/key.properties.example`.

## Building Linux

```bash
flutter build linux --release \
  --dart-define-from-file=.env \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_VOICE_MODE=true
# Output: build/linux/x64/release/bundle/
```

Packaging (DEB, RPM, AppImage, Flatpak): see `docs/LINUX_BUILDS.md`

## Building Web

Deployed via Docker on Dokploy at `chat.chuk.chat` (auto-deploys on push to master).

**Web credentials:** `--dart-define` is unreliable with dart2js. `Dockerfile.web` generates `lib/web_env.dart` at build time. Credential priority in `lib/supabase_config.dart`: `--dart-define` > `web_env.dart` > `.env` file.

**Web can't use `dart:io`:** Use `import 'package:chuk_chat/utils/io_helper.dart'` instead.

```bash
flutter build web --release \
  --dart-define-from-file=.env \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_VOICE_MODE=true
# Output: build/web/
```

Stale cache? Purge Cloudflare: Dashboard > chuk.chat > Caching > Purge Everything.

## Creating a Release

**Default policy:**

- Do **not** run GitHub release workflows for normal coding tasks.
- Build and validate Linux/Android locally first.
- Trigger GitHub cross-platform release workflow **only** when the user explicitly asks for a real release.

1. Bump version in `pubspec.yaml` (e.g. `1.0.38` → `1.0.39` — no `+buildnumber` suffix)
2. Commit: `git commit -am "chore: bump version to 1.0.39"`
3. Push: `git push origin master`
4. Trigger CI build (builds Android, Linux x64/ARM64, Windows, macOS):
   ```bash
   gh workflow run build-cross-platform.yml \
     --field build_android=true \
     --field build_linux_x64=true \
     --field build_linux_arm64=true \
     --field build_windows=true \
     --field build_macos=true \
      --field build_ios=false \
      --field enable_signing=true
   ```
5. CI creates the GitHub Release with all artifacts automatically
6. Web deploys automatically via Dokploy on push to master

**Note:** Do not rely on git tags to trigger releases. Use `workflow_dispatch` for `build-cross-platform.yml`.

## Privacy: Logging

**All logs disabled in release builds.** Rules:
- **ALWAYS** wrap `debugPrint()` in `if (kDebugMode)`
- **NEVER** log message content, tokens, passwords, emails
- OK to log: lengths, counts, IDs, status codes

```dart
if (kDebugMode) {
  debugPrint('Message length: ${message.length} chars');
}
```

Alternative: `pLog('message')` from `lib/utils/privacy_logger.dart`

## Docs Index

| Doc | Topic |
|-----|-------|
| `docs/ARCHITECTURE.md` | Services, state, platform abstraction |
| `docs/FILE_MAP.md` | File locations, project structure |
| `docs/FEATURES.md` | Projects, Image Gen, Media Manager |
| `docs/DATABASE.md` | Supabase tables, schema |
| `docs/COMMON_TASKS.md` | Adding services, pages, features |
| `docs/GOTCHAS.md` | **CRITICAL** — bugs to avoid |
| `docs/LINUX_BUILDS.md` | Fastlane packaging (DEB, RPM, AppImage, Flatpak) |
