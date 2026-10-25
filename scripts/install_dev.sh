#!/usr/bin/env bash
# Build the Linux app from the current working tree and install it as
# "Chuk Chat (Dev)": a release bundle in ~/.local/opt/chuk-chat-dev plus a
# desktop entry. Stops a running copy first and starts the new one after.
#
#   scripts/install_dev.sh            # build + install + start
#   scripts/install_dev.sh --no-build # install the last build only
#   scripts/install_dev.sh --no-start
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="$HOME/.local/opt/chuk-chat-dev"
ENTRY="$HOME/.local/share/applications/chuk-chat-dev.desktop"
BUNDLE="build/linux/x64/release/bundle"

build=1
start=1
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    --no-start) start=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ $build == 1 ]]; then
  # run.sh prints the same defines it would run with (Supabase from .env,
  # feature flags), so the installed app matches ./run.sh linux.
  # shellcheck disable=SC2046
  flutter build linux --release $(PRINT_DEFINES=1 ./run.sh linux)
fi
[[ -x "$BUNDLE/chuk_chat" ]] || { echo "no build at $BUNDLE" >&2; exit 1; }

pkill -f "^$DEST/chuk_chat" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f "^$DEST/chuk_chat" >/dev/null || break
  sleep 0.5
done

mkdir -p "$DEST"
rsync -a --delete "$BUNDLE/" "$DEST/"

rev="$(git rev-parse --short HEAD)"
dirty=""
git diff --quiet HEAD || dirty=" + lokale Änderungen"
mkdir -p "$(dirname "$ENTRY")"
cat > "$ENTRY" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Chuk Chat (Dev)
Comment=Build aus dem aktuellen Code ($rev$dirty)
Exec=env GDK_BACKEND=x11 $DEST/chuk_chat
Icon=chuk-chat
Terminal=false
Categories=Network;Chat;
DESKTOP
update-desktop-database "$(dirname "$ENTRY")" 2>/dev/null || true
echo "installed $rev$dirty to $DEST"

if [[ $start == 1 ]]; then
  # A window that must outlive this shell: start it outside claude.slice.
  if command -v user-app >/dev/null; then
    user-app env GDK_BACKEND=x11 "$DEST/chuk_chat"
  else
    (GDK_BACKEND=x11 setsid "$DEST/chuk_chat" >/dev/null 2>&1 </dev/null &)
  fi
  echo "started"
fi
