# CLAUDE.md

**chuk_chat** — Cross-platform Flutter chat app with E2E encryption, Supabase backend, AI chat.

## Workflow Rules

**After completing any task, ALWAYS do this in order:**

1. `flutter test` — all must pass
2. `coderabbit review --plain --type uncommitted` (timeout 300s) — fix any findings
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

| Flag | Default | Notes |
|------|---------|-------|
| `PLATFORM_MOBILE` | `false` | Mobile UI layout (set `true` for Android) |
| `FEATURE_PROJECTS` | `false` | Project workspaces |
| `FEATURE_VOICE_MODE` | `false` | Voice mode button |
| `FEATURE_IMAGE_GEN` | **always on** | Hardcoded, no flag needed |
| `FEATURE_SERVER_TOOLS` | `false` | GitHub, Slack, Gmail, Google Calendar, Email, Nextcloud (need backend OAuth) |
| `FEATURE_LINUX_KEYRING` | `false` | Use libsecret/keyring for encryption key (causes 10s+ startup stall) |
| `FEATURE_SYSTEM_TRAY` | `false` | System tray integration on desktop |

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

**Local testing builds:** To avoid `INSTALL_FAILED_VERSION_DOWNGRADE`, temporarily set a high build number in `pubspec.yaml` (e.g. `1.0.48+9000`) before building. This raises the Android version code without bumping the release version. Revert `pubspec.yaml` after installing — do NOT commit the build number change.

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

1. Bump version in `pubspec.yaml` (e.g. `1.0.49` → `1.0.50` — no `+buildnumber` suffix)
2. Commit: `git commit -am "chore: bump version to 1.0.50"`
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
5. **Immediately** after triggering CI, update the release notes on the draft release:
   ```bash
   gh release edit v1.0.50 --notes "$(cat <<'NOTES'
   ## What's New
   ### Section
   - Change description
   NOTES
   )"
   ```
   Write the notes from git commits (`git log <prev-tag>..HEAD --oneline`). CI attaches artifacts to the same release tag.
6. Web deploys automatically via Dokploy on push to master

**Repo is public** — only one release on `chuk-development/chuk_chat`. No second repo needed.

**Release notes = changelog only.** Write what changed (from git commits), grouped by category. NEVER include download instructions, architecture explanations, platform lists, or "build artifacts" notices.

**Note:** Do not rely on git tags to trigger releases. Use `workflow_dispatch` for `build-cross-platform.yml`.

## Local Cache Architecture

Chat payloads stored in **SQLite database** (`chat_cache.db`) on all native platforms. No local encryption — the encryption key lives on the same device, so local encryption was security theater.

- **Native (Android/iOS/Linux/Windows/macOS)**: SQLite via `sqflite_common_ffi`
- **Web**: SharedPreferences fallback (always online, small cache)
- **Server-side encryption**: Unchanged. AES-256-GCM, E2E, zero knowledge.
- **Local cache fields**: `payload` + `title` (plaintext in SQLite)
- **Supabase fields**: `encrypted_payload` + `encrypted_title` (encrypted)
- **Safety**: Different field names prevent accidentally sending plaintext to Supabase
- **Chat loading**: Cache-first via `loadFullChat()` — instant from SQLite, Supabase sync in background
- **Preload**: On-demand only (search/export triggers `ChatPreloadService.awaitPreload()`)
- **KV cache**: Generic `kv_cache` table in SQLite for projects and other larger data
- **SharedPreferences**: Only for small settings (~200 KB). NEVER store large data in SharedPreferences.

Key files: `lib/services/local_chat_cache_service.dart` (conditional export), `lib/services/local_chat_cache_native.dart` (SQLite), `lib/services/local_chat_cache_web.dart` (web fallback)

## Visual Output Tags

The AI can emit special tags in responses that the UI renders as interactive blocks (like tools, but no tool call needed):

| Tag | Renders as | Example |
|-----|-----------|---------|
| `<chart>` | Interactive chart (bar, line, pie, scatter, radar) | `<chart>{"type":"line","title":"...","labels":[...],"datasets":[...]}</chart>` |
| `<map>` | Interactive map (markers, places, routes) | `<map>{"type":"markers","markers":[{"lat":54.3,"lon":10.1,"label":"Kiel"}]}</map>` |
| `<email>` | Email card with "Open in Mail App" button | `<email>{"to":"...","subject":"...","body":"..."}</email>` |

Configured in `lib/services/tool_prompt_builder.dart`. Rendered in `lib/widgets/message_bubble.dart`.

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

## Agent Behavior Rules

### Planning
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately — don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes — don't over-engineer
- Challenge your own work before presenting it

### Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests — then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

### Task Management
1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

### Core Principles
- **Simplicity First**: Make every change as simple as possible. Impact minimal code
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards

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
