#!/usr/bin/env bash
# The exact static checks of CI's `analyze` job (.github/workflows/ci.yml).
# CI runs this file, the pre-push hook (.beads/hooks/pre-push) runs it too,
# so a push that CI would reject for an analyzer error stops here first.
#
# Explicit paths: vendor/openui_core/test needs its own dev dependencies
# (package:test, very_good_analysis), which the app's package config does
# not resolve, so a bare `flutter analyze` reports thousands of
# unresolved-import errors there. Errors are fatal; infos and warnings are
# not yet (lib/models/content_block.dart has one warning).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

./scripts/check_flutter_pins.sh
flutter analyze --no-fatal-infos --no-fatal-warnings \
  lib test tool integration_test test_driver test_screenshots \
  vendor/markdraw/lib vendor/openui/lib vendor/openui_core/lib
