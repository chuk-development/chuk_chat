#!/usr/bin/env bash
# Smoke test against a running chuk backend: API health, version, model
# list, Supabase sign-in with a test account, and one authenticated call.
#
# The nightly workflow .github/workflows/e2e-live.yml runs it against
# production (api.chuk.chat). It also runs against the local E2E stack
# (docs/E2E_STACK.md), which is how to test the script itself.
#
# Input (environment variables, all required):
#   SMOKE_API_URL            e.g. https://api.chuk.chat
#   SMOKE_SUPABASE_URL       Supabase project URL
#   SMOKE_SUPABASE_ANON_KEY  Supabase anon (public) key
#   SMOKE_EMAIL              test account email
#   SMOKE_PASSWORD           test account password
#
# The script never prints a credential or a token. It does not use `set -x`.
# On GitHub Actions it masks the access token as soon as it has it.
# Exit code 0 = all checks passed, 1 = a check failed, 2 = bad input.
set -euo pipefail
set +x

UA="chuk-e2e-smoke/1.0"
fail=0
# RUNNER_TEMP on GitHub Actions; the repository _scratch/ on a dev machine.
base="${RUNNER_TEMP:-$(cd "$(dirname "$0")/.." && pwd)/_scratch}"
mkdir -p "$base"
work="$(mktemp -d "$base/smoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for v in SMOKE_API_URL SMOKE_SUPABASE_URL SMOKE_SUPABASE_ANON_KEY SMOKE_EMAIL SMOKE_PASSWORD; do
  if [ -z "${!v:-}" ]; then
    echo "missing input: $v" >&2
    exit 2
  fi
done
command -v jq >/dev/null || { echo "jq is not installed" >&2; exit 2; }

api="${SMOKE_API_URL%/}"
sb="${SMOKE_SUPABASE_URL%/}"

ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
warn() { printf 'warn  %s\n' "$*"; }

# GET <url> -> writes the body to $work/body, prints the HTTP code.
# Extra curl options (headers from a file) come after the URL.
get() {
  local url="$1"; shift
  curl -sS -A "$UA" --max-time 30 -o "$work/body" -w '%{http_code}' "$@" "$url" \
    || echo "000"
}

# 1. Health. The server keeps 200 while degraded; the body tells.
code="$(get "$api/health")"
if [ "$code" = "200" ] && [ "$(jq -r '.status // empty' "$work/body" 2>/dev/null)" = "ok" ]; then
  ok "GET /health (git_sha $(jq -r '.git_sha // "?"' "$work/body"))"
else
  bad "GET /health -> HTTP $code"
fi

# 2. Version.
code="$(get "$api/v1/version")"
if [ "$code" = "200" ]; then ok "GET /v1/version"; else bad "GET /v1/version -> HTTP $code"; fi

# 3. Model list: not empty.
code="$(get "$api/v1/models_info")"
# The body is a JSON array of models (api_server main.py, /v1/models_info).
count="$(jq -r 'if type == "array" then length else ((.models // .data // []) | length) end' \
  "$work/body" 2>/dev/null || echo 0)"
if [ "$code" = "200" ] && [ "${count:-0}" -gt 0 ]; then
  ok "GET /v1/models_info ($count models)"
else
  bad "GET /v1/models_info -> HTTP $code, $count models"
fi

# 4. Sign in. jq reads the credentials from the environment and curl reads
# the body from stdin, so the password is in no argv.
printf 'apikey: %s\n' "$SMOKE_SUPABASE_ANON_KEY" >"$work/anon.h"
export SMOKE_EMAIL SMOKE_PASSWORD
code="$(jq -n '{email: env.SMOKE_EMAIL, password: env.SMOKE_PASSWORD}' \
  | curl -sS -A "$UA" --max-time 30 -o "$work/token" -w '%{http_code}' \
      -X POST "$sb/auth/v1/token?grant_type=password" \
      -H @"$work/anon.h" -H 'Content-Type: application/json' --data-binary @- \
  || echo "000")"
token=""
if [ "$code" = "200" ]; then
  token="$(jq -r '.access_token // empty' "$work/token")"
fi
rm -f "$work/token"
if [ -n "$token" ]; then
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$token"
  ok "Supabase password sign-in"
else
  bad "Supabase password sign-in -> HTTP $code"
fi

# 5. One authenticated API call. 200 = full pass. 404 "no billing record"
# still proves that the API accepted the Supabase token.
if [ -n "$token" ]; then
  printf 'Authorization: Bearer %s\n' "$token" >"$work/auth.h"
  code="$(get "$api/v1/user/status" -H @"$work/auth.h")"
  case "$code" in
    200) ok "GET /v1/user/status (plan $(jq -r '.current_plan // .plan // "?"' "$work/body"))" ;;
    404) warn "GET /v1/user/status -> 404: token accepted, the account has no billing record" ;;
    *)   bad "GET /v1/user/status -> HTTP $code" ;;
  esac
  rm -f "$work/auth.h"
fi

if [ "$fail" = "0" ]; then echo "smoke: all checks passed"; else echo "smoke: FAILED"; fi
exit "$fail"
