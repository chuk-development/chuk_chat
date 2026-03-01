#!/bin/bash

# Unified build script for Chuk Chat
# Usage: ./build.sh [target]
# Targets: linux, deb, rpm, apk, apk-desktop, appimage, all
#
# IMPORTANT: Requires .env file with SUPABASE_URL and SUPABASE_ANON_KEY.
#
# Tree-shaking optimization:
# - Desktop builds exclude mobile code, mobile builds exclude desktop code
# - --tree-shake-icons removes unused Material/Cupertino icons
# - --split-debug-info separates debug symbols for smaller binaries
# - --obfuscate obfuscates Dart code

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Print functions
print_header() { echo -e "${PURPLE}$1${NC}"; }
print_info() { echo -e "${BLUE}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; }

# Display name (shown in desktop launchers, etc.)
DISPLAY_NAME="Chuk Chat"

# Load environment variables
load_env() {
    if [ -f ".env" ]; then
        # shellcheck disable=SC2046
        export $(grep -v '^#' .env | xargs)
    fi

    if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
        print_error "SUPABASE_URL and SUPABASE_ANON_KEY must be set."
        print_error "Create .env file from .env.example or set environment variables."
        exit 1
    fi

    print_success "Supabase credentials loaded"
}

# Common dart-define flags for all builds
dart_defines_desktop() {
    echo "--dart-define=SUPABASE_URL=$SUPABASE_URL \
        --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
        --dart-define=PLATFORM_DESKTOP=true \
        --dart-define=FEATURE_PROJECTS=true \
        --dart-define=FEATURE_IMAGE_GEN=true \
        --dart-define=FEATURE_VOICE_MODE=true"
}

dart_defines_mobile() {
    echo "--dart-define=SUPABASE_URL=$SUPABASE_URL \
        --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
        --dart-define=PLATFORM_MOBILE=true \
        --dart-define=FEATURE_PROJECTS=false \
        --dart-define=FEATURE_IMAGE_GEN=true \
        --dart-define=FEATURE_VOICE_MODE=false"
}

# Extract app information
extract_app_info() {
    print_info "Extracting app information from pubspec.yaml..."

    APP_NAME=$(grep '^name:' pubspec.yaml | sed 's/^name:[[:space:]]*//' | sed 's/[[:space:]]*$//')
    VERSION=$(grep '^version:' pubspec.yaml | sed 's/^version:[[:space:]]*//' | sed 's/+.*//' | sed 's/[[:space:]]*$//')

    if [ -z "$APP_NAME" ] || [ -z "$VERSION" ]; then
        print_error "Could not extract app name or version from pubspec.yaml"
        exit 1
    fi

    # Package name uses hyphens (chuk-chat), binary name uses underscores (chuk_chat)
    PACKAGE_NAME=$(echo "$APP_NAME" | sed 's/_/-/g')

    # Extract patch number as Android build number (e.g. 1.0.39 -> 39)
    # This ensures --split-per-abi version codes increase when you bump the version
    BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{print $3}')
    if [ -z "$BUILD_NUMBER" ] || [ "$BUILD_NUMBER" -lt 1 ] 2>/dev/null; then
        BUILD_NUMBER=1
    fi

    print_success "App: $APP_NAME v$VERSION (package: $PACKAGE_NAME, build: $BUILD_NUMBER)"
}

# Find the best app icon
find_app_icon() {
    print_info "Finding app icon..."

    ICON_PATH=""

    # Prefer web 512px icon (best quality for desktop)
    if [ -f "web/icons/Icon-512.png" ]; then
        ICON_PATH="web/icons/Icon-512.png"
    else
        # Fall back to Android mipmap icons
        for size in xxxhdpi xxhdpi xhdpi hdpi mdpi; do
            if [ -f "android/app/src/main/res/mipmap-${size}/ic_launcher.png" ]; then
                ICON_PATH="android/app/src/main/res/mipmap-${size}/ic_launcher.png"
                break
            fi
        done
    fi

    if [ -n "$ICON_PATH" ]; then
        print_success "Found icon: $ICON_PATH"
    else
        print_warning "No app icon found"
    fi
}

# Clean up previous builds
cleanup() {
    print_info "Cleaning up previous builds..."
    flutter clean
    rm -rf debian rpm build/linux build/app AppDir
    mkdir -p releases/linux releases/android
}

# Build Linux app
build_linux() {
    local arch=$1
    print_info "Building Linux app for $arch..."

    local defines
    defines=$(dart_defines_desktop)

    case $arch in
        "amd64")
            eval flutter build linux --release --target-platform linux-x64 \
                $defines \
                --tree-shake-icons \
                --split-debug-info=build/debug-info \
                --obfuscate
            ;;
        "arm64")
            if ! eval flutter build linux --release --target-platform linux-arm64 \
                $defines \
                --tree-shake-icons \
                --split-debug-info=build/debug-info \
                --obfuscate 2>/dev/null; then
                print_warning "ARM64 build not supported on this system, skipping..."
                return 1
            fi
            ;;
        *)
            print_error "Unsupported Linux architecture: $arch"
            exit 1
            ;;
    esac

    print_success "Linux build completed for $arch"
    return 0
}

# Get the bundle directory for a given arch
bundle_dir() {
    local arch=$1
    if [ "$arch" = "amd64" ]; then
        echo "build/linux/x64/release/bundle"
    else
        echo "build/linux/arm64/release/bundle"
    fi
}

# Create deb package
create_deb() {
    local arch=$1
    local bundle
    bundle=$(bundle_dir "$arch")
    print_info "Creating .deb package for $arch..."

    # Create directory structure — install to /opt/chuk-chat/
    mkdir -p "debian/DEBIAN"
    mkdir -p "debian/opt/$PACKAGE_NAME"
    mkdir -p "debian/usr/bin"
    mkdir -p "debian/usr/share/applications"
    mkdir -p "debian/usr/share/icons/hicolor/512x512/apps"

    # Copy Flutter bundle
    cp -r "$bundle"/* "debian/opt/$PACKAGE_NAME/"
    chmod +x "debian/opt/$PACKAGE_NAME/$APP_NAME"

    # Create symlink so 'chuk-chat' works from command line
    ln -s "/opt/$PACKAGE_NAME/$APP_NAME" "debian/usr/bin/$PACKAGE_NAME"

    # Copy icon
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        cp "$ICON_PATH" "debian/usr/share/icons/hicolor/512x512/apps/$PACKAGE_NAME.png"
    fi

    # Desktop entry
    cat > "debian/usr/share/applications/$PACKAGE_NAME.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
GenericName=Chat Application
Comment=Privacy-focused AI chat with end-to-end encryption
Exec=/opt/$PACKAGE_NAME/$APP_NAME
Icon=$PACKAGE_NAME
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=$APP_NAME
Keywords=chat;ai;encrypted;privacy;
EOF

    # Control file
    cat > "debian/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $arch
Maintainer: Chuk Development <support@chuk.dev>
Homepage: https://chuk.chat
Description: Privacy-focused AI chat with end-to-end encryption
 $DISPLAY_NAME is a cross-platform chat application that uses
 open-weight AI models with AES-256-GCM end-to-end encryption.
 Your messages are encrypted on your device before leaving it.
Depends: libgtk-3-0, libblkid1, liblzma5
EOF

    # Post-install script
    cat > "debian/DEBIAN/postinst" <<'EOF'
#!/bin/bash
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
EOF

    # Pre-remove script
    cat > "debian/DEBIAN/prerm" <<'EOF'
#!/bin/bash
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
EOF

    chmod +x "debian/DEBIAN/postinst"
    chmod +x "debian/DEBIAN/prerm"

    # Build
    dpkg-deb --build debian "releases/linux/${PACKAGE_NAME}_${VERSION}_${arch}.deb"
    print_success "Created ${PACKAGE_NAME}_${VERSION}_${arch}.deb"
}

# Create rpm package
create_rpm() {
    local arch=$1
    local bundle
    bundle=$(bundle_dir "$arch")
    print_info "Creating .rpm package for $arch..."

    if ! command -v rpmbuild &> /dev/null; then
        print_warning "rpmbuild not found. Install with: sudo apt install rpm"
        return 0
    fi

    # Map Debian arch to RPM arch
    local rpm_arch="x86_64"
    [ "$arch" = "arm64" ] && rpm_arch="aarch64"

    # Create directory structure
    mkdir -p rpm/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    mkdir -p "rpm/SOURCES/$PACKAGE_NAME-$VERSION"
    cp -r "$bundle"/* "rpm/SOURCES/$PACKAGE_NAME-$VERSION/"

    # Create tarball
    (cd rpm/SOURCES && tar -czf "$PACKAGE_NAME-$VERSION.tar.gz" "$PACKAGE_NAME-$VERSION")

    # Spec file
    cat > "rpm/SPECS/$PACKAGE_NAME.spec" <<EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        Privacy-focused AI chat with end-to-end encryption
License:        BSL-1.1
URL:            https://chuk.chat
Source0:        %{name}-%{version}.tar.gz
BuildArch:      $rpm_arch
Requires:       gtk3, libblkid, xz-libs

%description
$DISPLAY_NAME is a cross-platform chat application that uses
open-weight AI models with AES-256-GCM end-to-end encryption.
Your messages are encrypted on your device before leaving it.

%prep
%setup -q

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/opt/%{name}
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons/hicolor/512x512/apps
cp -r * %{buildroot}/opt/%{name}/
chmod +x %{buildroot}/opt/%{name}/$APP_NAME
ln -s /opt/%{name}/$APP_NAME %{buildroot}/usr/bin/%{name}
EOF

    # Copy icon into rpm build
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        cp "$ICON_PATH" "rpm/BUILD/$PACKAGE_NAME.png"
        echo "cp $PWD/rpm/BUILD/$PACKAGE_NAME.png %{buildroot}/usr/share/icons/hicolor/512x512/apps/%{name}.png" >> "rpm/SPECS/$PACKAGE_NAME.spec"
    fi

    # Desktop entry and file list
    cat >> "rpm/SPECS/$PACKAGE_NAME.spec" <<EOF

cat > %{buildroot}/usr/share/applications/%{name}.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
GenericName=Chat Application
Comment=Privacy-focused AI chat with end-to-end encryption
Exec=/opt/$PACKAGE_NAME/$APP_NAME
Icon=$PACKAGE_NAME
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=$APP_NAME
Keywords=chat;ai;encrypted;privacy;
DESKTOP

%files
/opt/%{name}/
/usr/bin/%{name}
/usr/share/applications/%{name}.desktop
/usr/share/icons/hicolor/512x512/apps/%{name}.png

%post
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true

%preun
rm -f /usr/share/applications/%{name}.desktop
update-desktop-database /usr/share/applications 2>/dev/null || true

%changelog
* $(date '+%a %b %d %Y') Chuk Development <support@chuk.dev> - $VERSION-1
- Release $VERSION
EOF

    rpmbuild --define "_topdir $(pwd)/rpm" -bb "rpm/SPECS/$PACKAGE_NAME.spec"
    find rpm/RPMS -name "*.rpm" -exec cp {} "releases/linux/${PACKAGE_NAME}_${VERSION}_${rpm_arch}.rpm" \;

    print_success "Created ${PACKAGE_NAME}_${VERSION}_${rpm_arch}.rpm"
}

# Download appimagetool if not present
download_appimagetool() {
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local TOOLS_DIR="$SCRIPT_DIR/tools"
    local APPIMAGETOOL_PATH="$TOOLS_DIR/appimagetool"

    if [ -x "$APPIMAGETOOL_PATH" ]; then
        return 0
    fi

    print_info "appimagetool not found, downloading..."
    mkdir -p "$TOOLS_DIR"

    local DOWNLOAD_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"

    if command -v curl &> /dev/null; then
        curl -L -o "$APPIMAGETOOL_PATH" "$DOWNLOAD_URL"
    elif command -v wget &> /dev/null; then
        wget -O "$APPIMAGETOOL_PATH" "$DOWNLOAD_URL"
    else
        print_error "Neither curl nor wget found. Cannot download appimagetool."
        return 1
    fi

    if [ -f "$APPIMAGETOOL_PATH" ]; then
        chmod +x "$APPIMAGETOOL_PATH"
        print_success "Downloaded appimagetool"
        return 0
    else
        print_error "Failed to download appimagetool"
        return 1
    fi
}

# Create AppImage
create_appimage() {
    local arch=$1
    local bundle
    bundle=$(bundle_dir "$arch")
    print_info "Creating AppImage for $arch..."

    # Map to AppImage arch naming
    local appimage_arch="x86_64"
    [ "$arch" = "arm64" ] && appimage_arch="aarch64"

    # Find appimagetool
    local APPIMAGETOOL=""
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ ! -x "$SCRIPT_DIR/tools/appimagetool" ]; then
        download_appimagetool
    fi

    if [ -x "$SCRIPT_DIR/tools/appimagetool" ]; then
        APPIMAGETOOL="$SCRIPT_DIR/tools/appimagetool"
    elif command -v appimagetool &> /dev/null; then
        APPIMAGETOOL="appimagetool"
    else
        print_warning "appimagetool not found. Skipping AppImage creation."
        return 0
    fi

    # Create AppDir structure
    mkdir -p "AppDir/usr/bin"
    mkdir -p "AppDir/usr/share/applications"
    mkdir -p "AppDir/usr/share/icons/hicolor/512x512/apps"

    # Copy Flutter bundle
    cp -r "$bundle"/* "AppDir/usr/bin/"
    chmod +x "AppDir/usr/bin/$APP_NAME"

    # Copy icon
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        cp "$ICON_PATH" "AppDir/usr/share/icons/hicolor/512x512/apps/$PACKAGE_NAME.png"
        # AppImage needs icon in root
        cp "$ICON_PATH" "AppDir/$PACKAGE_NAME.png"
    fi

    # Desktop entry
    cat > "AppDir/$PACKAGE_NAME.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
GenericName=Chat Application
Comment=Privacy-focused AI chat with end-to-end encryption
Exec=$APP_NAME
Icon=$PACKAGE_NAME
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=$APP_NAME
Keywords=chat;ai;encrypted;privacy;
EOF

    # Copy desktop file into standard location too
    cp "AppDir/$PACKAGE_NAME.desktop" "AppDir/usr/share/applications/"

    # AppRun
    cat > "AppDir/AppRun" <<'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${HERE}/usr/bin/lib:${LD_LIBRARY_PATH}"
exec "${HERE}/usr/bin/chuk_chat" "$@"
APPRUN
    chmod +x "AppDir/AppRun"

    # Build AppImage with correct architecture
    ARCH=$appimage_arch $APPIMAGETOOL AppDir "releases/linux/${PACKAGE_NAME}_${VERSION}_${appimage_arch}.AppImage"
    print_success "Created ${PACKAGE_NAME}_${VERSION}_${appimage_arch}.AppImage"
}

# Build Android APKs (mobile UI)
build_android() {
    print_info "Building Android APKs..."

    local defines
    defines=$(dart_defines_mobile)

    if eval flutter build apk --release --split-per-abi \
        $defines \
        --build-number=$BUILD_NUMBER \
        --tree-shake-icons \
        --split-debug-info=build/android-debug-info \
        --obfuscate; then

        mkdir -p releases/android

        for apk in build/app/outputs/flutter-apk/app-*-release.apk; do
            if [ -f "$apk" ]; then
                filename=$(basename "$apk")
                arch=$(echo "$filename" | sed 's/app-\(.*\)-release.apk/\1/')
                cp "$apk" "releases/android/${PACKAGE_NAME}_${VERSION}_${arch}.apk"
                print_success "Created ${PACKAGE_NAME}_${VERSION}_${arch}.apk"
            fi
        done
    else
        print_error "Android build failed"
        return 1
    fi
}

# Build Android APKs with desktop UI (for tablets)
build_android_desktop() {
    print_info "Building Android APKs with desktop UI for tablets..."

    local defines
    defines=$(dart_defines_desktop)

    if eval flutter build apk --release --split-per-abi \
        $defines \
        --build-number=$BUILD_NUMBER \
        --tree-shake-icons \
        --split-debug-info=build/android-debug-info \
        --obfuscate; then

        mkdir -p releases/android

        for apk in build/app/outputs/flutter-apk/app-*-release.apk; do
            if [ -f "$apk" ]; then
                filename=$(basename "$apk")
                arch=$(echo "$filename" | sed 's/app-\(.*\)-release.apk/\1/')
                cp "$apk" "releases/android/${PACKAGE_NAME}_${VERSION}_${arch}_desktop.apk"
                print_success "Created ${PACKAGE_NAME}_${VERSION}_${arch}_desktop.apk"
            fi
        done
    else
        print_error "Android tablet build failed"
        return 1
    fi
}

# Main build functions
build_linux_packages() {
    print_header "Building Linux packages..."
    for arch in amd64 arm64; do
        print_header "Building for $arch..."

        if build_linux $arch; then
            create_deb $arch
            create_rpm $arch
            create_appimage $arch
            rm -rf debian rpm AppDir
        else
            print_warning "Skipping $arch packages (build failed)"
        fi
    done
}

build_deb_packages() {
    print_header "Building DEB packages..."
    for arch in amd64 arm64; do
        if build_linux $arch; then
            create_deb $arch
            rm -rf debian
        else
            print_warning "Skipping DEB for $arch"
        fi
    done
}

build_rpm_packages() {
    print_header "Building RPM packages..."
    for arch in amd64 arm64; do
        if build_linux $arch; then
            create_rpm $arch
            rm -rf rpm
        else
            print_warning "Skipping RPM for $arch"
        fi
    done
}

build_appimage_packages() {
    print_header "Building AppImage packages..."
    for arch in amd64 arm64; do
        if build_linux $arch; then
            create_appimage $arch
            rm -rf AppDir
        else
            print_warning "Skipping AppImage for $arch"
        fi
    done
}

# Show usage
show_usage() {
    echo ""
    print_header "Chuk Chat Build System"
    echo ""
    echo "Usage: $0 [target]"
    echo ""
    echo "Targets:"
    echo "  linux       All Linux packages (DEB, RPM, AppImage)"
    echo "  deb         DEB packages only (Debian/Ubuntu)"
    echo "  rpm         RPM packages only (Fedora/RHEL)"
    echo "  appimage    AppImage packages only"
    echo "  apk         Android APKs (mobile UI)"
    echo "  apk-desktop Android APKs (desktop UI for tablets)"
    echo "  all         Linux + Android"
    echo ""
    echo "Output: releases/linux/ and releases/android/"
    echo ""
}

# Main execution
main() {
    if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ "$1" = "help" ]; then
        show_usage
        exit 0
    fi

    local target=$1

    extract_app_info
    load_env
    find_app_icon
    cleanup

    print_header "Building $DISPLAY_NAME v$VERSION..."

    case $target in
        "linux")    build_linux_packages ;;
        "deb")      build_deb_packages ;;
        "rpm")      build_rpm_packages ;;
        "appimage") build_appimage_packages ;;
        "apk")      build_android ;;
        "apk-desktop") build_android_desktop ;;
        "all")
            build_linux_packages
            build_android
            ;;
        *)
            print_error "Unknown target: $target"
            show_usage
            exit 1
            ;;
    esac

    echo ""
    print_success "Build completed!"
    echo ""
    print_info "Linux packages:"
    ls -lh releases/linux/ 2>/dev/null || echo "  (none)"
    echo ""
    print_info "Android packages:"
    ls -lh releases/android/ 2>/dev/null || echo "  (none)"
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    command -v flutter &> /dev/null || missing_deps+=("flutter")
    command -v dpkg-deb &> /dev/null || missing_deps+=("dpkg-deb")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

check_dependencies
main "$@"
