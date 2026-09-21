#!/usr/bin/env bash
# Every build path must pin the same Flutter version.
#
# On 2026-09-13 the dependency upgrade raised the Dart floor to 3.12. CI moved
# to Flutter 3.47.0, but Dockerfile.web still cloned 3.38.8 and the Flatpak
# manifest fetched 3.38.7, so `flutter pub get` failed inside the web image.
# Dokploy kept the old container alive and chat.chuk.chat served a three week
# old app without a single visible error. This check fails that class early.
set -euo pipefail
cd "$(dirname "$0")/.."

expected="$(grep -oP "FLUTTER_VERSION: '\K[0-9.]+" .github/workflows/release-windows.yml | head -1)"
[ -n "$expected" ] || { echo "cannot read the reference version"; exit 1; }

fail=0
check() { # file, found version
  if [ "$2" != "$expected" ]; then
    echo "MISMATCH $1 pins $2, expected $expected"
    fail=1
  else
    echo "ok       $1 pins $2"
  fi
}

check Dockerfile.web \
  "$(grep -oP '^ENV FLUTTER_VERSION=\K[0-9.]+' Dockerfile.web)"
check dev.chuk.chat.yml \
  "$(grep -oP 'flutter_linux_\K[0-9.]+(?=-stable)' dev.chuk.chat.yml)"
check .github/workflows/release-macos.yml \
  "$(grep -oP "FLUTTER_VERSION: '\K[0-9.]+" .github/workflows/release-macos.yml | head -1)"
cross="$(grep -oP 'flutter\.git -b \K[0-9.]+' .github/workflows/build-cross-platform.yml | sort -u)"
if [ -z "$cross" ]; then
  # No match means the pin moved or changed shape, which is exactly the drift
  # this script exists to catch — an empty loop would pass silently.
  echo "MISSING .github/workflows/build-cross-platform.yml has no Flutter pin"
  fail=1
fi
for v in $cross; do
  check .github/workflows/build-cross-platform.yml "$v"
done

exit "$fail"
