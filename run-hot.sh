#!/bin/bash
# Start the app under flutter-hot (hot reload) using EXACTLY the same
# dart-defines and feature flags as ./run.sh — so a hot-started dev app
# matches ./run.sh (voice OFF, no CoWork, production API, tray on, etc).
#
# NEVER start `flutter-hot start` bare: it runs `flutter run` with no
# dart-defines, so Supabase creds are missing and feature flags fall back to
# the production defaults in platform_config.dart (e.g. voice becomes visible).
#
# Usage:
#   ./run-hot.sh [device]      # default device: linux
#
# It reuses run.sh as the single source of truth for the defines via
# PRINT_DEFINES=1 (which prints the --dart-define string and exits without
# building), then feeds it to flutter-hot through FLUTTER_HOT_EXTRA.
set -e

DEVICE="${1:-linux}"

# run.sh with PRINT_DEFINES=1 prints only the assembled --dart-define string.
DEFINES="$(PRINT_DEFINES=1 ./run.sh "$DEVICE")"

# A development run must not be turned away by the installed app's
# single-instance lock (same as run.sh).
export CHUK_MULTI_INSTANCE=1
export FLUTTER_HOT_EXTRA="$DEFINES"

exec flutter-hot start "$DEVICE"
