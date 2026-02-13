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

# Static analysis
flutter analyze

# Format code
dart format .

# Run locally (loads .env automatically)
./run.sh linux          # desktop
./run.sh android        # mobile

# Build Android (ALWAYS use --release, debug is unusably slow)
flutter build apk --release \
  --dart-define-from-file=.env \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_PROJECTS=false \
  --dart-define=FEATURE_VOICE_MODE=false \
  --tree-shake-icons --target-platform android-arm64

# Build Linux
flutter build linux --release --dart-define-from-file=.env

# Build all platforms
./scripts/build-release.sh all
```

### Mandatory Post-Task Workflow

1. `flutter test` — all must pass
2. `coderabbit review --plain` (timeout 300s) — fix any findings
3. Commit with descriptive message
4. `git push`

**Do NOT push if tests fail or CodeRabbit finds issues.**

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

**All logs are disabled in release builds.** Strict rules:

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
- Always use `--dart-define-from-file=.env` for credentials, never `source .env`

## Critical Gotchas

1. **Message field preservation**: When loading messages from storage, preserve ALL fields including `images` and `attachments` in both desktop and mobile UIs.
2. **Mobile image sending**: Capture `attachedFiles` BEFORE clearing in `setState`, then pass the captured list to the streaming handler.
3. **Image persistence**: Use `MessageCompositionService.prepareMessage()` and encode images as `jsonEncode(images)` in `userMessage['images']`.
4. **Mobile streaming focus**: Do NOT refocus text field on every streaming token.
5. **Theme/customization sync**: Changes must update both `SharedPreferences` (local) and Supabase (remote).
6. **Encryption**: All chat data is encrypted client-side. Never log or commit unencrypted data.
7. **Web credentials**: `--dart-define` is unreliable with dart2js. `Dockerfile.web` generates `lib/web_env.dart` at build time. Priority: `--dart-define` > `web_env.dart` > `.env`.

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
