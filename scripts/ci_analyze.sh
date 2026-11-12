#!/usr/bin/env bash
# The exact static checks of CI's `analyze` job (.github/workflows/ci.yml).
# CI runs this file, the pre-push hook (.beads/hooks/pre-push) runs it too,
# so a push that CI would reject for an analyzer error stops here first.
#
#   scripts/ci_analyze.sh                 check the working tree (CI)
#   scripts/ci_analyze.sh --commit <rev>  check one commit, not the tree
#
# --commit exports the commit's sources to _scratch/ci_analyze/ and checks
# them there. Several agents share one checkout, so a foreign uncommitted
# file must not block (or excuse) a push; the hook passes the pushed sha.
# The export reuses this checkout's .dart_tool/package_config.json; when the
# commit changes pubspec.yaml or pubspec.lock it runs `flutter pub get`.
#
# Explicit paths: vendor/openui_core/test needs its own dev dependencies
# (package:test, very_good_analysis), which the app's package config does
# not resolve, so a bare `flutter analyze` reports thousands of
# unresolved-import errors there. Errors are fatal; infos and warnings are
# not yet (lib/models/content_block.dart has one warning).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ANALYZE_PATHS=(
  lib test tool integration_test test_driver test_screenshots
  vendor/markdraw/lib vendor/openui/lib vendor/openui_core/lib
)

if [ "${1:-}" = "--commit" ]; then
  rev="$(git rev-parse --verify "${2:?--commit needs a revision}^{commit}")"
  dir="$ROOT/_scratch/ci_analyze"
  rm -rf "$dir"
  mkdir -p "$dir/.dart_tool"
  # Everything analyze and the pin check read. Paths missing in the commit
  # are skipped, so an old commit still exports.
  paths=()
  for p in lib test tool integration_test test_driver test_screenshots \
    vendor third_party assets pubspec.yaml pubspec.lock analysis_options.yaml \
    l10n.yaml scripts .github dev.chuk.chat.yml Dockerfile.web codemagic.yaml \
    build.sh; do
    if git cat-file -e "$rev:$p" 2>/dev/null; then paths+=("$p"); fi
  done
  git archive "$rev" "${paths[@]}" | tar -x -C "$dir"
  cd "$dir"
  if [ -f "$ROOT/.dart_tool/package_config.json" ] &&
    cmp -s pubspec.lock "$ROOT/pubspec.lock" &&
    cmp -s pubspec.yaml "$ROOT/pubspec.yaml"; then
    cp "$ROOT/.dart_tool/package_config.json" .dart_tool/
    if [ -f "$ROOT/.dart_tool/package_graph.json" ]; then
      cp "$ROOT/.dart_tool/package_graph.json" .dart_tool/
    fi
  else
    flutter pub get >/dev/null
  fi
fi

./scripts/check_flutter_pins.sh
flutter analyze --no-fatal-infos --no-fatal-warnings "${ANALYZE_PATHS[@]}"
