#!/usr/bin/env bash
# Build the Chuk Chat .deb from a Flutter Linux release bundle.
#
#   make_deb.sh --bundle DIR --arch amd64|arm64 --version PKGVER --out FILE
#               [--variant slim|full] [--icon PNG] [--depends "a, b"]
#
# PKGVER is the package version (1.0.114, or 1.0.115~pre.2 for a
# pre-release, see pkg_version_from_tag in common.sh).
#
# The slim package is the one in the apt repository. It ships the repo
# keyring and, on install, adds the apt source (like Chrome and VS Code).
# The full package (CEF bundled) is called chuk-chat-full. It is not in
# the repository, so it does not add the source. It replaces chuk-chat,
# so apt never "upgrades" a full install back to slim.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BUNDLE="" ARCH="" VERSION="" OUT="" VARIANT="slim" ICON="" DEPENDS=""
DEPENDS_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --depends) DEPENDS="$2"; DEPENDS_SET=1; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$BUNDLE" ] && [ -n "$ARCH" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || {
  echo "usage: $0 --bundle DIR --arch amd64|arm64 --version PKGVER --out FILE [--variant slim|full]" >&2
  exit 2
}
case "$ARCH" in amd64|arm64) ;; *) echo "bad --arch $ARCH" >&2; exit 2 ;; esac
printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(~pre\.[0-9]+)?$' \
  || { echo "bad --version $VERSION" >&2; exit 2; }

BASE_DEPS="libgtk-3-0, libblkid1, liblzma5, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good"
case "$VARIANT" in
  slim)
    PKG=chuk-chat
    DESC_SHORT="Privacy-focused AI chat with end-to-end encryption"
    DESC_LONG=" Chuk Chat is a cross-platform chat application that uses
 open-weight AI models with AES-256-GCM end-to-end encryption.
 .
 This package adds the Chuk Chat apt repository, so that
 \"apt upgrade\" installs new versions."
    APP_NAME="Chuk Chat"
    [ "$DEPENDS_SET" = 1 ] || DEPENDS="$BASE_DEPS"
    ;;
  full)
    PKG=chuk-chat-full
    DESC_SHORT="Privacy-focused AI chat with end-to-end encryption (full)"
    DESC_LONG=" Bundles a Chromium Embedded Framework (CEF) runtime for real
 HTML and Excalidraw artifact rendering on Linux. If you prefer
 a smaller install, use the chuk-chat package instead."
    APP_NAME="Chuk Chat (full)"
    [ "$DEPENDS_SET" = 1 ] || DEPENDS="$BASE_DEPS, libnss3, libxkbcommon0, libxdamage1, libxcomposite1, libgbm1, libasound2t64"
    ;;
  *) echo "bad --variant $VARIANT" >&2; exit 2 ;;
esac

ROOT="$(mktemp -d "${TMPDIR:-$PWD}/debroot.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/chuk-chat" "$ROOT/usr/bin" \
  "$ROOT/usr/share/applications" "$ROOT/usr/share/icons/hicolor/512x512/apps"
cp -r "$BUNDLE"/. "$ROOT/opt/chuk-chat/"
chmod 0755 "$ROOT/opt/chuk-chat/chuk_chat"
ln -s /opt/chuk-chat/chuk_chat "$ROOT/usr/bin/chuk-chat"
[ -n "$ICON" ] && [ -f "$ICON" ] && \
  install -m 0644 "$ICON" "$ROOT/usr/share/icons/hicolor/512x512/apps/chuk-chat.png"

cat > "$ROOT/usr/share/applications/chuk-chat.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$APP_NAME
GenericName=Chat Application
Comment=Privacy-focused AI chat with end-to-end encryption
Exec=/opt/chuk-chat/chuk_chat
Icon=chuk-chat
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=chuk_chat
Keywords=chat;ai;encrypted;privacy;
EOF

EXTRA_FIELDS=""
if [ "$VARIANT" = full ]; then
  EXTRA_FIELDS="Conflicts: chuk-chat
Replaces: chuk-chat
Provides: chuk-chat"
else
  EXTRA_FIELDS="Conflicts: chuk-chat-full
Replaces: chuk-chat-full"
fi

{
  echo "Package: $PKG"
  echo "Version: $VERSION"
  echo "Section: net"
  echo "Priority: optional"
  echo "Architecture: $ARCH"
  echo "Maintainer: Chuk Development <support@chuk.dev>"
  echo "Homepage: https://chuk.chat"
  [ -n "$DEPENDS" ] && echo "Depends: $DEPENDS"
  echo "$EXTRA_FIELDS"
  echo "Description: $DESC_SHORT"
  echo "$DESC_LONG"
} > "$ROOT/DEBIAN/control"

if [ "$VARIANT" = slim ]; then
  # Keyring: owned by the package, so a new key reaches every user with
  # the next update, and "apt remove" deletes it.
  mkdir -p "$ROOT/usr/share/keyrings" "$ROOT/usr/share/chuk-chat"
  gpg --batch --yes --dearmor -o "$ROOT/usr/share/keyrings/chuk-chat.gpg" < "$REPO_PUBLIC_KEY"
  chmod 0644 "$ROOT/usr/share/keyrings/chuk-chat.gpg"
  write_apt_sources stable > "$ROOT/usr/share/chuk-chat/chuk-chat.sources"
  chmod 0644 "$ROOT/usr/share/chuk-chat/chuk-chat.sources"

  cat > "$ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
REPO_URL="$REPO_BASE_URL/deb"
EOF
  cat >> "$ROOT/DEBIAN/postinst" <<'EOF'
SRC=/etc/apt/sources.list.d/chuk-chat.sources

repo_opted_out() {
  [ -r /etc/default/chuk-chat ] &&
    grep -qiE '^[[:space:]]*repo[[:space:]]*=[[:space:]]*"?(no|false|0)"?[[:space:]]*$' /etc/default/chuk-chat
}

# Is the repository already configured (by us or by hand, any file name)?
repo_configured() {
  [ -e "$SRC" ] && return 0
  grep -qsF "$REPO_URL" /etc/apt/sources.list 2>/dev/null && return 0
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && grep -qsF "$REPO_URL" "$f" && return 0
  done
  return 1
}

if [ "$1" = "configure" ]; then
  if ! repo_opted_out && ! repo_configured; then
    install -m 0644 /usr/share/chuk-chat/chuk-chat.sources "$SRC"
  fi
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF

  cat > "$ROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
MARKER="$APT_SOURCES_MARKER"
EOF
  cat >> "$ROOT/DEBIAN/postrm" <<'EOF'
SRC=/etc/apt/sources.list.d/chuk-chat.sources
case "$1" in
  remove|purge)
    # The keyring goes with the package. A source that points to a
    # missing keyring makes "apt update" fail, so remove our source too.
    # Only a file that carries our marker line is removed.
    if [ -f "$SRC" ] && grep -qxF "$MARKER" "$SRC"; then
      rm -f "$SRC"
    fi
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    ;;
esac
exit 0
EOF
else
  cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF
fi
chmod 0755 "$ROOT/DEBIAN/postinst"
[ -f "$ROOT/DEBIAN/postrm" ] && chmod 0755 "$ROOT/DEBIAN/postrm"

dpkg-deb --root-owner-group --build "$ROOT" "$OUT" >/dev/null
echo "built $OUT ($PKG $VERSION $ARCH)"
