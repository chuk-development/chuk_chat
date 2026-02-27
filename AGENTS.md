# AGENTS.md

Guidelines for AI coding agents working in the **chuk_chat** Flutter codebase.

## Build / Test / Lint Commands

```bash
# Run all tests (MUST pass before every commit)
flutter test

# Run a single test file
flutter test test/models/chat_message_test.dart

# Run tests matching a name pattern
flutter test --name "validateEmail"

# Static analysis (4 pre-existing info-level lints in chat_ui_desktop.dart are acceptable)
flutter analyze

# Format code
dart format .

# Run locally (loads .env automatically)
./run.sh linux          # desktop
./run.sh android        # mobile
```

### Building

```bash
# Android (ALWAYS --release, debug is unusably slow)
flutter build apk --release \
  --dart-define-from-file=.env \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=false \
  --dart-define=FEATURE_VOICE_MODE=false \
  --tree-shake-icons --target-platform android-arm64

# Linux
flutter build linux --release --dart-define-from-file=.env

# Web
flutter build web --release --dart-define-from-file=.env

# Local all-platform build
./scripts/build-release.sh all
```

- **ALWAYS** `--dart-define-from-file=.env` for credentials, **NEVER** `source .env`
- If app shows "Supabase credentials are not configured" → `flutter clean` and rebuild

### Creating a Release

**Cost-control release policy (IMPORTANT):**

- Do **NOT** trigger GitHub Actions release workflows for normal feature/fix tasks.
- For routine validation, build locally on the developer machine:
  - Android: `flutter build apk --release --dart-define-from-file=.env --dart-define=PLATFORM_MOBILE=true --dart-define=FEATURE_PROJECTS=false --dart-define=FEATURE_VOICE_MODE=false --tree-shake-icons --target-platform android-arm64`
  - Linux: `flutter build linux --release --dart-define-from-file=.env`
- Trigger `gh workflow run build-cross-platform.yml` **only** when the user explicitly asks for a real release (for example: "make release", "new release", "build release").
- Prefer fewer production releases (typically one planned release per day, unless urgent hotfix).

**When the user explicitly asks to "build a release" or "make a new release", ALWAYS follow these steps:**

1. Bump version in `pubspec.yaml` (e.g. `1.0.26` → `1.0.27` — **no** `+buildnumber` suffix)
2. Commit: `git commit -am "chore: bump version to 1.0.27"`
3. Push: `git push origin master`
4. Trigger the cross-platform build (**always include all platforms except iOS**):
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
5. Verify the workflow started: `gh run list --limit 3`
6. CI reads the version from `pubspec.yaml`, builds all platforms, and creates the GitHub Release automatically
7. Web deploys automatically via Dokploy on push to master

**Important:** Do NOT rely on git tags to trigger builds. The `Cross-Platform Build & Release` workflow is triggered by `workflow_dispatch` only. The separate `Release - macOS` and `Release - Windows` tag-triggered workflows are legacy and may fail.

### Mandatory Post-Task Workflow

**This workflow is non-negotiable. Follow it EVERY time you change code, in EVERY session.**

1. `flutter test` — all must pass
2. `flutter analyze` — 0 new issues (4 pre-existing info-level lints in `chat_ui_desktop.dart` OK)
3. **BEFORE committing**: run `coderabbit review --plain` (timeout 300s) on your **uncommitted** changes
   - CodeRabbit only reviews uncommitted files. If you commit first, it won't see your changes.
   - Review the output and fix any findings **in your changed files** (ignore pre-existing issues in other files)
   - Re-run `coderabbit review --plain` after fixing to confirm clean
4. Commit with descriptive message
5. `git push`

**Do NOT commit before CodeRabbit has reviewed. Do NOT push if tests fail or CodeRabbit finds issues.**

The correct order is always: **test → analyze → coderabbit (uncommitted) → fix → commit → push**

## Code Style

### Imports

Order imports in this sequence, separated by blank lines:

1. `dart:` SDK imports
2. `package:flutter/` and third-party `package:` imports
3. `package:chuk_chat/` project imports

**Never use relative imports.** Always use `package:chuk_chat/...` for internal files.

### Naming

| Element | Convention | Example |
|---------|-----------|---------|
| Files | `snake_case.dart` | `chat_storage_service.dart` |
| Classes | `PascalCase` | `EncryptionService` |
| Compile-time constants | `kCamelCase` | `kPlatformMobile`, `kFeatureVoiceMode` |
| Variables / methods | `camelCase` | `selectedChatIndex` |
| Private members | `_prefixed` | `_cachedKey`, `_ensureKey()` |
| JSON serialization | `fromJson` / `toJson` | Standard on all model classes |

### Formatting & Patterns

- Use `const` constructors wherever possible
- Use `super.key` (not `Key? key` in constructor)
- Use `color.withValues(alpha: 0.5)` — **not** `color.withOpacity(0.5)` (deprecated)
- Use `unawaited()` for fire-and-forget futures
- Check `if (mounted)` before `setState()` after any async operation
- Models use `copyWith()` pattern with nullable parameters
- Services use singleton pattern: `const EncryptionService._()` with static methods

### Error Handling

- Use `try/catch` with specific exception types (`on AuthException`, `on DioException`)
- Use `ServiceErrorHandler` static methods: `handleDioException()`, `tryAsync()`, `isNetworkError()`
- Throw `StateError` for business logic errors with user-facing messages
- Use `catch (_)` only for non-critical background failures

### State Management

No third-party state management (no Provider, Riverpod, Bloc). Uses:
- `ChangeNotifier` / `ValueNotifier` for reactive updates
- Supabase `auth.onAuthStateChange` stream for auth state
- `ChatStorageService` with static methods for chat data
- Compile-time `const bool` flags for platform/feature gating

## Privacy & Logging

**All logs are disabled in release builds.** `debugPrint()` is NOT a no-op in release.

- **ALWAYS** wrap `debugPrint()` in `if (kDebugMode) { ... }`
- **NEVER** log message content, tokens, passwords, or emails
- OK to log: lengths, counts, IDs, status codes
- Alternative: use `pLog()` from `lib/utils/privacy_logger.dart` (auto-guards with `kDebugMode`)

## Platform Rules

Feature flags are defined in `lib/platform_config.dart` via `--dart-define`:

| Flag | Android | Linux/Web |
|------|---------|-----------|
| `PLATFORM_MOBILE` | `true` | omit |
| `FEATURE_PROJECTS` | `false` | `true` |
| `FEATURE_VOICE_MODE` | `false` | `true` |
| `FEATURE_IMAGE_GEN` | always on | always on |

- When adding UI features, implement in **both** `chat_ui_desktop.dart` **and** `chat_ui_mobile.dart`
- Web cannot use `dart:io` — use `package:chuk_chat/utils/io_helper.dart` instead
- Web credentials: `--dart-define` unreliable with dart2js. `Dockerfile.web` generates `lib/web_env.dart`. Priority: `--dart-define` > `web_env.dart` > `.env`.

## Critical Gotchas

1. **Message field preservation**: Preserve ALL fields including `images` and `attachments` when loading from storage.
2. **Mobile image sending**: Capture `attachedFiles` BEFORE clearing in `setState`, then pass to streaming handler.
3. **Image persistence**: Use `MessageCompositionService.prepareMessage()`, encode images as `jsonEncode(images)`.
4. **Mobile streaming focus**: Do NOT refocus text field on every streaming token.
5. **Theme/customization sync**: Must update both `SharedPreferences` (local) and Supabase (remote).
6. **Encryption**: All chat data is encrypted client-side. Never log or commit unencrypted data.
7. **Supabase onAuthStateChange**: Fires an initial event synchronously when you subscribe. Guard against races.
8. **Image cache**: Limited by bytes only (50 MB), NOT by pixel count. See `lib/utils/lru_byte_cache.dart`.

## Project Structure

```
lib/
  main.dart                     # Entry point, theme/auth
  platform_config.dart          # Compile-time feature flags
  models/                       # Data models (chat_message, stored_chat, etc.)
  services/                     # ~30 services (auth, chat, storage, encryption, etc.)
  pages/                        # Full-page UIs (login, settings, pricing, etc.)
  widgets/                      # Reusable widgets (auth_gate, message_bubble, etc.)
  platform_specific/
    chat/
      chat_ui_desktop.dart      # Desktop chat implementation
      chat_ui_mobile.dart       # Mobile chat implementation
      handlers/                 # Streaming, persistence, attachments, audio
      widgets/                  # Platform-specific chat widgets
    sidebar_desktop.dart
    sidebar_mobile.dart
  utils/                        # Logging, validation, error handling, crypto
test/
  models/                       # Model tests
  services/                     # Service tests
  utils/                        # Utility tests
```

## Adding Common Things

- **New service**: Create in `lib/services/`, use const constructor or static methods, initialize in `main.dart` if needed
- **New page**: Create in `lib/pages/`, add navigation in both sidebars, use `Theme.of(context)` for colors
- **New feature flag**: Add `const bool` in `platform_config.dart` with `bool.fromEnvironment()`, gate with `if (kFeatureX)`
- **Database migration**: Add SQL in `migrations/`, update service/model, run in Supabase SQL Editor

## Key Docs

| Doc | Topic |
|-----|-------|
| `docs/ARCHITECTURE.md` | Services, state, platform abstraction |
| `docs/FILE_MAP.md` | Complete file locations |
| `docs/GOTCHAS.md` | **Read this first** — critical bugs to avoid |
| `docs/COMMON_TASKS.md` | Step-by-step for adding services, pages, features |
| `docs/DATABASE.md` | Supabase tables and schema |
| `docs/LINUX_BUILDS.md` | Fastlane packaging (DEB, RPM, AppImage, Flatpak) |

## API Server

Separate repo at `/home/user/git/api_server/`. FastAPI + Supabase + Stripe.
- No test suite — verify with `python3 -c "import py_compile; py_compile.compile('main.py', doraise=True)"`
- Pre-existing LSP type errors (mutagen, fal_client, Supabase dynamic typing) are not bugs
- User-scoped endpoints must pass `user.client` to PaymentService methods (not admin client)
