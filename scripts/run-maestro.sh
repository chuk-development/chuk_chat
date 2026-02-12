#!/usr/bin/env bash
# run-maestro.sh — Run Maestro E2E smoke tests for chuk_chat
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FLOWS_DIR="$PROJECT_DIR/.maestro/flows"
ENV_FILE="$PROJECT_DIR/.env.maestro"

# --- Checks ---
if ! command -v maestro &>/dev/null; then
  echo "ERROR: maestro CLI not found. Install with:"
  echo "  curl -fsSL https://get.maestro.mobile.dev | bash"
  exit 1
fi

if ! command -v adb &>/dev/null; then
  echo "ERROR: adb not found. Install Android SDK platform-tools."
  exit 1
fi

if [ "$(adb devices | grep -c 'device$')" -eq 0 ]; then
  echo "ERROR: No Android device/emulator connected."
  echo "  Connect a device or start an emulator first."
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found."
  echo "  Copy .env.maestro.example to .env.maestro and fill in test credentials."
  exit 1
fi

# --- Load env ---
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

if [ -z "${TEST_EMAIL:-}" ] || [ -z "${TEST_PASSWORD:-}" ]; then
  echo "ERROR: TEST_EMAIL and TEST_PASSWORD must be set in $ENV_FILE"
  exit 1
fi

# --- Run ---
SUITE="${1:-all}"

run_flow() {
  local flow="$1"
  echo "=== Running: $flow ==="
  maestro test -e TEST_EMAIL="$TEST_EMAIL" -e TEST_PASSWORD="$TEST_PASSWORD" "$FLOWS_DIR/$flow"
}

case "$SUITE" in
  login)
    run_flow login.yaml
    ;;
  send)
    run_flow smoke_send_message.yaml
    ;;
  switch)
    run_flow smoke_switch_chat.yaml
    ;;
  model)
    run_flow smoke_model_select.yaml
    ;;
  smoke)
    run_flow smoke_send_message.yaml
    run_flow smoke_switch_chat.yaml
    run_flow smoke_model_select.yaml
    ;;
  all)
    run_flow smoke_send_message.yaml
    run_flow smoke_switch_chat.yaml
    run_flow smoke_model_select.yaml
    ;;
  *)
    echo "Usage: $0 [all|smoke|login|send|switch|model]"
    exit 1
    ;;
esac

echo ""
echo "All requested flows passed."
