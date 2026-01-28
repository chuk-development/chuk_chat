#!/bin/bash
# Linux packaging script for chuk_chat
# Creates AppImage, DEB, and RPM packages

set -e

PACKAGE_TYPE=${1:-all}
VERSION=${2:-1.0.0}
APP_NAME="chuk_chat"
BUNDLE_DIR="build/linux/x64/release/bundle"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}🐧 Building Linux packages for ${APP_NAME} v${VERSION}${NC}"

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
    echo -e "${RED}❌ Error: SUPABASE_URL or SUPABASE_ANON_KEY not set${NC}"
    echo -e "${YELLOW}Create .env file with these values or set environment variables${NC}"
    exit 1
fi

# Build Flutter app if not already built
if [ ! -d "$BUNDLE_DIR" ]; then
    echo -e "${YELLOW}Building Flutter Linux app...${NC}"
    flutter build linux --release \
        --dart-define=SUPABASE_URL=$SUPABASE_URL \
        --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
        --dart-define=FEATURE_PROJECTS=true \
        --dart-define=FEATURE_IMAGE_GEN=true \
        --dart-define=FEATURE_MEDIA_MANAGER=true \
        --dart-define=FEATURE_VOICE_MODE=true \
        --tree-shake-icons
fi

# Create AppImage
build_appimage() {
    echo -e "${YELLOW}📦 Creating AppImage...${NC}"

    APPDIR="build/linux/AppDir"
    rm -rf "$APPDIR"
    mkdir -p "$APPDIR/usr/bin"
    mkdir -p "$APPDIR/usr/lib"
    mkdir -p "$APPDIR/usr/share/applications"
    mkdir -p "$APPDIR/usr/share/icons/hicolor/512x512/apps"

    # Copy bundle
    cp -r "$BUNDLE_DIR"/* "$APPDIR/usr/bin/"

    # Create desktop entry
    cat > "$APPDIR/usr/share/applications/${APP_NAME}.desktop" << EOF
[Desktop Entry]
Type=Application
Name=chuk_chat
Comment=Privacy-focused chat app with E2E encryption
Exec=chuk_chat
Icon=chuk_chat
Categories=Network;InstantMessaging;
Terminal=false
EOF

    # Copy icon (if exists)
    if [ -f "web/icons/Icon-512.png" ]; then
        cp "web/icons/Icon-512.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/${APP_NAME}.png"
        cp "web/icons/Icon-512.png" "$APPDIR/${APP_NAME}.png"
    fi

    # Create AppRun
    cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
SELF=$(readlink -f "$0")
HERE=${SELF%/*}
export PATH="${HERE}/usr/bin/:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib/:${LD_LIBRARY_PATH}"
exec "${HERE}/usr/bin/chuk_chat" "$@"
EOF
    chmod +x "$APPDIR/AppRun"

    # Copy desktop file to root
    cp "$APPDIR/usr/share/applications/${APP_NAME}.desktop" "$APPDIR/"

    # Build AppImage
    if command -v appimagetool &> /dev/null; then
        ARCH=x86_64 appimagetool "$APPDIR" "${APP_NAME}-${VERSION}-x86_64.AppImage"
        echo -e "${GREEN}✅ AppImage created: ${APP_NAME}-${VERSION}-x86_64.AppImage${NC}"
    else
        echo -e "${YELLOW}⚠️  appimagetool not found, skipping AppImage creation${NC}"
    fi
}

# Create DEB package
build_deb() {
    echo -e "${YELLOW}📦 Creating DEB package...${NC}"

    DEB_DIR="build/linux/deb"
    rm -rf "$DEB_DIR"
    mkdir -p "$DEB_DIR/DEBIAN"
    mkdir -p "$DEB_DIR/opt/${APP_NAME}"
    mkdir -p "$DEB_DIR/usr/share/applications"
    mkdir -p "$DEB_DIR/usr/share/icons/hicolor/512x512/apps"
    mkdir -p "$DEB_DIR/usr/bin"

    # Copy bundle
    cp -r "$BUNDLE_DIR"/* "$DEB_DIR/opt/${APP_NAME}/"

    # Create symlink
    ln -s "/opt/${APP_NAME}/${APP_NAME}" "$DEB_DIR/usr/bin/${APP_NAME}"

    # Create control file
    cat > "$DEB_DIR/DEBIAN/control" << EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: net
Priority: optional
Architecture: amd64
Maintainer: chuk Development <dev@chuk.chat>
Description: Privacy-focused chat app with E2E encryption
 Cross-platform Flutter chat app with end-to-end encryption,
 Supabase backend, and AI chat integration.
Depends: libgtk-3-0, libblkid1, liblzma5
EOF

    # Create desktop entry
    cat > "$DEB_DIR/usr/share/applications/${APP_NAME}.desktop" << EOF
[Desktop Entry]
Type=Application
Name=chuk_chat
Comment=Privacy-focused chat app with E2E encryption
Exec=/opt/${APP_NAME}/${APP_NAME}
Icon=${APP_NAME}
Categories=Network;InstantMessaging;
Terminal=false
EOF

    # Copy icon
    if [ -f "web/icons/Icon-512.png" ]; then
        cp "web/icons/Icon-512.png" "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/${APP_NAME}.png"
    fi

    # Build DEB
    dpkg-deb --build "$DEB_DIR" "${APP_NAME}_${VERSION}_amd64.deb"
    echo -e "${GREEN}✅ DEB package created: ${APP_NAME}_${VERSION}_amd64.deb${NC}"
}

# Create RPM package
build_rpm() {
    echo -e "${YELLOW}📦 Creating RPM package...${NC}"

    RPM_DIR="build/linux/rpm"
    rm -rf "$RPM_DIR"
    mkdir -p "$RPM_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    mkdir -p "$RPM_DIR/BUILD/opt/${APP_NAME}"
    mkdir -p "$RPM_DIR/BUILD/usr/share/applications"
    mkdir -p "$RPM_DIR/BUILD/usr/share/icons/hicolor/512x512/apps"
    mkdir -p "$RPM_DIR/BUILD/usr/bin"

    # Copy bundle
    cp -r "$BUNDLE_DIR"/* "$RPM_DIR/BUILD/opt/${APP_NAME}/"

    # Create spec file
    cat > "$RPM_DIR/SPECS/${APP_NAME}.spec" << EOF
Name:           ${APP_NAME}
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Privacy-focused chat app with E2E encryption

License:        Proprietary
URL:            https://github.com/chuk-development/chuk_chat
BuildArch:      x86_64

Requires:       gtk3, libblkid, xz-libs

%description
Cross-platform Flutter chat app with end-to-end encryption,
Supabase backend, and AI chat integration.

%install
mkdir -p %{buildroot}/opt/${APP_NAME}
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons/hicolor/512x512/apps
mkdir -p %{buildroot}/usr/bin

cp -r $RPM_DIR/BUILD/opt/${APP_NAME}/* %{buildroot}/opt/${APP_NAME}/
ln -s /opt/${APP_NAME}/${APP_NAME} %{buildroot}/usr/bin/${APP_NAME}

cat > %{buildroot}/usr/share/applications/${APP_NAME}.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=chuk_chat
Comment=Privacy-focused chat app with E2E encryption
Exec=/opt/${APP_NAME}/${APP_NAME}
Icon=${APP_NAME}
Categories=Network;InstantMessaging;
Terminal=false
DESKTOP
EOF

    if [ -f "web/icons/Icon-512.png" ]; then
        echo "cp $PWD/web/icons/Icon-512.png %{buildroot}/usr/share/icons/hicolor/512x512/apps/${APP_NAME}.png" >> "$RPM_DIR/SPECS/${APP_NAME}.spec"
    fi

    cat >> "$RPM_DIR/SPECS/${APP_NAME}.spec" << EOF

%files
/opt/${APP_NAME}/*
/usr/bin/${APP_NAME}
/usr/share/applications/${APP_NAME}.desktop
/usr/share/icons/hicolor/512x512/apps/${APP_NAME}.png

%changelog
* $(date "+%a %b %d %Y") Builder <builder@chuk.chat> - ${VERSION}-1
- Release ${VERSION}
EOF

    # Build RPM
    if command -v rpmbuild &> /dev/null; then
        rpmbuild --define "_topdir $PWD/$RPM_DIR" -bb "$RPM_DIR/SPECS/${APP_NAME}.spec"
        cp "$RPM_DIR/RPMS/x86_64/${APP_NAME}-${VERSION}-1.x86_64.rpm" .
        echo -e "${GREEN}✅ RPM package created: ${APP_NAME}-${VERSION}-1.x86_64.rpm${NC}"
    else
        echo -e "${YELLOW}⚠️  rpmbuild not found, skipping RPM creation${NC}"
    fi
}

# Build based on type
case $PACKAGE_TYPE in
    appimage)
        build_appimage
        ;;
    deb)
        build_deb
        ;;
    rpm)
        build_rpm
        ;;
    all)
        build_appimage
        build_deb
        build_rpm
        ;;
    *)
        echo -e "${RED}❌ Unknown package type: $PACKAGE_TYPE${NC}"
        echo "Usage: $0 [appimage|deb|rpm|all] [version]"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}✅ Linux packaging complete!${NC}"
