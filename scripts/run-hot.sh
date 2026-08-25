#!/bin/bash
# run-hot.sh — start the app under flutter-hot (FIFO-driven hot reload) with the
# SAME dart-defines as ./run.sh, so a dev run always targets the production API
# (https://api.chuk.chat) and real Supabase credentials, with the dev feature
# flags on.
#
# Why this exists: `flutter-hot start` runs a bare `flutter run` with no
# --dart-define, which lands the app on the local dev API (localhost:8000) with
# no Supabase config. This wrapper asks run.sh for the exact define string
# (PRINT_DEFINES=1, single source of truth — no drift) and hands it to
# flutter-hot via FLUTTER_HOT_EXTRA.
#
# Usage:
#   ./scripts/run-hot.sh [device]     # default device: linux
#   ./scripts/run-hot.sh linux
#
# After it launches, use `flutter-hot wait` / `reload` / `restart` / `shot` as
# usual.

set -e

cd "$(dirname "$0")/.."

DEVICE="${1:-linux}"

# Reuse run.sh's define assembly verbatim.
DEFINES="$(PRINT_DEFINES=1 ./run.sh "$DEVICE")"

if [ -z "$DEFINES" ]; then
  echo "run-hot.sh: run.sh produced no dart-defines — check .env." >&2
  exit 1
fi

# A dev run must not be turned away by the installed app's single-instance lock.
export CHUK_MULTI_INSTANCE=1
export FLUTTER_HOT_EXTRA="$DEFINES"

exec flutter-hot start "$DEVICE"
