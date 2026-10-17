# Verification policy

This policy tells agents and people when a change is done. It comes from the
Rakazo maintainer workflow (Elie Steinbock, "How I Built an Open Source Grok
Bot in a Day", 2026-10-15): "verification is key", screenshots of every
screen, emulators for every third-party service, screenshots on every pull
request. See `docs/GROWTH_LESSONS_RAKAZO.md` for the background.

## Rules

1. A UI task is done only when a screenshot shows the result. A test report
   alone is not proof. If you cannot make a screenshot, the task is not done.
   Say so in the report.
2. Every claim of "it works" has evidence: a test name, a screenshot path, or
   a log line. Do not guess. Do not pretend.
3. Tests are deterministic. A test gives the same result on every run. Do not
   use real time, real network or random data without a fixed seed.
4. Tests are offline. Tests talk to emulators, not to production. No test
   uses `api.chuk.chat`, the production Supabase project or a real account,
   except the nightly live tier (see "CI tiers").
5. A third-party service without an emulator is a gap. Write the emulator.
   Do not test against the real service to fill the gap.
6. Never put credentials in code, logs, screenshots or pull request
   comments. Never read `.env`.

## Offline test stack

| Part | Replaces | Reference |
|------|----------|-----------|
| API emulator (`tool/emulator`) | `api.chuk.chat`: models, chat stream, tools | `docs/API_EMULATOR.md` |
| Local Supabase | Auth, tables, storage, encrypted sync | `docs/E2E_STACK.md` |
| Screenshot gallery | Manual review of every screen | `docs/SCREENSHOT_GALLERY.md` |

These three parts are under construction. The documents above are the source
of truth for ports, start commands and seed data. This file only sets the
policy.

The emulator keeps state in memory. A chat that you send is in the history
on the next request. A model reply is a fixed script, not a real model. Use
the same seed data in every run.

## CI tiers

| Workflow | Trigger | Content | Secrets |
|----------|---------|---------|---------|
| `.github/workflows/ci.yml` | Every pull request and push | `flutter analyze`, `flutter test` | None |
| `.github/workflows/e2e.yml` | Every pull request and push to `master` | Offline integration test (`integration_test/app_test.dart`) against the API emulator and local Supabase; uploads the screenshots as an artifact | None |
| `.github/workflows/e2e-comment.yml` | `workflow_run` after `e2e.yml` | Puts the screenshots on the `e2e-shots` branch and writes one sticky pull request comment. Runs no pull request code | None (write token) |
| `.github/workflows/e2e-live.yml` | Nightly schedule and manual `workflow_dispatch` only | Smoke tests against production with one test account | Test account from a protected GitHub Environment |

The setup, the security model of the pull request comment and the steps
to run each tier locally are in `docs/E2E_CI.md`.

Rules for `e2e-live.yml`:

- Never trigger it on `pull_request` or `pull_request_target`. A fork must
  never get the live secrets.
- Keep the credentials in a protected GitHub Environment (for example
  `e2e-live`) with a `master`-only branch rule. Do not put them in
  repository secrets. Required reviewers are optional: with them, the
  nightly run also waits for an approval (`docs/E2E_CI.md`).
- Never echo a credential. Do not use `set -x` in steps that touch secrets.
  Mask derived values with `::add-mask::`.
- Use a dedicated test account with no private data and a small credit
  limit. Never use the owner account.
- A failure opens or updates one issue. It does not block pull requests.

Rules for `e2e.yml`:

- The pull request comment shows only the screenshots that changed against
  `master`. All screenshots of the run are a workflow artifact.
- The comment step must not run fork code with a write token. Take the
  screenshots in an unprivileged job. Post the comment from a separate job that
  only reads the artifact.
- `e2e.yml` builds the screenshots with a read-only token.
  `e2e-comment.yml` (`workflow_run`) posts the comment. It runs from the
  default branch and only reads the artifact.

## Agent verification path

An agent that changes UI does these steps, in this order:

1. `flutter analyze` and `flutter test`. Both must pass.
2. Start the offline stack (`docs/E2E_STACK.md`, `docs/API_EMULATOR.md`).
3. Run `scripts/verify_ui.sh [walk.json]`. It starts the app against the
   emulators, walks the screens of the walk file and writes screenshots to
   `_scratch/verify/`.
4. Look at each screenshot. Compare it with the task. Check mobile and
   desktop layout when the change touches both.
5. For interaction (tap, type, scroll), use the agent driver: the MCP
   server `tool/agent_driver` (`docs/AGENT_DRIVER.md`). It starts the app
   with its own data folders, and gives the tools `tap`, `enter_text`,
   `read_state` and `screenshot`. Take a screenshot after the interaction,
   not only before it.
6. Put the screenshot paths in the report. No paths, no "done".

For live work on the developer machine, `./run-hot.sh` and
`scripts/capture_app_window.sh` stay the tools (see `CLAUDE.md`). Capture the
app window only. Never capture the desktop.

## What counts as evidence

| Change | Minimum evidence |
|--------|------------------|
| Logic, service, parser | Unit test that failed before and passes after |
| UI widget or screen | Screenshot of the screen, plus a widget test when practical |
| API contract (client side) | Emulator test that sends and checks the request |
| Sync or encryption | Integration test against local Supabase: write, read back, decrypt |
| Build or CI change | A green workflow run, linked |

## Gaps

When a step is not possible (for example, no emulator for a service yet),
write the gap in the report and create a `bd` issue for it. Do not skip the
step without a note.
