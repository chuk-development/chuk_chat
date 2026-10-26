#!/usr/bin/env bash
# Local E2E stack: Supabase (auth + DB) in Docker, plus the optional API
# emulator. See docs/E2E_STACK.md.
#
#   scripts/e2e_stack.sh up     start Supabase, rebuild the DB, seed the test user
#   scripts/e2e_stack.sh reset  rebuild the DB only (stack must be up)
#   scripts/e2e_stack.sh env    write _scratch/e2e.defines.json, print its path
#   scripts/e2e_stack.sh down   stop the API emulator and Supabase
#
# Works locally and on GitHub Actions ubuntu-latest (Docker + supabase CLI).
# Never talks to the production project: everything uses --local.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRATCH="$ROOT/_scratch"
DEFINES_FILE="$SCRATCH/e2e.defines.json"
EMU_PID_FILE="$SCRATCH/e2e_emulator.pid"
# The port that `up` started the emulator on. Later calls (`env`, `status`)
# read it back, so they do not need E2E_EMULATOR_PORT again.
EMU_PORT_FILE="$SCRATCH/e2e_emulator.port"
EMU_LOG_FILE="$SCRATCH/e2e_emulator.log"
EMU_ENTRY="tool/emulator/bin/chuk_emulator.dart"
EMU_PORT="${E2E_EMULATOR_PORT:-$(cat "$EMU_PORT_FILE" 2>/dev/null || echo 8787)}"
PROJECT_ID="$(sed -n 's/^project_id *= *"\(.*\)"/\1/p' supabase/config.toml)"
DB_CONTAINER="supabase_db_${PROJECT_ID}"

# Containers the tests do not need. Fewer images = faster CI start.
# Override with E2E_SUPABASE_EXCLUDE="" to start everything (e.g. Studio).
E2E_SUPABASE_EXCLUDE="${E2E_SUPABASE_EXCLUDE-studio,postgres-meta,imgproxy,edge-runtime,logflare,vector,supavisor,mailpit}"

# Test user. Must match supabase/seed.sql.
E2E_EMAIL="e2e@example.test"
E2E_PASSWORD="E2eTest-Passw0rd"

# Legacy dashboard scripts in migrations/ that create the base tables.
# supabase/migrations/ starts with ALTERs on tables it never creates, so the
# base schema must exist first. Order = order the files were added to git.
# Files that also exist in supabase/migrations/ are left out here.
LEGACY_BASELINE=(
  00_base_schema projects free_messages image_gen_settings
  project_files_storage project_files_markdown images_storage
  fix_credits_functions fix_security_linter_errors
  user_preferences_identity_sync user_tool_preferences artifacts
  settings_sync_columns add_ui_locale assistants workspaces_rename
  agents_chat_pins
)

# Tables that production has but no SQL file in this repo creates. Columns
# come from what the app and the migrations read and write. Drop this block
# once a real baseline dump of production is the first migration.
SHIM_SQL=$(cat <<'SQL'
CREATE TABLE IF NOT EXISTS public.user_model_providers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  model_id text NOT NULL,
  provider_slug text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, model_id)
);
ALTER TABLE public.user_model_providers ENABLE ROW LEVEL SECURITY;
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
CREATE TABLE IF NOT EXISTS public.usage_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.usage_logs ENABLE ROW LEVEL SECURITY;
-- Created by the api_server repo, not this one; read-only for the user.
CREATE TABLE IF NOT EXISTS public.user_billing (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  total_credits_allocated numeric(10,4) DEFAULT 0,
  credits_last_renewed_period text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE public.user_billing ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "user_billing_select_own" ON public.user_billing;
CREATE POLICY "user_billing_select_own" ON public.user_billing
  FOR SELECT USING (auth.uid() = user_id);
SQL
)

log() { printf '[e2e] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed"; }

# psql inside the DB container, so the host needs no postgres client.
psql_db() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q "$@"
}

status_env() {
  supabase status -o env 2>/dev/null | grep -E '^[A-Z_]+=' | sed 's/^\([A-Z_]*\)="\(.*\)"$/\1=\2/'
}

env_value() { status_env | sed -n "s/^$1=//p" | head -n 1; }

# An empty DB: the stack with migrations and seed switched off.
start_empty() {
  if supabase status >/dev/null 2>&1; then
    log "Supabase is running; resetting to an empty database"
    # The realtime schema init inside `db reset` fails now and then
    # ("error running container: exit 1"); a second try passes.
    SUPABASE_DB_MIGRATIONS_ENABLED=false SUPABASE_DB_SEED_ENABLED=false \
      supabase db reset --local >&2 \
      || { log "db reset failed; retrying once"
           SUPABASE_DB_MIGRATIONS_ENABLED=false SUPABASE_DB_SEED_ENABLED=false \
             supabase db reset --local >&2; }
  else
    log "Starting Supabase (first run pulls the Docker images)"
    local exclude=()
    [ -n "$E2E_SUPABASE_EXCLUDE" ] && exclude=(-x "$E2E_SUPABASE_EXCLUDE")
    SUPABASE_DB_MIGRATIONS_ENABLED=false SUPABASE_DB_SEED_ENABLED=false \
      supabase start "${exclude[@]}" >&2
  fi
}

build_db() {
  log "Applying shim tables"
  printf '%s\n' "$SHIM_SQL" | psql_db -v ON_ERROR_STOP=1 >/dev/null

  # Legacy scripts were run by hand against production and have drifted
  # (e.g. ALTER VIEW on views that were later dropped). Errors are logged,
  # not fatal. The strict check is the next step.
  local f errs
  for f in "${LEGACY_BASELINE[@]}"; do
    errs="$(psql_db -v ON_ERROR_STOP=0 < "migrations/$f.sql" 2>&1 \
      | grep -E '^(psql:.*)?ERROR' || true)"
    if [ -n "$errs" ]; then
      log "legacy $f.sql (not fatal): $(printf '%s' "$errs" | head -n 1)"
    fi
  done

  log "Applying supabase/migrations (strict)"
  supabase migration up --local >&2

  log "Seeding the test user"
  psql_db -v ON_ERROR_STOP=1 < supabase/seed.sql >/dev/null
}

check_sign_in() {
  local url key code
  url="$(env_value API_URL)"
  key="$(env_value ANON_KEY)"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$url/auth/v1/token?grant_type=password" \
    -H "apikey: $key" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$E2E_EMAIL\",\"password\":\"$E2E_PASSWORD\"}")"
  [ "$code" = "200" ] || die "test user sign-in failed (HTTP $code)"
  log "Test user sign-in OK ($E2E_EMAIL)"
}

start_emulator() {
  if [ ! -f "$EMU_ENTRY" ]; then
    log "No $EMU_ENTRY; API emulator not started"
    return 0
  fi
  if [ -f "$EMU_PID_FILE" ] && kill -0 "$(cat "$EMU_PID_FILE")" 2>/dev/null; then
    log "API emulator already running (pid $(cat "$EMU_PID_FILE"))"
    # A run from before the port file existed: record an explicit port.
    if [ -n "${E2E_EMULATOR_PORT:-}" ]; then echo "$EMU_PORT" >"$EMU_PORT_FILE"; fi
    return 0
  fi
  if port_open "$EMU_PORT"; then
    die "port $EMU_PORT is in use by another process; set E2E_EMULATOR_PORT"
  fi
  need dart
  log "Starting API emulator on 127.0.0.1:$EMU_PORT (log: $EMU_LOG_FILE)"
  nohup dart run "$EMU_ENTRY" --port "$EMU_PORT" >"$EMU_LOG_FILE" 2>&1 &
  echo $! >"$EMU_PID_FILE"
  echo "$EMU_PORT" >"$EMU_PORT_FILE"
  for _ in $(seq 1 120); do
    port_open "$EMU_PORT" && { log "API emulator is up"; return 0; }
    kill -0 "$(cat "$EMU_PID_FILE")" 2>/dev/null || break
    sleep 1
  done
  tail -n 20 "$EMU_LOG_FILE" >&2 || true
  die "API emulator did not start"
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

stop_emulator() {
  [ -f "$EMU_PID_FILE" ] || return 0
  local pid
  pid="$(cat "$EMU_PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    log "Stopping API emulator (pid $pid)"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$EMU_PID_FILE" "$EMU_PORT_FILE"
}

write_defines() {
  local url key
  url="$(env_value API_URL)"
  key="$(env_value ANON_KEY)"
  [ -n "$url" ] && [ -n "$key" ] || die "Supabase is not running; run 'up' first"
  # run.sh desktop defaults (PRINT_DEFINES=1 ./run.sh), except the tray: off,
  # so closing the window quits the app as a test expects.
  cat >"$DEFINES_FILE" <<JSON
{
  "SUPABASE_URL": "$url",
  "SUPABASE_ANON_KEY": "$key",
  "API_BASE_URL": "http://127.0.0.1:$EMU_PORT",
  "E2E_EMAIL": "$E2E_EMAIL",
  "E2E_PASSWORD": "$E2E_PASSWORD",
  "FEATURE_VOICE_MODE": "false",
  "FEATURE_WORKSPACES": "false",
  "FEATURE_ARTIFACTS": "true",
  "FEATURE_SERVER_TOOLS": "true",
  "FEATURE_SKILLS": "true",
  "FEATURE_SYSTEM_TRAY": "false",
  "FEATURE_PAYMENTS_DIRECT": "true",
  "FEATURE_LINUX_KEYRING": "false",
  "FEATURE_AGENTS": "false",
  "FEATURE_VOICE_CALL": "false"
}
JSON
  printf '%s\n' "$DEFINES_FILE"
}

cmd="${1:-}"
case "$cmd" in
  up)
    need docker; need supabase; need curl
    mkdir -p "$SCRATCH"
    start_empty
    build_db
    check_sign_in
    start_emulator
    write_defines
    ;;
  reset)
    need docker; need supabase; need curl
    start_empty
    build_db
    check_sign_in
    ;;
  env)
    need supabase
    mkdir -p "$SCRATCH"
    write_defines
    ;;
  down)
    stop_emulator
    if command -v supabase >/dev/null 2>&1; then
      supabase stop --no-backup >&2 || true
    fi
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
