---
name: pre-push-checks
description: Use while editing chuk_chat and before committing or pushing, to pick the smallest set of tests that covers the change during the edit loop, and to run the repo checks and the full gate (all of flutter test plus CodeRabbit) that CLAUDE.md requires before a push.
---

# Pre-push checks (chuk_chat)

Two speeds. While you work, run only the tests that cover your diff. Before
a push, the rule in `CLAUDE.md` holds without exception: the **full**
`flutter test` is green and CodeRabbit has no open finding.

## 1. Edit loop: scoped tests

```sh
dart run tool/change_scope.dart              # vs merge base with origin/master
dart run tool/change_scope.dart --base HEAD  # only uncommitted work
```

It lists the changed files (committed since the merge base, staged,
unstaged, untracked) and prints a `flutter test <files>` command with:

- every changed `_test.dart`;
- the mirrored test, `lib/a/b.dart` -> `test/a/b_test.dart`;
- every test that imports a changed library.

It prints a bare `flutter test` when the change cannot be scoped:
`pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`,
`test/flutter_test_config.dart`, or a helper under `test/helpers/` or
`test/support/`. It prints a `#` comment when no Dart test covers the change
(docs only).

Limits: it follows direct imports only. A change reached through a widget
tree, a provider, a generated file (`lib/services/skills/builtin_skills.g.dart`)
or a platform channel can break tests it does not pick. When in doubt, add
the test of the screen or service that uses the code.

Also run `flutter analyze <changed files>` on every Dart file you touched.
Never `dart format` a directory (it reformats untouched code); format only
the files you changed, and only if they were formatted before.

## 2. Repo checks (fast, part of `flutter test`)

These run in the full suite. Run them alone when you touch what they guard:

| Touched | Run |
|---|---|
| `CLAUDE.md`, `docs/AGENTS.md`, `docs/CONVENTIONS.md`, `docs/GOTCHAS.md` | `flutter test test/repo_checks/doc_budget_test.dart` |
| any doc, or moved or renamed a file | `dart run tool/verify_doc_refs.dart` |
| `lib/` code | `flutter test test/repo_checks/ratchet_test.dart` (`// ignore`, `as dynamic`, postfix `!`, unguarded `debugPrint` may not go up) |
| `lib/l10n/` | `flutter test test/l10n_parity_test.dart` |
| `lib/services/local_chat_cache_native.dart` schema | `flutter test test/services/local_cache_schema_test.dart` |
| `assets/skills/*/SKILL.md` | `dart run tool/gen_skills.dart`, then its freshness test |

After you remove smells from `lib/`, lock the lower count in:
`dart run tool/ratchet.dart --update`.

The pre-commit hook (`.beads/hooks/pre-commit`) checks staged whitespace
(`git diff --cached --check`) and the format of staged Dart files that were
formatted at `HEAD`. Do not bypass it with `--no-verify`.

## 3. Before push: the full gate

In this order, as `CLAUDE.md` says:

1. `dart tool/fast_test.dart` - the whole suite, all green (see below).
2. `coderabbit review --uncommitted --include-untracked` - 10 to 20 minutes,
   start it in the background. Fix every finding.
3. Commit as chukfinley, one commit per topic.
4. `git fetch` and `git merge origin/master` if master moved, then
   `git push`.

A scoped run is never a substitute for step 1. Do not push on red.

## The full suite: `dart tool/fast_test.dart`

Plain `flutter test` compiles the app once per test file (570 times) and
starts up to 14 test processes. That cost 10 to 30 minutes and most of a
16-core CPU. `tool/fast_test.dart` imports the files into 4 bundles that
compile once each, so a full run takes a few minutes with 4 processes.

- Start it with `dart`, not `dart run`: `dart run` first runs the package's
  native build hooks and can wait minutes on another build's lock.
- A file that hangs, fails or does not load in a bundle runs again on its
  own; only that result counts. Files that need their own process are in
  `tool/fast_test_isolated.txt` (checked in) and
  `.dart_tool/fast_test_learned.txt` (learned on this machine; delete it to
  re-learn). The summary lists "only green on their own" files: they leak
  state into the next file, so fix them when you touch them.
- Only one full run per checkout goes at a time (a lock); a second run
  waits. Do not start the suite again while one is running.
- Options: `--workers 2` (less CPU and RAM), `--only test/widgets`,
  `-- --name foo` (passed to `flutter test`).
- On a PC with T3 Code, run `scripts/patch_flutter_test_connect.sh` once
  (again after `flutter upgrade`). T3 Code probes every local port with
  `GET /`; without the patch that kills random test files at load with
  `Unable to connect to flutter_tester process`. A test that starts its own
  HTTP or WebSocket server must answer a non-upgrade request with 404
  (example: `test/services/agents/agents_half_open_socket_test.dart`).
