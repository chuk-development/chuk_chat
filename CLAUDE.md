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

## Agents (= CoWork) — naming and shape

**"CoWork" and "Agents" are the same product.** CoWork is the old name; when
the owner says CoWork, he means Agents. Code, flags and docs use "Agents".

- **One repository.** The Agents platform lives here and nowhere else: the
  Flutter controller is part of this app, the Python side (host, runtime,
  executor, manager, sandbox, shared packages) is under `agents/`. The old
  separate `cowork` repository and its `agents` branch are history only.
- **One build flag:** `FEATURE_AGENTS` (`lib/platform_config.dart`,
  `kFeatureAgents`). Off (default) = the app is plain chuk_chat, byte for
  byte in behaviour. On = the app is Agents: `MessengerShell` replaces
  `RootWrapper` (`lib/main.dart`). There is no runtime switch between the two.
- **Pairing is automatic and happens once.** The trust record is mirrored,
  encrypted, to Supabase; any install that signs in to the same account is
  linked again with no code, no QR and no host address
  (`lib/services/agents/agents_pairing_restore.dart`). The connection is the
  blind cloud relay `wss://api.chuk.chat/v2/relay/ws` (api_server,
  `routers/cowork/`). No user-visible host URL, port or "WebSocket" wording.
- **Design:** Agents keeps its design (`docs/agents/DESIGN.md` if present,
  otherwise the rules in the reference), fitted to chuk_chat's theme so the
  two do not collide. No glow — no coloured `BoxShadow`, ever.
- Run it: `FEATURE_AGENTS=true ./run-hot.sh linux`.

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

## Git Workflow (default: no worktrees)

**Default: work directly in `/home/user/git/chuk_chat` on `master`, commit and
push straight to `master`.** No feature branch, no worktree. That is the normal
case, because normally exactly one agent works this repo.

A `git worktree` is the **exception, not the rule**. Create one only when there
is a real conflict risk that cannot be solved otherwise:

- another agent is already working in the main checkout at the same time, and
- talking to that agent (`SendMessage` / `ListAgents`) does not resolve who owns
  which files.

Prefer coordination over isolation: ask the other agent what it touches, split
the files, work sequentially. A worktree is the last resort.

**If a worktree really is needed:**

```bash
git worktree add ../chuk_chat-<task> -b agent/<task> master
cp .env ../chuk_chat-<task>/.env    # gitignored, NOT carried into a fresh worktree
cd ../chuk_chat-<task>
```

**When the work is finished — `flutter test` green, CodeRabbit findings all
fixed — it is integrated, and then the worktree gets deleted; always, no
leftovers:**

```bash
git push origin agent/<task>:master      # integrate
cd /home/user/git/chuk_chat
git worktree remove ../chuk_chat-<task>
git branch -d agent/<task>
git worktree prune
```

The directory must not survive the task. `git worktree list` shows leftovers.

**Rules:**
- Default is master in the main checkout. Do not create branches/worktrees "for
  cleanliness".
- Never two agents in the same directory.
- A worktree without `.env` builds and shows "Supabase credentials are not
  configured".
- Every created worktree is removed after the push. Done means gone.

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
per-dep reasoning lives in the `pubspec.yaml` header block. No direct dep is
held back any more (verified 2026-09-23: `flutter pub outdated` shows every
direct dep at latest). The old caps on `dynamic_color`, `flutter_secure_storage`,
`permission_handler` and `app_links` are gone (`compileSdk = 37`). What is left
behind are transitive deps capped by their parents, listed in the header.
The vendored `vendor/markdraw/pubspec.yaml` carries its own constraints (e.g.
`file_picker <14`) — widen them there when a major lands.

**Windows caveat:** the whole lock now needs Dart ≥3.13 (`tray_manager` 0.7 /
`nativeapi` 0.3; `environment.sdk` says so), so every CI job (Windows included)
must stay on Flutter ≥3.47 — an older job would fail to resolve. Flutter's Windows renderer can show a black window
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

**Showing an image to the user: open it in qimgv on their display**, do not
only hand over the file path or send the file. One command, detached:
`(DISPLAY=:1 setsid qimgv <file> >/dev/null 2>&1 </dev/null &)`. The arrow keys
then walk the whole folder, which is what makes a set of screenshots judgeable.

**Starting the app for live/hot-reload work: ALWAYS use `./run-hot.sh`**, never
`flutter-hot start` bare. Bare `flutter-hot` runs `flutter run` with no
`--dart-define`, so Supabase creds are missing and feature flags fall back to
the production defaults in `platform_config.dart` — which makes Voice mode
visible again and drops the other run.sh flags. `run-hot.sh` reuses run.sh's
exact defines (`PRINT_DEFINES=1 ./run.sh`) + `CHUK_MULTI_INSTANCE=1`. Voice mode
is OFF by default in run.sh; Agents (= CoWork) is OFF by default too — turn it
on per run with `FEATURE_AGENTS=true ./run-hot.sh linux`.

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
| `FEATURE_PAYMENTS_DIRECT` | **`true`** | Stripe. MUST be false for Play Store builds — `fastlane build_aab` forces `false`, see `docs/FASTLANE.md` |
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

`./run.sh` turns on skills, server tools, artifacts and (on desktop) the
tray. Voice mode is off by default, as are the Linux keyring and the other
broken or costly flags. Override any of them per-run:
`FEATURE_SKILLS=false ./run.sh linux`.

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

- Always summarize **all commits since the previous release**, not just changes from the current session. Merge commits are the one exception — they carry no content of their own.
- Scope must be: `last_release_tag..new_release_tag` (example: `v1.0.92..v1.0.93`).
- Build notes from commit messages and group by category (for example: New Features, Bug Fixes, Performance, Refactors, Dependencies, Maintenance).
- Keep notes as changelog text only (no download/install/platform instructions).
- Include both:
  - hash-linked commit list (`[abc1234](.../commit/<full_sha>)`)
  - compare link (`.../compare/<last_tag>...<new_tag>`) and explicit commit range hashes.
- Update the release body directly with `gh release edit` after generating notes from the full tag range.
- **Generate the notes with `scripts/release_notes.py`** — it reads the git
  history, groups the commits by conventional-commit type, hash-links every
  commit and appends the compare link:
  ```bash
  git fetch --tags
  mkdir -p _scratch
  python3 scripts/release_notes.py v1.0.110 > _scratch/notes.md   # previous tag detected
  gh release edit v1.0.110 --notes-file _scratch/notes.md
  gh release view v1.0.110 --json body --jq .body
  ```
  A stable tag compares against the previous stable tag; a `-pre.N` tag compares
  against the tag right before it.
- **A release without a changelog is a broken release.** CI writes the changelog
  itself (`Generate release notes` step in `build-cross-platform.yml`, which
  calls the same script), so never replace a release body with download or
  install instructions. If a release body ever shows only the old "## Downloads"
  boilerplate, regenerate it with the script and push it back with
  `gh release edit`.

**Note:** Cut a release with `workflow_dispatch` on `build-cross-platform.yml`
— that is the path that tags and builds in one go. The workflow does
also react to a pushed `v*` tag, and then takes the tag from the push instead
of from `pubspec.yaml`, but pushing a tag by hand is not the normal way in.

## Local Cache Architecture

Chat payloads stored in **SQLite database** (`chat_cache.db`) on all native platforms. No local encryption — the encryption key lives on the same device, so local encryption was security theater.

- **Native (Android/iOS/Linux/Windows/macOS)**: SQLite via `sqflite_common_ffi`
- **Web**: SharedPreferences fallback (always online, small cache)
- **Server-side encryption**: Unchanged. AES-256-GCM, E2E, zero knowledge.
- **Local cache fields**: `payload` + `title` (plaintext in SQLite)
- **Payload format**: v3 JSON everywhere, compressed (cache: deflate frame; cloud: bzip2/deflate frame inside an AES envelope `{"v":"2"}`). Build payloads only with `encodeChatPayload`/`encodeChatPayloadAsync` and seal them with `EncryptionService.encryptChatPayload`. See `docs/CHAT_PAYLOAD_FORMAT.md`
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
| `docs/ASSISTANT_SURFACE.md` | Android assistant surface: assist role, overlay, device tools, the pinned model |
| `docs/MCP_CONNECTORS.md` | Remote MCP connectors: the OAuth flow, storage, tool naming |
| `docs/CHAT_PAYLOAD_FORMAT.md` | Chat payload v3 (no duplicates), compression frame, envelope `v:"2"`, old-client behaviour, the one-time migration behind the blocking maintenance screen |
| `docs/LINUX_BUILDS.md` | Fastlane packaging (DEB, RPM, AppImage, Flatpak) |
| `docs/REMOTE_DEV_SETUP.md` | Agent on `claudecode`, app on the laptop: `flutter-remote` / `flutter-hotd` |
| `docs/FASTLANE.md` | Fastlane: generated store screenshots, Play + F-Droid metadata, upload lanes |
| `docs/SCREENSHOTS.md` | **Read before recapturing any screenshot** — the seven gallery shots, the store frames, the painted backdrop, the traps |


## Fastlane / Play Store / F-Droid

`docs/FASTLANE.md` is the reference. The short version:

- Fastlane compiles nothing; every lane shells out to `flutter build`. Lanes run
  on this machine, on a GitHub runner, or on a Mac for macOS/iOS.
  **No build server is needed.**
- Install once: `sudo apt install ruby-dev build-essential`, then
  `gem install --user-install bundler` (a plain `gem install` hits
  `Gem::FilePermissionError` on `/var/lib/gems`), then
  `export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"` — RubyGems does not
  add that directory itself, so `bundle` is otherwise not found — and finally
  `bundle install` at the repository root. Then
  `cd android && bundle exec fastlane lanes`.
- **One `Gemfile`, at the root, with a committed `Gemfile.lock`.** Bundler walks
  up from the working directory, so it serves `android/`, `linux/` and `macos/`.
  Do not re-add per-platform Gemfiles — that is how the repo ended up with three
  unlocked dependency sets and a plugin no Fastfile called.
- **`fastlane/metadata/android/` lives at the repository root, not under
  `android/`.** That is the path F-Droid reads straight out of the git repo;
  `supply` is pointed at the same tree via `metadata_path`, and the README
  embeds the same PNGs. Do not move it back.
- **Store screenshots are captured on a real device, by hand:**
  capture into `fastlane/screenshots_raw/<locale>/`, then run
  `./scripts/frame_screenshots.sh`, which frames every capture into
  `fastlane/metadata/android/<locale>/images/phoneScreenshots/`.
  `scripts/device_screenshots.sh --demo on` freezes the status bar first.
  Recapture when the UI changes, before a release, and commit both trees.
  **There is no screenshot workflow any more** — the old `screenshots.yml`
  committed headlessly rendered widgets on every push to `master` and
  overwrote every real capture. Do not bring it back.
  Before capturing, put the status bar in demo mode (fixed clock, full
  battery, no notification icons) and use an account with no private content —
  see `docs/FASTLANE.md`. The headless harness (`flutter test test_screenshots`)
  is only the fallback when no device is available.
- **`build_aab` hardcodes `FEATURE_PAYMENTS_DIRECT=false`** — a Play build that
  ships the direct Stripe flow puts the listing at risk. `build_apk` (direct
  downloads) keeps it on. Do not merge the two flag sets.
- `pubspec.yaml` has no `+build` suffix, so the build number is derived from the
  semantic version: `major*100_000 + minor*1_000 + patch` (`1.0.109` → `100109`).
  **The same formula is in `android/fastlane/Fastfile`, `build.sh` and
  `build-cross-platform.yml` and they must stay identical**, or an APK from one
  path cannot upgrade an APK from another. It must stay under 2 100 000 because
  `--split-per-abi` multiplies it by 1000.
- Play production access needs a 12-tester closed test over 14 days first, so
  the upload lanes are pre-work. The F-Droid tree and the README screenshots
  pay off today.

# Agents platform

The sections below came in with the Agents tree (phone drives an agent on
the user's own machine). They are additional to everything above, not a
replacement: the chuk_chat rules keep applying to the app.

## App inspection and screenshots (user instruction, 2026-09-05)

- Read this file first. `AGENTS.md` links to this file so all agents use the same instructions.
- Never capture the user's desktop, monitor, root window, or unrelated windows. Capture only the explicitly identified project app window; verify its PID/executable and window ID first. If no matching window is available, stop the capture rather than falling back to the desktop.
- Use `xdotool` and native Linux tools. Do not use Orca computer-use.
- Use the existing `flutter-hot` / Flutter Hot Reload workflow. Window-only capture already exists in `/home/user/.claude/tools/flutter-hotd`; prefer reusing that capability with verified project-window ownership.
- On Wayland, run the project app with `GDK_BACKEND=x11` when needed for window-specific capture. Record only a short note containing the project, PID/window ID and capture command; never assume IDs survive a restart.
- Keep this as a short operational note, not a screenshot tutorial.
- Local workflow: from the repository root, `FEATURE_AGENTS=true ./run-hot.sh linux`, then `flutter-hot reload`; capture with `bash scripts/capture_app_window.sh _scratch/agents-window.png` from the repository root. The helper validates executable/PID/window ownership and prints the selected IDs; no desktop fallback.
- If GNOME reports `org.gnome.ScreenSaver.GetActive = true`, window pixels may be stale: defer visual acceptance until the user unlocks; never unlock the session automatically.

## Shell and task tracking

- Use non-interactive file operations (`cp -f`, `mv -f`, `rm -f`) and narrowly resolved targets.
- Use the project Beads skill at `.agents/skills/beads/SKILL.md`, then `bd prime` for current workflow context. Use `bd` for task tracking and `bd remember` for persistent project memory; never create ad hoc memory files.

## Build & Test

### Android APK (user instruction, 2026-09-10)

- **Always build the Agents phone app with `scripts/build_apk.sh`.** Never
  hand-roll `flutter build apk` for it. Supabase URL/key come from `.env` via
  `--dart-define-from-file`, and the script sets `FEATURE_AGENTS=true`. Without
  them the APK installs and then shows plain chuk_chat or a dead app.
- **arm64 only** (`--target-platform android-arm64`, ~47 MB). The phone is a
  Pixel 7 Pro. Never build the fat APK or `--split-per-abi`.
- **Deliver by `adb install -r`, not by any other route.** adb over USB is the
  transport; the script installs and launches `dev.chuk.chat` itself (one
  app: Agents is chuk_chat built with the flag, same package). Do not
  serve the APK over HTTP and do not try `SendUserFile` (30 MiB limit; the APK
  is bigger).
- Build only: `scripts/build_apk.sh --no-install`.

```bash
scripts/build_apk.sh          # arm64 release + adb install + launch
```

### Android emulator (user instruction, 2026-09-11)

- The local AVD is the second target next to the Pixel 7 Pro. Start it with
  `scripts/emulator.sh start` (creates `cowork_x64` on first run: Android 16 /
  API 36, `google_apis`, **x86_64**, Pixel 7 Pro profile, 4 GB RAM, 8 GB data).
- **x86_64, never arm64.** The host is x86_64, so an arm64 image runs without
  KVM and is too slow to use. `hw.gpu.mode=host` puts rendering on the RTX 3060
  over Vulkan; the emulator log names the physical GPU it picked.
- Gradle follows Flutter: `android/app/build.gradle.kts` reads the
  `target-platform` property, so a phone build stays arm64-v8a and an emulator
  build is x86_64. Do not pin the ABI again.
- Release APK on the AVD: `scripts/build_apk.sh --emulator` (picks the
  `emulator-*` serial; the plain call still picks the phone).
- Hot reload on the AVD, from the repository root:
  `FEATURE_AGENTS=true ./run-hot.sh emulator-5554`.
- Cost on this machine: the emulator idles near half a core and holds about
  5 GB RSS, so the script starts it under `memguard-allow 8G`. The CPU spike
  during `flutter run` is the Gradle daemon and the Dart frontend, not the VM.
  The daemon keeps about 4 GB after a build; kill it when RAM gets tight.
- Other commands: `scripts/emulator.sh status|wait|shot [out.png]|stop`.

## Arbeitsweise: Subagenten machen die Arbeit, ich pruefe das Bild

Anweisung des Nutzers (2026-09-11): **Wo eine Aufgabe sich abgrenzen laesst, wird
sie an einen Subagenten gegeben, nicht selbst getippt.** Der Koordinator
beschreibt genau, was zu tun ist, welche Dateien tabu sind (mehrere Agenten
arbeiten im selben Working Tree) und welche Tests gruen sein muessen.

- Mehrere Subagenten parallel, wenn die Dateimengen sich nicht ueberschneiden.
  Jedem Agenten die Liste der fremden Dateien mitgeben, die er nicht anfassen
  darf.
- **Der Koordinator prueft das Ergebnis am Bild**, nicht am Bericht: bauen
  (`scripts/build_apk.sh --emulator`), `scripts/emulator.sh shot` und den
  Screenshot wirklich ansehen. Sieht es nicht gut aus, geht die naechste Runde
  an den naechsten Subagenten - so oft wie noetig. Dauer ist egal, das Ergebnis
  zaehlt.
- Der Koordinator committet; die Subagenten committen nicht.

## Design

All UI follows `docs/DESIGN.md` — Material 3 Expressive, one button family, no
glows, files as their own messages. Read it before adding or changing a screen,
and run its checklist before calling one done.

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_

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
