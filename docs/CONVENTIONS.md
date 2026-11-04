# Code conventions

This file holds the code conventions for chuk_chat. `CLAUDE.md` holds the
workflow rules (tests, CodeRabbit, commit, push, release, build flags). If this
file and `CLAUDE.md` do not agree, `CLAUDE.md` is correct. Fix this file.

## Tests and analysis

Use these commands while you work:

```bash
flutter test test/models/chat_message_test.dart   # one test file
flutter test --name "validateEmail"               # tests that match a name
flutter analyze                                    # static analysis
```

- `flutter analyze` must show no new issues for the files you changed.
- Format only the files that you changed: `dart format <file> ...`. Do not
  format a full directory. The repository uses an older formatter style. A
  full-directory format adds hundreds of unrelated lines to the diff, and
  CodeRabbit then reports old code as new findings.
- The tests use no mocking framework. Use real objects: real `DioException`
  instances and direct constructors.
- Where possible, put a test in the `test/` folder that agrees with the source
  folder. For example, a test for `lib/services/x.dart` goes in
  `test/services/`.

## Imports

Put imports in this sequence. Put one blank line between the groups.

1. `dart:` SDK imports.
2. `package:flutter/` imports and other third-party `package:` imports.
3. `package:chuk_chat/` project imports.

Do not use relative imports. Use `package:chuk_chat/...` for all project files.
(The demo files in `lib/demo/variants/` are an old exception. Do not copy them.)

## Names

| Item | Rule | Example |
|------|------|---------|
| Files | `snake_case.dart` | `chat_storage_service.dart` |
| Classes | `PascalCase` | `EncryptionService` |
| Compile-time constants | `kCamelCase` | `kPlatformMobile`, `kFeatureAgents` |
| Variables and methods | `camelCase` | `selectedChatIndex` |
| Private members | `_` prefix | `_cachedKey`, `_ensureKey()` |
| JSON on models | `fromJson` / `toJson` | All model classes |

## Dart and Flutter patterns

- Use `const` constructors where possible.
- Use `super.key`. Do not write `Key? key` in a constructor.
- Use `color.withValues(alpha: 0.5)`. Do not use `color.withOpacity(0.5)`. It
  is deprecated.
- Use `unawaited()` for a future that you do not wait for.
- After an `await`, check `if (mounted)` before you call `setState()`.
- Models use the `copyWith()` pattern with nullable parameters.
- Services use static methods and a private constructor, for example
  `const EncryptionService._()`.

## Errors

- Catch specific exception types: `on AuthException`, `on DioException`.
- Use the static methods of `ServiceErrorHandler`
  (`lib/utils/service_error_handler.dart`): `handleDioException()`,
  `tryAsync()`, `isNetworkError()`.
- Throw `StateError` for a business-logic error. Give it a message that the
  user can read.
- Use `catch (_)` only for a background failure that is not important.
- Do not only log an error in a `catch` block and then return. Update the UI
  state, so that the user sees the failure and can recover.

## State

The app uses no third-party state management (no Provider, no Riverpod, no
Bloc). It uses:

- `ChangeNotifier` and `ValueNotifier` for reactive updates.
- The Supabase `auth.onAuthStateChange` stream for the auth state.
- `ChatStorageService` with static methods for chat data.
- Compile-time `const bool` flags for platform and feature gates.

## Logs

`CLAUDE.md` ("Privacy: Logging") gives the log rules. Two more facts:

- `debugPrint()` also writes in a release build. Only the `kDebugMode` guard
  stops it.
- `pLog()` (`lib/utils/privacy_logger.dart`) adds the `kDebugMode` guard
  itself.

## Platforms

- A UI feature must work on desktop and on mobile. Make the change in
  `chat_ui_desktop.dart` and in `chat_ui_mobile.dart`
  (`lib/platform_specific/chat/`).
- The feature flags and their default values are in `CLAUDE.md`
  ("Feature Flags").

## Gotchas

`docs/GOTCHAS.md` gives the full list (message fields, mobile image send, image
persistence, streaming focus, theme sync, encryption). Two more:

- `auth.onAuthStateChange` sends an initial event immediately when you
  subscribe. Make sure that this first event does not cause a race.
- The decrypted-image cache has a limit in bytes (50 MB), not in pixels. See
  `lib/utils/lru_byte_cache.dart` and `lib/services/image_storage_service.dart`.

## Project layout

```
lib/
  main.dart                 entry point, theme, auth
  platform_config.dart      compile-time feature flags
  models/                   data models
  services/                 services (auth, chat, storage, encryption, ...)
  pages/                    full-page screens
  widgets/                  shared widgets
  platform_specific/
    chat/                   desktop and mobile chat, handlers/, widgets/
    sidebar_desktop.dart
    sidebar_mobile.dart
  utils/                    logs, validation, error handling, crypto
test/                       tests, mostly in the same folders as lib/
agents/                     Python side of Agents (see CLAUDE.md)
```

`docs/FILE_MAP.md` gives all file locations.

## Add a common item

- **Service:** Put it in `lib/services/`. Use static methods or a const
  constructor. If it needs a start step, call it from `main.dart`.
- **Page:** Put it in `lib/pages/`. Add the navigation in both sidebars. Get
  colors from `Theme.of(context)`. Follow `docs/DESIGN.md`.
- **Feature flag:** Add a `const bool` with `bool.fromEnvironment()` in
  `lib/platform_config.dart`. Gate the code with `if (kFeatureX)`. Add the flag
  to the table in `CLAUDE.md`.
- **Database change:** Add the SQL in `supabase/migrations/` with a timestamp
  prefix (`YYYYMMDDHHMMSS_name.sql`). Update the service and the model. Apply
  the SQL as `docs/DATABASE.md` tells you ("Applying a migration to
  production"). Do not use `supabase db push`. The old `migrations/` folder
  holds the base schema only.

`docs/COMMON_TASKS.md` gives the full steps.

## API server (`/home/user/git/api_server`)

FastAPI, Supabase and Stripe. The repository has its own `CLAUDE.md`. Read it
before you change the server.

- The server has a pytest suite in `tests/`. Run it before and after each
  change:
  `MEMGUARD_ALLOW_MB=8192 uv run --with pytest python -m pytest -q`.
- Some LSP type errors are old and are not bugs (mutagen, fal_client, Supabase
  dynamic types).
- A user-scoped endpoint gives `user.client` to the billing and payment
  service calls. Do not give the admin client.

## Releases

`CLAUDE.md` ("Creating a Release") gives the release steps. One more rule: make
few production releases. Usually make one planned release per day at most. An
urgent hotfix is the exception. For a local all-platform build, use
`./scripts/build-release.sh all`.
