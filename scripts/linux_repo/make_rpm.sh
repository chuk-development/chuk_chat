#!/usr/bin/env bash
# Build the Chuk Chat .rpm from a Flutter Linux release bundle.
#
#   make_rpm.sh --bundle DIR --arch x86_64|aarch64 --version PKGVER --out FILE
#               [--variant slim|full] [--icon PNG] [--requires "a, b"]
#
# The slim package owns /etc/yum.repos.d/chuk-chat.repo (%config noreplace):
# installing it once adds the dnf repository, "dnf remove" deletes it, and a
# local edit (enabled=0) survives updates. The full package is called
# chuk-chat-full, is not in the repository and does not add it.
#
# The package is not signed here. The repository job signs the copy it
# publishes (scripts/linux_repo/build_repo.sh), so the private key never
# reaches the build jobs that run third-party build code.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BUNDLE="" ARCH="" VERSION="" OUT="" VARIANT="slim" ICON="" REQUIRES=""
REQUIRES_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --requires) REQUIRES="$2"; REQUIRES_SET=1; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$BUNDLE" ] && [ -n "$ARCH" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || {
  echo "usage: $0 --bundle DIR --arch x86_64|aarch64 --version PKGVER --out FILE [--variant slim|full]" >&2
  exit 2
}
case "$ARCH" in x86_64|aarch64) ;; *) echo "bad --arch $ARCH" >&2; exit 2 ;; esac
printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(~pre\.[0-9]+)?$' \
  || { echo "bad --version $VERSION" >&2; exit 2; }

BASE_REQ="gtk3, libblkid, xz-libs, gstreamer1, gstreamer1-plugins-base, gstreamer1-plugins-good"
case "$VARIANT" in
  slim)
    NAME=chuk-chat
    SUMMARY="Privacy-focused AI chat with end-to-end encryption"
    APP_NAME="Chuk Chat"
    [ "$REQUIRES_SET" = 1 ] || REQUIRES="$BASE_REQ"
    RELATION="Conflicts:      chuk-chat-full"
    ;;
  full)
    NAME=chuk-chat-full
    SUMMARY="Privacy-focused AI chat with CEF-backed Linux WebView"
    APP_NAME="Chuk Chat (full)"
    [ "$REQUIRES_SET" = 1 ] || REQUIRES="$BASE_REQ, nss, libxkbcommon, libXdamage, libXcomposite, mesa-libgbm, alsa-lib"
    RELATION="Conflicts:      chuk-chat
Obsoletes:      chuk-chat < %{version}-%{release}
Provides:       chuk-chat = %{version}-%{release}"
    ;;
  *) echo "bad --variant $VARIANT" >&2; exit 2 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-$PWD}/rpmwork.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TOP="$WORK/rpmbuild"
SRC="$WORK/src"
mkdir -p "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS} "$SRC/opt/chuk-chat" "$SRC/usr/bin" \
  "$SRC/usr/share/applications" "$SRC/usr/share/icons/hicolor/512x512/apps"
cp -r "$BUNDLE"/. "$SRC/opt/chuk-chat/"
chmod 0755 "$SRC/opt/chuk-chat/chuk_chat"
ln -s /opt/chuk-chat/chuk_chat "$SRC/usr/bin/chuk-chat"
HAS_ICON=0
if [ -n "$ICON" ] && [ -f "$ICON" ]; then
  install -m 0644 "$ICON" "$SRC/usr/share/icons/hicolor/512x512/apps/chuk-chat.png"
  HAS_ICON=1
fi
cat > "$SRC/usr/share/applications/chuk-chat.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$APP_NAME
Comment=Privacy-focused AI chat with end-to-end encryption
Exec=/opt/chuk-chat/chuk_chat
Icon=chuk-chat
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=chuk_chat
EOF
if [ "$VARIANT" = slim ]; then
  mkdir -p "$SRC/etc/yum.repos.d"
  write_dnf_repo > "$SRC/etc/yum.repos.d/chuk-chat.repo"
  chmod 0644 "$SRC/etc/yum.repos.d/chuk-chat.repo"
fi

# rpm macros: a "%" in the version would be expanded. The version regex
# above allows digits, dots, "~" and "pre" only.
tar -czf "$TOP/SOURCES/$NAME.tar.gz" -C "$SRC" .

{
  cat <<EOF
# Prebuilt Flutter bundle: no debuginfo split, no binary stripping.
%global debug_package %{nil}
%global __os_install_post %{nil}
# No /usr/lib/.build-id links: they can clash with other packages.
%global _build_id_links none
Name:           $NAME
Version:        $VERSION
Release:        1
Summary:        $SUMMARY
License:        BSL-1.1
URL:            https://chuk.chat
Source0:        $NAME.tar.gz
BuildArch:      $ARCH
EOF
  [ -n "$REQUIRES" ] && echo "Requires:       $REQUIRES"
  echo "$RELATION"
  cat <<'EOF'

%description
Chuk Chat is a cross-platform chat application that uses
open-weight AI models with AES-256-GCM end-to-end encryption.

%prep
%setup -q -c

%build

%install
mkdir -p %{buildroot}
cp -a . %{buildroot}/

%files
/opt/chuk-chat/
/usr/bin/chuk-chat
/usr/share/applications/chuk-chat.desktop
EOF
  [ "$HAS_ICON" = 1 ] && echo "/usr/share/icons/hicolor/512x512/apps/chuk-chat.png"
  [ "$VARIANT" = slim ] && echo "%config(noreplace) /etc/yum.repos.d/chuk-chat.repo"
  cat <<'EOF'

%post
update-desktop-database /usr/share/applications >/dev/null 2>&1 || :
gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || :

%postun
update-desktop-database /usr/share/applications >/dev/null 2>&1 || :
EOF
} > "$TOP/SPECS/$NAME.spec"

rpmbuild --quiet --define "_topdir $TOP" --target "$ARCH" -bb "$TOP/SPECS/$NAME.spec"
cp "$TOP/RPMS/$ARCH/$NAME-"*.rpm "$OUT"
echo "built $OUT ($NAME $VERSION $ARCH)"
