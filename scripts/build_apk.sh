#!/usr/bin/env bash
# Build the Agents Android APK the ONLY correct way, then install it with adb.
#
# The app is broken without its compile-time environment: Supabase keys and the
# feature flags (FEATURE_AGENTS ...) all come from app/.env. A plain
# `flutter build apk` installs fine and then shows a dead screen. Always use
# this script; never hand-roll the flutter command. To change what is built,
# edit app/.env (template: app/.env.example).
#
# Usage:
#   scripts/build_apk.sh              # arm64 release build + adb install + launch
#   scripts/build_apk.sh --no-install # build only
#   scripts/build_apk.sh --emulator   # x86_64 build, installed on the local AVD
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
APP_DIR="$REPO/app"
CDPATH= cd -- "$APP_DIR"

ENV_FILE="$APP_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (SUPABASE_URL, SUPABASE_ANON_KEY)" >&2; exit 1; }

TARGET_PLATFORM=android-arm64
NO_INSTALL=
SERIAL=
for arg in "$@"; do
  case "$arg" in
    --no-install) NO_INSTALL=1 ;;
    # The phone is arm64, the local AVD is x86_64. Gradle follows this through
    # the target-platform property (app/android/app/build.gradle.kts).
    --emulator|--x64) TARGET_PLATFORM=android-x64 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

PKG=dev.chuk.cowork
OUT=build/app/outputs/flutter-apk/app-release.apk
APP_VERSION="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

DEFINES=(
  # Everything the app needs lives in app/.env — Supabase keys and the feature
  # flags (FEATURE_AGENTS and friends). Change the build there, not here.
  "--dart-define-from-file=$ENV_FILE"
  "--dart-define=APP_VERSION=$APP_VERSION"
  "--dart-define=BUILD_TIMESTAMP=$BUILD_TIMESTAMP"
)

echo "==> flutter build apk --release --target-platform $TARGET_PLATFORM"
flutter build apk --release --target-platform "$TARGET_PLATFORM" "${DEFINES[@]}"
ls -lh "$OUT"

[ -n "$NO_INSTALL" ] && exit 0

# An x86_64 build belongs on the emulator, an arm64 build on the phone. Pick the
# matching device instead of whatever adb lists first.
if [ "$TARGET_PLATFORM" = "android-x64" ]; then
  SERIAL="$(adb devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1; exit}')"
  [ -n "$SERIAL" ] || { echo "no emulator running — start it: scripts/emulator.sh start" >&2; exit 1; }
else
  SERIAL="$(adb devices | awk '$1 !~ /^emulator-/ && $2 == "device" {print $1; exit}')"
  [ -n "$SERIAL" ] || { echo "no phone attached over adb" >&2; exit 1; }
fi
echo "==> device $SERIAL"
adb() { command adb -s "$SERIAL" "$@"; }
# An older split-per-abi build leaves a higher version code on the phone (arm64
# splits get +2000), and then a normal install fails with
# INSTALL_FAILED_VERSION_DOWNGRADE. -d covers it; if the phone still refuses,
# uninstall first — that drops the app's local data, pairing included.
echo "==> adb install"
if ! adb install -r -d "$OUT"; then
  echo "==> install refused, uninstalling $PKG and retrying (app data is lost)"
  adb uninstall "$PKG" >/dev/null
  adb install -r "$OUT"
fi

adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  PID="$(adb shell pidof "$PKG" | tr -d '\r')"
  [ -n "$PID" ] && break
  sleep 1
done
[ -n "${PID:-}" ] || { echo "app did not stay up — check: adb logcat -d | grep flutter" >&2; exit 1; }
echo "installed and running: $PKG pid=$PID ($APP_VERSION, $BUILD_TIMESTAMP)"
