#!/usr/bin/env bash
# scripts/import_chat_ui.sh
#
# Import the chuk_chat chat UI into CoWork, verbatim.
#
# Every path in tools/chat_ui_manifest.txt is copied from <chuk>/lib/<path> to
# app/lib/<path>, and the Dart package prefix is rewritten from `chuk_chat` to
# `cowork`. Nothing else is changed: the imported files stay byte-comparable to
# upstream, so a re-sync is `import_chat_ui.sh` followed by `git diff`.
#
# The script is re-runnable and idempotent. It fails (non-zero) when a manifest
# path does not exist upstream, so a file that moved in chuk_chat is reported
# instead of being silently dropped.
#
# STOP before you run this. The widget entries in the manifest are NO LONGER
# byte-identical to upstream: about two thousand lines of CoWork rendering work
# live in them (tappable links in tables, the stacked narrow table, inline code
# in headings, monotonic heading sizes, the trailing-comma parser fix, the
# tolerant chart parser, 48 dp targets). A plain re-sync overwrites all of it in
# silence. Read the "Allowed divergences" section of docs/CHAT_UI_IMPORT.md and
# prune the manifest first (bead cowork-r6jy).
#
# Usage:
#   scripts/import_chat_ui.sh [path-to-chuk_chat]
#
# The upstream checkout defaults to $CHUK_CHAT_DIR, then ~/git/chuk_chat.
#
# NOT imported (deliberate, see docs/CHAT_UI_IMPORT.md):
#   - lib/services/mcp/*          CoWork's MCP is the source of truth.
#   - lib/widgets/mcp_connect_card.dart, lib/pages/mcp_connectors_page.dart
#   - lib/services/websocket_connector_io.dart
#   - every file replaced by a CoWork stub (see docs/CHAT_UI_IMPORT.md).

set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/tools/chat_ui_manifest.txt"
DEST_ROOT="$REPO_ROOT/app/lib"
SRC_REPO="${1:-${CHUK_CHAT_DIR:-$HOME/git/chuk_chat}}"
SRC_ROOT="$SRC_REPO/lib"
EXTRAS="$REPO_ROOT/tools/platform_config_cowork_extras.dart.part"

[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
[ -d "$SRC_ROOT" ] || { echo "upstream lib not found: $SRC_ROOT" >&2; exit 1; }

pinned="$(sed -n 's/^# upstream: chuk_chat \([0-9a-f]\{7,40\}\).*/\1/p' "$MANIFEST" | head -n1)"
actual="$(git -C "$SRC_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -n "$pinned" ] && [ "$pinned" != "$actual" ]; then
  echo "note: manifest pins $pinned, upstream HEAD is $actual" >&2
  echo "      update the '# upstream:' header after reviewing the diff." >&2
fi

missing=0
copied=0

while IFS= read -r line; do
  # strip comments and blank lines
  path="${line%%#*}"
  path="$(printf '%s' "$path" | tr -d '[:space:]')"
  [ -n "$path" ] || continue
  # tolerate a leading lib/ in the manifest
  path="${path#lib/}"

  src="$SRC_ROOT/$path"
  dest="$DEST_ROOT/$path"

  if [ ! -f "$src" ]; then
    echo "MISSING upstream: lib/$path" >&2
    missing=$((missing + 1))
    continue
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  sed -i 's|package:chuk_chat/|package:cowork/|g' "$dest"
  # CoWork threads live in their own table: a session key is not a UUID and
  # the two apps share one Supabase project (bead cowork-sha).
  sed -i "s|'encrypted_chats'|'cowork_chats'|g" "$dest"
  copied=$((copied + 1))
done < "$MANIFEST"

# platform_config.dart is imported verbatim and then gets CoWork's own feature
# flags appended, so a re-sync keeps chuk's flags and never loses CoWork's.
if [ -f "$EXTRAS" ] && [ -f "$DEST_ROOT/platform_config.dart" ]; then
  if ! grep -q 'COWORK-ONLY FEATURE FLAGS' "$DEST_ROOT/platform_config.dart"; then
    cat "$EXTRAS" >> "$DEST_ROOT/platform_config.dart"
    echo "appended CoWork-only flags to platform_config.dart"
  fi
fi

echo "imported $copied file(s) into app/lib from $SRC_ROOT"

if [ "$missing" -gt 0 ]; then
  echo "FAILED: $missing manifest path(s) do not exist upstream" >&2
  exit 1
fi
