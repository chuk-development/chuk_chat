# E2E workflows on GitHub Actions

This document describes the two E2E tiers in CI. The policy is in
`docs/VERIFICATION.md` ("CI tiers"). The local stack is in
`docs/E2E_STACK.md`. The test itself is in `docs/INTEGRATION_TESTS.md`.

| Workflow | Trigger | Token | Secrets |
|----------|---------|-------|---------|
| `.github/workflows/e2e.yml` | Every pull request, every push to `master` | Read only | None |
| `.github/workflows/e2e-comment.yml` | `workflow_run` after "E2E" completes | Write (contents, pull requests) | None |
| `.github/workflows/e2e-live.yml` | Manual (`workflow_dispatch`), nightly at 03:23 UTC | Read only (issues: write in the report job) | GitHub Environment `e2e-live` |

Beads: `chuk_chat-xmp0` (e2e + comment), `chuk_chat-cnws` (e2e-live).

## 1. Offline tier: `e2e.yml`

The job `integration` does these steps on `ubuntu-latest`:

1. Install the Linux build packages and Xvfb.
2. Install Flutter 3.47.0. `scripts/check_flutter_pins.sh` checks this pin
   together with the other build paths.
3. Install the Supabase CLI 2.72.8 (`supabase/setup-cli`).
4. `scripts/e2e_stack.sh up`. This starts Supabase in Docker, builds the DB,
   seeds the test user, starts the API emulator on port 8787 and writes
   `_scratch/e2e.defines.json`. The workflow does not need a committed
   defines file. The script makes it.
5. Run `integration_test/app_test.dart` under `xvfb-run`, with an empty XDG
   data directory in `$RUNNER_TEMP`. This is the same command as in
   `docs/INTEGRATION_TESTS.md`.
6. Write `run.json` (event, pull request number, head commit) next to the
   screenshots. This file is for people only. No workflow trusts it.
7. Upload `build/integration_shots/` as the artifact `e2e-shots` (14 days).
   On failure, upload `_scratch/*.log` as `e2e-logs` (stack and emulator
   logs).

The stack uses only the public local demo keys of Supabase and the seeded
test user. The workflow needs no secrets. A pull request from a fork runs
it with the same read-only token.

The runner is discarded after the job. The workflow does not run
`e2e_stack.sh down`.

## 2. Pull request comment: `e2e-comment.yml`

### Why a second workflow

A pull request from a fork can change any file, also the workflow and the
test. Code from such a pull request must never run with a write token.
GitHub gives a `pull_request` run from a fork only a read-only token, so
`e2e.yml` cannot write a comment for forks.

There are two safe options:

- Skip the comment for forks.
- Post the comment from a `workflow_run` workflow.

We use `workflow_run`. Contributors from forks also get the screenshots,
and the security rule stays true:

- GitHub runs `e2e-comment.yml` from the default branch. A pull request
  cannot change the version that runs.
- The job checks out only `.github/scripts` from the default branch. It
  never checks out or runs code from the pull request.
- The artifact is data. `.github/scripts/e2e_shots_comment.cjs` uses only
  files with a name like `NN_name.png` (lowercase), a size of 5 MB or less, a
  real PNG signature and no symbolic link. It uses 50 files at most. It
  ignores all other files.
- The script finds the pull request from the `workflow_run` event
  (`pull_requests`, or for forks the head owner and branch). The head commit
  of the pull request must be the head commit of the run. The script never
  reads the pull request number from the artifact.

Do not change `e2e-comment.yml` to `pull_request_target`, and do not add a
step that runs a file from the artifact or from the pull request.

### Where the images are

A comment can only show an image from a URL. An artifact has no public URL
for each file. The script therefore stores the images on the branch
`e2e-shots`:

| Path | Content |
|------|---------|
| `master/<file>.png` | Baseline: the screenshots of the last green run on `master` |
| `pr/<number>/<run id>/<file>.png` | The last run of each open pull request |

- The branch has one commit only. Each run makes a new orphan commit with
  the full tree and pushes it with `--force-with-lease`. When two runs push
  at the same time, the lease stops the second push, and that run starts
  again from the new head (5 attempts). The branch does not grow a history.
- Each run removes the folders of pull requests that are closed.
- A red or empty run on `master` does not change the baseline.
- The comment loads the images from
  `raw.githubusercontent.com/<repo>/e2e-shots/...`. The run id in the path
  prevents old cached images. The repository is public, so these URLs work.
- Do not protect the branch `e2e-shots`, and do not merge it.

### The comment

Each pull request has one comment. The first line is the marker
`<!-- e2e-screenshots -->`. The next run updates this comment. It does not
add a new one.

The comment shows:

- The run result (passed, or failed in bold) and a link to the run.
- The screenshots that changed or are new against the `master` baseline.
- The names of baseline screenshots that the run did not make.
- The unchanged screenshots, in a closed `<details>` block.
- When there is no baseline yet: all screenshots.

"Changed" means that the PNG bytes are different (SHA-256). Two runs with
no code change give the same bytes for all screenshots (see "Byte-stable
screenshots" in `docs/INTEGRATION_TESTS.md`). A changed screenshot is a real
change on the screen.

## 3. Live tier: `e2e-live.yml`

The job `smoke` runs `scripts/e2e_live_smoke.sh` against production:

1. `GET /health` returns 200 and `status: ok`.
2. `GET /v1/version` returns 200.
3. `GET /v1/models_info` returns a list that is not empty.
4. Supabase password sign-in with the test account returns a token.
5. `GET /v1/user/status` with this token returns 200. A 404 ("no billing
   record") gives a warning only, because it shows that the API accepted
   the token.

The smoke test sends no chat message, so it uses no model credits.

### Rules

- The workflow has only `workflow_dispatch` and `schedule`. Never add
  `pull_request` or `pull_request_target`.
- The job runs only in `chuk-development/chuk_chat`, not in forks.
- The job uses the GitHub Environment `e2e-live`.
- The script never prints a credential or a token. It sends the password
  through stdin and the token through a header file. It masks the token
  with `::add-mask::`. Do not add `set -x` or `curl -v`.
- A failed nightly run opens the issue "E2E live smoke test fails", or adds
  a comment to it when it is open. A manual run does not open an issue.
  The live tier does not block pull requests.

### Missing secrets

When a secret is missing, the job does not fail. It writes a notice and a
step summary with the names of the missing secrets (never the values), and
skips the smoke test. The run is green.

### Set up the secrets (owner, one time)

1. Make a new chuk account for tests only. Do not use the owner account. Put
   no private data in it. Keep its credit limit small.
2. GitHub: Settings, Environments, New environment, name `e2e-live`.
3. In the environment, set "Deployment branches" to `master` only. Add
   required reviewers if a manual approval for each run is necessary. Note:
   with required reviewers, the nightly run also waits for an approval.
4. Add the environment secrets `E2E_TEST_EMAIL` and `E2E_TEST_PASSWORD`.
5. `SUPABASE_URL` and `SUPABASE_ANON_KEY` are repository secrets that the
   release builds use already. The job reads them too. If they are not
   there, add them to the environment.
6. Start the workflow one time by hand (Actions, "E2E live", Run workflow)
   and read the step summary.

## Run the steps locally

Use a running local stack. Do not run `e2e_stack.sh down` when another
agent uses the stack.

```bash
# Workflow lint (actionlint with shellcheck)
actionlint .github/workflows/e2e.yml .github/workflows/e2e-comment.yml \
  .github/workflows/e2e-live.yml

# The integration test, as in e2e.yml
H="$PWD/_scratch/it_home"; rm -rf "$H"; mkdir -p "$H/data" "$H/cache" "$H/state"
CHUK_MULTI_INSTANCE=1 XDG_DATA_HOME="$H/data" XDG_CACHE_HOME="$H/cache" \
XDG_STATE_HOME="$H/state" xvfb-run -a -s "-screen 0 1440x900x24" \
  flutter test integration_test/app_test.dart -d linux \
  --dart-define-from-file=_scratch/e2e.defines.json

# The smoke script against the local stack (port from the defines file)
SMOKE_API_URL="$(jq -r .API_BASE_URL _scratch/e2e.defines.json)" \
SMOKE_SUPABASE_URL="$(jq -r .SUPABASE_URL _scratch/e2e.defines.json)" \
SMOKE_SUPABASE_ANON_KEY="$(jq -r .SUPABASE_ANON_KEY _scratch/e2e.defines.json)" \
SMOKE_EMAIL=e2e@example.test SMOKE_PASSWORD=E2eTest-Passw0rd \
  scripts/e2e_live_smoke.sh
```

`e2e_shots_comment.cjs` reads `E2E_SHOTS_REMOTE`. Set it to a local bare
git repository to test the branch logic without GitHub.
