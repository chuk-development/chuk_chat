#!/usr/bin/env bash
# Pull store screenshots off a real Android device or emulator.
#
# The generated screenshots (`flutter test test_screenshots`) are the default
# and need no hardware. Use this one when you want the real thing: the actual
# status bar, the actual font stack, real chat content.
#
# Usage:
#   ./scripts/device_screenshots.sh --demo on          # freeze the status bar
#   ./scripts/device_screenshots.sh 01_chat            # one shot, en-US
#   ./scripts/device_screenshots.sh 02_tools de-DE     # one shot, German listing
#   LOCALE=de-DE ./scripts/device_screenshots.sh 03_theme
#
# The phone must already show the screen you want. The file lands in
# fastlane/screenshots_raw/<locale>/; run scripts/frame_screenshots.sh
# afterwards to write the framed listing images.

set -euo pipefail

NAME="${1:-}"
LOCALE="${2:-${LOCALE:-en-US}}"

if [ -z "$NAME" ]; then
  echo "usage: $0 <name> [locale]" >&2
  echo "  e.g. $0 01_chat de-DE" >&2
  exit 1
fi

resolve_adb() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi
  for sdk in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Android/Sdk"; do
    [ -n "$sdk" ] || continue
    if [ -x "$sdk/platform-tools/adb" ]; then
      printf '%s\n' "$sdk/platform-tools/adb"
      return 0
    fi
  done
  return 1
}

ADB="$(resolve_adb)" || {
  echo "adb not found. Install platform-tools or set ANDROID_SDK_ROOT." >&2
  exit 1
}

DEVICES="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')"
if [ -z "$DEVICES" ]; then
  echo "No device. Connect a phone with USB debugging, or start an emulator." >&2
  exit 1
fi
if [ -n "${ANDROID_SERIAL:-}" ]; then
  if ! printf '%s\n' "$DEVICES" | grep -qxF "$ANDROID_SERIAL"; then
    echo "ANDROID_SERIAL=$ANDROID_SERIAL is not an attached device:" >&2
    echo "$DEVICES" >&2
    exit 1
  fi
elif [ "$(echo "$DEVICES" | wc -l)" -gt 1 ]; then
  echo "More than one device attached. Set ANDROID_SERIAL to pick one:" >&2
  echo "$DEVICES" >&2
  exit 1
fi

# Anchored to the repository root, so the shot lands in the supply tree no
# matter which directory the script is called from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The device is already resolved above, and adb honours ANDROID_SERIAL, so
# every broadcast below reaches exactly one phone.
# `--demo on` freezes the status bar before a capture: clock at 12:00, full
# battery, no notification icons, full wifi. Nothing about the device, the
# time or the owner leaks into a store listing. `--demo off` gives the real
# status bar back.
if [ "${1:-}" = "--demo" ]; then
  MODE="${2:-on}"
  if [ "$MODE" = "off" ]; then
    "$ADB" shell am broadcast -a com.android.systemui.demo -e command exit >/dev/null
    echo "status bar: back to normal"
  else
    "$ADB" shell settings put global sysui_demo_allowed 1
    for args in \
      "-e command enter" \
      "-e command clock -e hhmm 1200" \
      "-e command battery -e level 100 -e plugged false" \
      "-e command notifications -e visible false" \
      "-e command network -e wifi show -e level 4 -e mobile false"; do
      # shellcheck disable=SC2086
      "$ADB" shell am broadcast -a com.android.systemui.demo $args >/dev/null
    done
    echo "status bar: demo mode (12:00, full battery, no notifications)"
  fi
  exit 0
fi

# Raw captures live outside the metadata tree. scripts/frame_screenshots.sh
# turns them into the listing images, so re-framing always starts from the
# original capture.
OUT_DIR="$REPO_ROOT/fastlane/screenshots_raw/$LOCALE"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$NAME.png"

# Capture to a temporary file and move it into place only on success. A
# redirection straight onto $OUT would leave a 0-byte "PNG" in the tree that
# fastlane uploads from if screencap fails.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! "$ADB" exec-out screencap -p > "$TMP" || [ ! -s "$TMP" ]; then
  echo "screencap produced nothing. Is the screen on and unlocked?" >&2
  exit 1
fi

mv "$TMP" "$OUT"

# grep exits 1 when file(1) reports no dimensions, and pipefail would abort
# the script after the screenshot was already written.
SIZE="$(file -b "$OUT" | grep -oE '[0-9]+ x [0-9]+' | head -1 || true)"
SIZE="${SIZE:-size unknown}"
echo "Wrote $OUT ($SIZE)"
echo "Run ./scripts/frame_screenshots.sh to update the listing images."
echo
echo "Play wants 16:9 or 9:16, 320-3840 px per side. A phone screenshot at its"
echo "native resolution is fine. Odd aspect ratios (foldables, tablets in"
echo "landscape) need a crop before upload."
