# CLAUDE.md

**chuk_chat** — Cross-platform Flutter chat app with E2E encryption, Supabase backend, AI chat.

## ▶ Active plan: CoWork

**`docs/COWORK_EXECUTION_PLAN.md`** is the live, ordered build plan for CoWork
(phone drives an agent running on the user's own laptop).

When the user says **"führe den CoWork-Plan aus"** — read that file, take the
first milestone whose box is unchecked, and dispatch the subagents listed under
it. It carries the verified state of the world, the per-milestone subagent
breakdown, and the traps. **One milestone per session**, ending in green tests,
a clean CodeRabbit and a commit — then tick the box.

`docs/COWORK_BUILD_PLAN.md` stays the architectural reference (system diagram,
threat model, decisions). The execution plan is the order of work.

## Workflow Rules

**After completing any task, ALWAYS do this in order:**

1. `flutter test` — all must pass
2. `coderabbit review --plain --type uncommitted` (timeout 300s) — fix any findings
3. Commit with descriptive message
4. `git push`

**Do NOT push if tests fail or CodeRabbit finds issues. Fix first.**

## Multi-Agent Worktrees

When several agents work this repo at once, **each agent gets its own git worktree** so they never touch the same working directory. A worktree is a second checkout of the same repo on its own branch, sharing one `.git` — parallel-safe because `.dart_tool/` and `build/` are per-directory.

**Each agent, on start:**

```bash
# 1. Create an isolated worktree + branch (name it after the task)
git worktree add ../chuk_chat-<task> -b agent/<task> master

# 2. Copy the gitignored .env — it is NOT carried into a fresh worktree
cp .env ../chuk_chat-<task>/.env

# 3. Work only inside that directory
cd ../chuk_chat-<task>
```

**Each agent, on finish** (follow the normal Workflow Rules first — `flutter test`, CodeRabbit, commit):

```bash
# From inside the worktree: commit on the agent/<task> branch, then
git push -u origin agent/<task>          # push branch, OR merge to master below
```

**Integrating branches** (one agent, or you, does this after all are done):

```bash
cd /home/user/git/chuk_chat              # main worktree on master
git merge --no-ff agent/<task>           # merge each branch in turn, resolve conflicts
git push
git worktree remove ../chuk_chat-<task>  # clean up finished worktree
git branch -d agent/<task>
```

**Rules:**
- One worktree per agent — never two agents in the same directory.
- Always `cp .env` into a new worktree; a build without it shows "Supabase credentials are not configured".
- `git worktree list` shows all active worktrees. `git worktree prune` removes stale entries.
- Branch names: `agent/<short-task>`. Keep changes on the branch; integrate to master via merge, not by editing master directly while agents run.

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
| `PLATFORM_MOBILE` | `false` | Mobile UI layout (set `true` for Android). Leave BOTH platform flags unset to let `kAutoDetectPlatform` pick from the device |
| `PLATFORM_DESKTOP` | `false` | Desktop UI layout |
| `FEATURE_WORKSPACES` | **`true`** | Workspaces (custom AI personas + files + memory) |
| `FEATURE_ARTIFACTS` | **`true`** | Editable code/markdown/HTML/drawing panels |
| `FEATURE_PAYMENTS_DIRECT` | **`true`** | Stripe. MUST be false for Play Store builds |
| `FEATURE_IMAGE_GEN` | **always on** | Hardcoded, no flag needed |
| `FEATURE_MEDIA_MANAGER` | **always on** | Hardcoded, no flag needed |
| `FEATURE_VOICE_MODE` | `false` | Voice mode button |
| `FEATURE_SERVER_TOOLS` | `false` | GitHub, Slack, Gmail, Google Calendar, Email, Nextcloud (need backend OAuth) |
| `FEATURE_SKILLS` | `false` | Agent Skills — `skill` tool + on-demand prompt blocks (see below) |
| `FEATURE_COWORK` | `false` | Chat↔CoWork switcher (M0 placeholder) |
| `FEATURE_SYSTEM_TRAY` | `false` | System tray on desktop. **Also suppresses `window_close_service`** — with it on, closing the window minimises to tray instead of quitting |
| `FEATURE_LINUX_KEYRING` | `false` | Use libsecret/keyring for encryption key (causes 10s+ startup stall) |
| `FEATURE_SPOTIFY` | `false` | Leave off — the API server no longer exposes the OAuth route, so the tool registers and then fails at call time |
| `FEATURE_WHOOP` | `false` | Leave off — integration removed server-side, same failure |

**There is no `FEATURE_PROJECTS`.** Nothing in `lib/` reads it; the flag is
`FEATURE_WORKSPACES`, and it already defaults to `true`. `build.sh`,
`codemagic.yaml` and `AGENTS.md` still pass `--dart-define=FEATURE_PROJECTS=…`,
which does nothing.

`./run.sh` turns on everything that works (skills, cowork, voice, server tools,
tray) and deliberately leaves the three broken/costly ones off. Override any of
them per-run: `FEATURE_SKILLS=false ./run.sh linux`.

## Agent Skills

Named procedures the AI loads on demand, following the open spec at
[agentskills.io](https://agentskills.io/specification). Progressive disclosure:
only `name` + `description` sit in every prompt; the body is injected under
`## ACTIVE SKILL` after the model calls the `skill` tool, and stays for the rest
of the conversation.

Authored as `assets/skills/<name>/SKILL.md`, validated and compiled into the
binary by `dart run tool/gen_skills.dart` → `lib/services/skills/builtin_skills.g.dart`.
**Nothing is fetched from a marketplace or URL at runtime** — 36.8% of publicly
shared skills carry a security flaw and 84% of those live in the SKILL.md prose
itself, which is processed with operator-level authority on activation.

**After editing any SKILL.md, re-run the generator.** `builtin_skills_freshness_test.dart`
fails if you forget.

Four built-ins migrate blocks that used to be injected unconditionally
(`weather-cards`, `news-cards`, `chart-authoring`, `deep-research`) — net
**−1145 tokens per round**. When adding a skill, keep `description` ≤300 chars:
it is level-1 weight charged to every prompt.

Adding the `skill` tool took four registration edits, not three — `builtinTools`,
`toolCategoryMap`, `_builtinExecutableToolNames`, and **`_nonFactualToolNames`**
(`tool_call_handler.dart`). Omitting the last makes every skill-only turn trigger
a spurious `[VERIFY]` fact-check round.

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
5. **Immediately** after triggering CI, update the release notes on the GitHub Release.
6. Web deploys automatically via Dokploy on push to master

**Repo is public** — only one release on `chuk-development/chuk_chat`. No second repo needed.

**Release notes = changelog only.** Write what changed (from git commits), grouped by category. NEVER include download instructions, architecture explanations, platform lists, or "build artifacts" notices.

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
