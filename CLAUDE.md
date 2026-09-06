# CLAUDE.md

**chuk_chat** — Cross-platform Flutter chat app with E2E encryption, Supabase backend, AI chat.

## Backend / API server (local repo)

The API server code lives at **`/home/user/git/api_server`** (deployed at
`api.chuk.chat`). Do NOT claim ignorance about it — read it there.

- **Models endpoint the client calls:** `GET /v1/models_info` — `api_server/main.py:2523`.
- **Model registry / list logic:** `api_server/model_info/service.py`. Static
  data: `model_info/models_cache.json` (per-model provider list, incl.
  `fireworks_model_id` mappings), `model_info/direct_prices.json` (direct
  provider prices, keyed under `prices/<provider>`), `model_info/data/model_icons.json`.
- **Direct providers registry:** `api_server/direct_providers.py`
  (`DIRECT_PROVIDERS`, e.g. `fireworks`). Provider slugs the client pins map here.
- **Known model ids:** DeepSeek V4 Flash = `deepseek/deepseek-v4-flash-0731`,
  V4 Pro = `deepseek/deepseek-v4-pro-0813`, GLM 5.3 Flash = `z-ai/glm-5.3-flash`
  (priced via orcarouter in `direct_prices.json`; fireworks direct catalog
  carries glm-5p2/5p1, i.e. GLM 5.2/5.1, not 5.3-flash).

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
2. `coderabbit review --uncommitted --include-untracked` — fix any findings.
   Plain text is the default now; `--plain` and `--type` were removed from the
   CLI. **`--include-untracked` matters**: a newly added file is invisible to
   the review without it. Runs take 10–20 min, so start it in the background
   rather than under a short timeout.
3. Commit with descriptive message
4. `git push`

**Do NOT push if tests fail or CodeRabbit finds issues. Fix first.**

**Always push straight to `master`.** Do the work in one worktree, commit
everything there (including any files the analyses/tools produce), and push it
to `master` — no long-lived feature branches, no waiting on a PR. If `master`
moved under you, `git fetch` + `git merge origin/master` first, then push. This
overrides any "conservative: do not push" default in the Beads block below.

## Bug/Task tracking with `bd` (mandatory)

`bd` (beads) is this project's task board — use it, always. For EVERY new bug or
task you discover, create a `bd` issue (`bd create "<title>" -d "<detail>" -l bug`)
before or as you start on it. Claim it while working (`bd update <id> --claim`),
and close it the moment it is done and verified (`bd close <id>`). Treat it as
your personal kanban: nothing worked on without a bead, nothing left open once
fixed. Do NOT use TodoWrite or ad-hoc markdown checklists for this. The same rule
holds in the `api_server` repo, which has its own `bd` database.

## Multi-Agent Worktrees

**HARD RULE — a new feature branch always means a new local worktree.** Whenever
you start a new feature branch, create it in its own `git worktree` (off `master`)
and do the work there. NEVER check out a different branch inside the main checkout
(`/home/user/git/chuk_chat`) or the main CoWork directory — each of those stays on
its own branch (normally `master`) and is never switched to another task's branch.
Do not commit an unrelated fix onto whatever branch the main checkout happens to be
sitting on; branch it into a fresh worktree instead. This keeps every task's history
isolated and stops one task's in-progress work from riding along with another's.

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

## Dependency Ceilings

CI runs **Flutter 3.47.0 (Dart 3.13)** on every platform (pinned in
`.github/workflows/*` and `codemagic.yaml`). The old re_editor 0.8.0 ceiling that
held CI at 3.41.4 is gone — `vendor/markdraw` now uses `re_editor ^0.10.0`.

When asked to "update everything", run `flutter pub upgrade --major-versions`,
then fix the fallout and only hold a dep back when you have **verified** it breaks
(analyze/test error, or `cd android && ./gradlew :app:tasks` fails). Do not trust a
stale "capped because X" comment — check whether X is still true first. The full
per-dep reasoning lives in the `pubspec.yaml` header block. Four deps are held for
real reasons, all gated on an AGP 9 / Gradle 9 / compileSdk 37 toolchain jump:
`dynamic_color <2` (material_ui ColorScheme split), `flutter_secure_storage <11`
and `permission_handler <13` (their `_android` majors hardcode compileSdk 37),
`app_links <7.2` (AGP-9 plugins-DSL the 3.47 loader mis-orders). Everything else
is at its latest resolvable version.

**Windows caveat:** the whole lock now needs Dart ≥3.12, so every CI job
(Windows included) must stay on Flutter ≥3.44 — reverting the Windows job to
3.41.4 would fail to resolve. Flutter's Windows renderer can show a black window
on GPUs/VMs limited to D3D11 feature level 9_3 (ANGLE fallback, a cross-version
issue). Test the Windows artifact on such hardware before publishing a release.

## Quick Start

```bash
cp .env.example .env       # First time: add Supabase credentials
./run.sh linux             # Run desktop
./run.sh android           # Run mobile
./run-hot.sh linux         # Run desktop under flutter-hot (hot reload)
flutter test               # Run tests
flutter analyze            # Static analysis
```

**Starting the app for live/hot-reload work: ALWAYS use `./run-hot.sh`**, never
`flutter-hot start` bare. Bare `flutter-hot` runs `flutter run` with no
`--dart-define`, so Supabase creds are missing and feature flags fall back to
the production defaults in `platform_config.dart` — which makes Voice mode
visible again and drops the other run.sh flags. `run-hot.sh` reuses run.sh's
exact defines (`PRINT_DEFINES=1 ./run.sh`) + `CHUK_MULTI_INSTANCE=1`. Voice mode
is OFF by default in run.sh; CoWork was removed from this branch (developed
elsewhere) — do not re-add it here.

**Working from the `claudecode` host:** the agent runs there, the app runs on the
laptop. Use `flutter-remote` instead of `flutter-hot` — same verbs, plus `sync`,
`shot` and `projects`. See `docs/REMOTE_DEV_SETUP.md`.

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
| `FEATURE_SERVER_TOOLS` | `false` | GitHub, Slack, Gmail, Google Calendar (need backend OAuth) |
| `FEATURE_SKILLS` | `false` | Agent Skills — `skill` tool + on-demand prompt blocks (see below) |
| `FEATURE_MCP` | **`true`** | Remote MCP connectors — OAuth sign-in in the browser, tools join the registry. See `docs/MCP_CONNECTORS.md`. Native only (web has no loopback port) |
| `FEATURE_SYSTEM_TRAY` | `false` | System tray on desktop. **Also suppresses `window_close_service`** — with it on, closing the window minimises to tray instead of quitting |
| `FEATURE_LINUX_KEYRING` | `false` | Use libsecret/keyring for encryption key (causes 10s+ startup stall) |
| `FEATURE_SPOTIFY` | `false` | Leave off — the API server no longer exposes the OAuth route, so the tool registers and then fails at call time |

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

## MCP servers

When adding or editing an MCP server catalogue entry in
`lib/services/mcp/mcp_catalogue.dart`, set its `iconUrl` explicitly to the
real verified logo. Do not rely on the auto favicon fallback, which
mis-resolves service subdomains — `mcp.mail.…` gave Superhuman a Play-Store
icon, and `ai.todoist.net` gave Todoist none. A reliable choice is
`https://www.google.com/s2/favicons?domain=<brand.com>&sz=128`. Check the icon
actually loads before committing. See `docs/MCP_CONNECTORS.md`.

## Docs Index

| Doc | Topic |
|-----|-------|
| `docs/ARCHITECTURE.md` | Services, state, platform abstraction |
| `docs/FILE_MAP.md` | File locations, project structure |
| `docs/FEATURES.md` | Projects, Image Gen, Media Manager |
| `docs/DATABASE.md` | Supabase tables, schema |
| `docs/COMMON_TASKS.md` | Adding services, pages, features |
| `docs/GOTCHAS.md` | **CRITICAL** — bugs to avoid |
| `docs/MCP_CONNECTORS.md` | Remote MCP connectors: the OAuth flow, storage, tool naming |
| `docs/LINUX_BUILDS.md` | Fastlane packaging (DEB, RPM, AppImage, Flatpak) |
| `docs/REMOTE_DEV_SETUP.md` | Agent on `claudecode`, app on the laptop: `flutter-remote` / `flutter-hotd` |


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
