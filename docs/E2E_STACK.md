# Local E2E stack

The E2E stack replaces the production backend for integration tests. It runs
offline on a developer machine and on GitHub Actions `ubuntu-latest`.

- **Supabase** (auth + Postgres + REST + realtime + storage) runs in Docker
  through the `supabase` CLI. It is the "emulator" for sign-in and the DB.
- **API emulator** (`tool/emulator/bin/chuk_emulator.dart`) replaces
  `api.chuk.chat`. The script starts it when the file exists.

Nothing in this stack talks to the production project. Every command uses
`--local`. Never run `supabase db push` or `supabase link` for this.

## Commands

```bash
scripts/e2e_stack.sh up      # start Supabase, build the DB, seed, start the API emulator
scripts/e2e_stack.sh env     # write _scratch/e2e.defines.json and print its path
scripts/e2e_stack.sh reset   # rebuild the DB and the test user (stack must be up)
scripts/e2e_stack.sh down    # stop the API emulator and Supabase (no backup)
```

`up` also prints the path of the defines file. A cold `up` takes about 40 s
when the Docker images are cached. The first run pulls the images.

Use the defines file with Flutter. The app needs its own XDG folders, or
it uses the data of the installed app (the test fails without them):

```bash
H="$PWD/_scratch/it_home"; rm -rf "$H"; mkdir -p "$H/data" "$H/cache" "$H/state"
CHUK_MULTI_INSTANCE=1 XDG_DATA_HOME="$H/data" XDG_CACHE_HOME="$H/cache" \
XDG_STATE_HOME="$H/state" xvfb-run -a -s "-screen 0 1440x900x24" \
  flutter test integration_test/app_test.dart -d linux \
  --dart-define-from-file="$(scripts/e2e_stack.sh env)"
```

## Test user

| Field    | Value                                  |
|----------|----------------------------------------|
| Email    | `e2e@example.test`                     |
| Password | `E2eTest-Passw0rd`                     |
| User id  | `00000000-0000-4000-8000-0000000000e2` |

The seed (`supabase/seed.sql`) creates the user in `auth.users` and
`auth.identities`, a `profiles` row, and a `customization_preferences` row
with `onboarding_completed = true`. The `profiles` insert fires
`trigger_set_default_model`, which writes the default `user_preferences` and
`user_model_providers` rows.

The seed does not create key material. On the first sign-in the app writes
the encryption salt and key version into the user metadata itself.

The script checks the sign-in after each build with a password grant on
`/auth/v1/token`. A failed sign-in stops the script.

## Defines file

`_scratch/e2e.defines.json` holds:

- `SUPABASE_URL`, `SUPABASE_ANON_KEY`: the local stack (from
  `supabase status -o env`). These are the public local demo keys.
- `API_BASE_URL`: `http://127.0.0.1:8787` (the API emulator).
- `E2E_EMAIL`, `E2E_PASSWORD`: the test user.
- The feature flags of `./run.sh` on desktop. One change: `FEATURE_SYSTEM_TRAY`
  is `false`, so a closed window quits the app.

## Settings

| Variable               | Default                       | Effect                                    |
|------------------------|-------------------------------|-------------------------------------------|
| `E2E_EMULATOR_PORT`    | `8787`                        | Port of the API emulator and `API_BASE_URL` |
| `E2E_SUPABASE_EXCLUDE` | studio, imgproxy, logflare, … | Containers not to start. `""` starts all  |

If the emulator port is in use, `up` stops with an error. It does not kill
the other process.

## How the DB is built

`supabase db reset` alone does **not** work. The first file in
`supabase/migrations/` (`20260120210545_fix_project_chats_policy.sql`) changes
`project_chats`, but no file in `supabase/migrations/` creates it. The base
tables were made by hand in the Supabase dashboard, and no baseline dump of
production is in the repository. The result:

```
Applying migration 20260120210545_fix_project_chats_policy.sql...
ERROR: relation "project_chats" does not exist (SQLSTATE 42P01)
```

`scripts/e2e_stack.sh` builds the DB in four steps instead:

1. Start (or reset) Supabase with migrations and seed off
   (`SUPABASE_DB_MIGRATIONS_ENABLED=false SUPABASE_DB_SEED_ENABLED=false`).
2. Create three "shim" tables that production has but no SQL file creates:
   `user_model_providers`, `subscriptions`, `usage_logs`. The columns come
   from the app code and the migrations.
3. Run the old dashboard scripts in `migrations/` (repository root) in the
   order they were added to git. Two of them fail on drift and the script
   logs this, but does not stop:
   - `fix_security_linter_errors.sql`: view `user_credit_summary` does not
     exist.
   - `settings_sync_columns.sql`: column `theme_settings.show_reasoning_tokens`
     does not exist.
4. Run `supabase migration up --local` (strict: any error stops the script),
   then load `supabase/seed.sql`.

All 31 files in `supabase/migrations/` apply cleanly on top of this baseline.

### Risk: drift from production

The local schema is a reconstruction. It is not a copy of production.
Tables, columns, defaults, policies or functions can differ. A test that
passes locally can fail against production. The correct fix is a schema-only
dump of production (`supabase db dump --schema public`, run by the owner) as
the first migration. After that, remove steps 2 and 3, and plain
`supabase db reset` works.

## GitHub Actions

`ubuntu-latest` has Docker. Install the CLI, then call the script.
`.github/workflows/e2e.yml` does this; see `docs/E2E_CI.md`.

```yaml
- uses: supabase/setup-cli@v3
  with:
    version: 2.72.8
- run: scripts/e2e_stack.sh up
- run: |
    H="$RUNNER_TEMP/it_home"; mkdir -p "$H/data" "$H/cache" "$H/state"
    CHUK_MULTI_INSTANCE=1 XDG_DATA_HOME="$H/data" XDG_CACHE_HOME="$H/cache" \
    XDG_STATE_HOME="$H/state" xvfb-run -a \
      flutter test integration_test/app_test.dart -d linux \
      --dart-define-from-file=_scratch/e2e.defines.json
- if: always()
  run: scripts/e2e_stack.sh down
```

The script uses `psql` inside the DB container (`docker exec`), so the runner
needs no Postgres client.

## Known problems

- `supabase db reset` sometimes fails in the realtime schema step with
  `error running container: exit 1`. The script tries a second time.
- Two worktrees share one stack: the container names come from
  `project_id` in `supabase/config.toml` and the ports are fixed. Run one
  stack at a time.
