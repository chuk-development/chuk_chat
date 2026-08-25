#!/bin/bash
# prerelease.sh - Cut a pre-release as easily as a normal release.
#
# Triggers the cross-platform workflow with prerelease=true. The workflow tags
# it v<pubspec-version>-pre.N (N auto-increments, up to 20 per base version —
# the 21st needs a pubspec version bump), marks the GitHub release as a
# pre-release, and keeps it out of the "Latest" slot.
#
# Usage:
#   ./scripts/prerelease.sh            # Android + Linux (.deb/.AppImage/.rpm)
#   ./scripts/prerelease.sh all        # also Windows + macOS
#
# A normal (stable) release is the same workflow without prerelease — see
# CLAUDE.md "Creating a Release".

set -e

WORKFLOW="build-cross-platform.yml"
REF="${PRERELEASE_REF:-master}"
SCOPE="${1:-default}"

WIN=false
MAC=false
if [ "$SCOPE" = "all" ]; then
  WIN=true
  MAC=true
fi

echo "Triggering pre-release build on ref '$REF' (scope: $SCOPE)..."
gh workflow run "$WORKFLOW" \
  --ref "$REF" \
  --field build_android=true \
  --field build_linux_x64=true \
  --field build_linux_arm64=true \
  --field build_windows="$WIN" \
  --field build_macos="$MAC" \
  --field build_ios=false \
  --field enable_signing=true \
  --field prerelease=true

echo "Triggered. Watch it:  gh run watch \$(gh run list --workflow=$WORKFLOW --limit 1 --json databaseId --jq '.[0].databaseId')"
