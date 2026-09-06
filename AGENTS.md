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

1. Bump version in `pubspec.yaml` (e.g. `1.0.49` → `1.0.50` — **no** `+buildnumber` suffix)
2. Commit: `git commit -am "chore: bump version to 1.0.50"`
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
5. CI creates the GitHub Release with all artifacts automatically
6. Web deploys automatically via Dokploy on push to master

**Repo is public** — only one release on `chuk-development/chuk_chat`. No second repo needed.

**Release notes = changelog only.** Write what changed (from git commits), grouped by category (Performance, New Features, Bug Fixes, etc.). NEVER include download instructions, architecture explanations, platform lists, or "build artifacts will be attached" notices. Users can figure out downloads themselves.

**Release notes are mandatory for every new release** (no exceptions):

- Always summarize **all commits since the previous release**, not just changes from the current session.
- Scope must be: `last_release_tag..new_release_tag` (example: `v1.0.92..v1.0.93`).
- Build notes from commit messages and group by category (for example: New Features, Bug Fixes, Performance, Refactors, Dependencies, Maintenance).
- Keep notes as changelog text only (no download/install/platform instructions).
- Include both:
  - hash-linked commit list (`[abc1234](.../commit/<full_sha>)`)
  - compare link (`.../compare/<last_tag>...<new_tag>`) and explicit commit range hashes.
- Update the release body directly with `gh release edit` after generating notes from the full tag range.
- Preferred direct command pattern (no repo script required):
  ```bash
  gh release edit <new_tag> --notes-file <notes_file>
  gh release view <new_tag> --json body --jq .body
  ```

**Important:** The `Cross-Platform Build & Release` workflow is triggered by `workflow_dispatch` only. Do not rely on git tags to trigger releases.

### Mandatory Post-Task Workflow

**This workflow is non-negotiable. Follow it EVERY time you change code, in EVERY session.**

1. `flutter test` — all must pass
2. `flutter analyze` — 0 new issues (4 pre-existing info-level lints in `chat_ui_desktop.dart` OK)
3. **BEFORE committing**: run `coderabbit review --plain --type uncommitted` (timeout 300s) on your **uncommitted** changes
   - The `--type uncommitted` flag is **required** — without it CodeRabbit reviews all files and will fail with "Too many files" in large repos.
   - CodeRabbit only reviews uncommitted files. If you commit first, it won't see your changes.
   - Review the output and fix any findings **in your changed files** (ignore pre-existing issues in other files)
   - Re-run `coderabbit review --plain --type uncommitted` after fixing to confirm clean
4. Commit with descriptive message
5. `git push`

**Do NOT commit before CodeRabbit has reviewed. Do NOT push if tests fail or CodeRabbit finds issues.**

**Always push straight to `master`.** Do the work in one worktree, commit
everything there (including files the analyses/tools produce), and push it to
`master` — no long-lived feature branches, no waiting on a PR. A short-lived
branch while several agents run is fine, but when the work is done it lands on
`master`. If `master` moved, `git fetch` + `git merge origin/master` first, then
push. This overrides any "conservative: do not push" default in the Beads block.

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
| `docs/REMOTE_DEV_SETUP.md` | Agent on `claudecode`, app on the laptop: `flutter-remote` / `flutter-hotd` |

## API Server

Separate repo at `/home/user/git/api_server/`. FastAPI + Supabase + Stripe.
- No test suite — verify with `python3 -c "import py_compile; py_compile.compile('main.py', doraise=True)"`
- Pre-existing LSP type errors (mutagen, fal_client, Supabase dynamic typing) are not bugs
- User-scoped endpoints must pass `user.client` to PaymentService methods (not admin client)

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
