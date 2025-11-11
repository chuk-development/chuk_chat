#!/bin/bash

# Unified build script for chuk_chat
# Usage: ./build.sh [target]
# Targets: linux, deb, rpm, apk, appimage, all
#
# TREE-SHAKING OPTIMIZATION:
# This build script uses Flutter's tree-shaking to automatically remove unused code:
# - When building for Linux/Desktop: Mobile-specific code (root_wrapper_mobile.dart,
#   chat_ui_mobile.dart, etc.) is automatically excluded from the final binary
# - When building for Android/Mobile: Desktop-specific code (root_wrapper_desktop.dart,
#   chat_ui_desktop.dart, etc.) is automatically excluded from the final APK
#
# This is achieved through conditional imports in lib/platform_specific/root_wrapper.dart
# and deferred loading, which allows Dart's tree-shaker to detect and remove unused code paths.
#
# Additional optimizations enabled:
# - --tree-shake-icons: Removes unused Material/Cupertino icons
# - --split-debug-info: Separates debug symbols for smaller binaries
# - --obfuscate: Obfuscates Dart code for better security
#
# Result: Smaller binary sizes and faster load times for each platform!

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Print functions
print_header() { echo -e "${PURPLE}🚀 $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Extract app information
extract_app_info() {
    print_info "Extracting app information from pubspec.yaml..."
    
    APP_NAME=$(grep '^name:' pubspec.yaml | sed 's/^name:[[:space:]]*//' | sed 's/[[:space:]]*$//')
    VERSION=$(grep '^version:' pubspec.yaml | sed 's/^version:[[:space:]]*//' | sed 's/+.*//' | sed 's/[[:space:]]*$//')
    
    if [ -z "$APP_NAME" ] || [ -z "$VERSION" ]; then
        print_error "Could not extract app name or version from pubspec.yaml"
        exit 1
    fi
    
    # Convert app name to package name (replace underscores with hyphens)
    PACKAGE_NAME=$(echo "$APP_NAME" | sed 's/_/-/g')
    
    print_success "App: $APP_NAME, Version: $VERSION, Package: $PACKAGE_NAME"
}

# Find the best app icon
find_app_icon() {
    print_info "Finding app icon..."
    
    # Look for the highest resolution icon
    ICON_PATH=""
    ICON_SIZES=("xxxhdpi" "xxhdpi" "xhdpi" "hdpi" "mdpi")
    
    for size in "${ICON_SIZES[@]}"; do
        if [ -f "android/app/src/main/res/mipmap-${size}/ic_launcher.png" ]; then
            ICON_PATH="android/app/src/main/res/mipmap-${size}/ic_launcher.png"
            print_success "Found icon: $ICON_PATH"
            break
        fi
    done
    
    # Fallback to web icons
    if [ -z "$ICON_PATH" ]; then
        if [ -f "web/icons/Icon-512.png" ]; then
            ICON_PATH="web/icons/Icon-512.png"
            print_success "Using web icon: $ICON_PATH"
        elif [ -f "web/favicon.png" ]; then
            ICON_PATH="web/favicon.png"
            print_success "Using favicon: $ICON_PATH"
        fi
    fi
    
    if [ -z "$ICON_PATH" ]; then
        print_warning "No app icon found, using default"
        ICON_PATH=""
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
    print_info "Building Linux app for $arch (with tree-shaking - mobile code excluded)..."

    case $arch in
        "amd64")
            flutter build linux --release --target-platform linux-x64 \
                --dart-define=PLATFORM_DESKTOP=true \
                --tree-shake-icons \
                --split-debug-info=build/debug-info \
                --obfuscate
            ;;
        "arm64")
            if ! flutter build linux --release --target-platform linux-arm64 \
                --dart-define=PLATFORM_DESKTOP=true \
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

    print_success "Linux build completed for $arch (mobile code tree-shaken)"
    return 0
}

# Create deb package
create_deb() {
    local arch=$1
    print_info "Creating .deb package for $arch..."
    
    # Create directory structure
    mkdir -p debian/DEBIAN
    mkdir -p "debian/usr/local/bin/$APP_NAME"
    mkdir -p "debian/usr/share/applications"
    mkdir -p "debian/usr/share/icons/hicolor/256x256/apps"
    
    # Copy Flutter build
    if [ "$arch" = "amd64" ]; then
        cp -r build/linux/x64/release/bundle/* "debian/usr/local/bin/$APP_NAME/"
    else
        cp -r build/linux/arm64/release/bundle/* "debian/usr/local/bin/$APP_NAME/"
    fi
    
    # Fix permissions on the executable
    chmod +x "debian/usr/local/bin/$APP_NAME/${APP_NAME//-/_}"
    
    # Copy app icon if available
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        cp "$ICON_PATH" "debian/usr/share/icons/hicolor/256x256/apps/$PACKAGE_NAME.png"
    fi
    
    # Create desktop file
    cat > "debian/usr/share/applications/$PACKAGE_NAME.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Chuk Chat
Comment=Modern chat application
Exec=/usr/local/bin/$APP_NAME/${APP_NAME//-/_}
Icon=$PACKAGE_NAME
Terminal=false
Categories=Network;Chat;
StartupWMClass=${APP_NAME//-/_}
EOF
    
    # Create control file
    cat > debian/DEBIAN/control <<EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $arch
Maintainer: Chuk <you@example.com>
Description: Flutter chat application
 A modern chat application built with Flutter.
EOF

    # Create postinst script for desktop integration
    cat > debian/DEBIAN/postinst <<'EOF'
#!/bin/bash
# Update desktop database
update-desktop-database /usr/share/applications
# Update icon cache
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
EOF

    # Create prerm script
    cat > debian/DEBIAN/prerm <<'EOF'
#!/bin/bash
# Update desktop database
update-desktop-database /usr/share/applications
# Update icon cache
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
EOF

    # Make scripts executable
    chmod +x debian/DEBIAN/postinst
    chmod +x debian/DEBIAN/prerm
    
    # Build deb package
    dpkg-deb --build debian "releases/linux/${PACKAGE_NAME}_${VERSION}_${arch}.deb"
    
    print_success "Created ${PACKAGE_NAME}_${VERSION}_${arch}.deb"
}

# Create rpm package
create_rpm() {
    local arch=$1
    print_info "Creating .rpm package for $arch..."
    
    # Check if rpmbuild is available
    if ! command -v rpmbuild &> /dev/null; then
        print_warning "rpmbuild not found. Skipping RPM package creation."
        print_info "Install rpm-build package to create RPM packages: sudo apt install rpm (Ubuntu/Debian) or sudo yum install rpm-build (RHEL/CentOS)"
        return 0
    fi
    
    # Create directory structure
    mkdir -p rpm/BUILD rpm/RPMS rpm/SOURCES rpm/SPECS rpm/SRPMS
    
    # Copy Flutter build to sources
    mkdir -p "rpm/SOURCES/$PACKAGE_NAME-$VERSION"
    if [ "$arch" = "amd64" ]; then
        cp -r build/linux/x64/release/bundle/* "rpm/SOURCES/$PACKAGE_NAME-$VERSION/"
    else
        cp -r build/linux/arm64/release/bundle/* "rpm/SOURCES/$PACKAGE_NAME-$VERSION/"
    fi
    
    # Create tarball
    cd rpm/SOURCES
    tar -czf "$PACKAGE_NAME-$VERSION.tar.gz" "$PACKAGE_NAME-$VERSION"
    cd ../..
    
    # Create spec file
    cat > "rpm/SPECS/$PACKAGE_NAME.spec" <<EOF
Name: $PACKAGE_NAME
Version: $VERSION
Release: 1%{?dist}
Summary: Flutter chat application
License: MIT
URL: https://github.com/yourusername/$PACKAGE_NAME
Source0: %{name}-%{version}.tar.gz
BuildArch: $arch
Requires: glibc

%description
A modern chat application built with Flutter.

%prep
%setup -q

%build
# No build step needed for pre-built binary

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/local/bin/%{name}
cp -r * %{buildroot}/usr/local/bin/%{name}/

%files
/usr/local/bin/%{name}/

%post
# Create desktop entry
mkdir -p /usr/share/applications
cat > /usr/share/applications/chuk-chat.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Chuk Chat
Comment=Modern chat application
Exec=/usr/local/bin/chuk-chat/chuk_chat
Icon=/usr/local/bin/chuk-chat/data/flutter_assets/assets/icons/icon.png
Terminal=false
Categories=Network;Chat;
DESKTOP
chmod +x /usr/local/bin/chuk-chat/chuk_chat
update-desktop-database /usr/share/applications

%preun
# Remove desktop entry
rm -f /usr/share/applications/chuk-chat.desktop
update-desktop-database /usr/share/applications

%changelog
* $(date '+%a %b %d %Y') Chuk <you@example.com> - $VERSION-1
- Initial package
EOF

    # Build RPM
    rpmbuild --define "_topdir $(pwd)/rpm" -ba "rpm/SPECS/$PACKAGE_NAME.spec"
    
    # Move the built RPM to releases directory
    find rpm/RPMS -name "*.rpm" -exec cp {} "releases/linux/${PACKAGE_NAME}_${VERSION}_${arch}.rpm" \;
    
    print_success "Created ${PACKAGE_NAME}_${VERSION}_${arch}.rpm"
}

# Create AppImage
create_appimage() {
    local arch=$1
    print_info "Creating AppImage for $arch..."
    
    # Check if appimagetool is available
    if ! command -v appimagetool &> /dev/null; then
        print_warning "appimagetool not found. Skipping AppImage creation."
        print_info "Download from: https://github.com/AppImage/AppImageKit/releases"
        return 0
    fi
    
    # Create AppDir structure
    mkdir -p "AppDir/usr/bin"
    mkdir -p "AppDir/usr/share/applications"
    mkdir -p "AppDir/usr/share/icons/hicolor/256x256/apps"
    
    # Copy Flutter build
    if [ "$arch" = "amd64" ]; then
        cp -r build/linux/x64/release/bundle/* "AppDir/usr/bin/"
    else
        cp -r build/linux/arm64/release/bundle/* "AppDir/usr/bin/"
    fi
    
    # Fix permissions
    chmod +x AppDir/usr/bin/chuk_chat
    
    # Copy app icon if available
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        cp "$ICON_PATH" "AppDir/usr/share/icons/hicolor/256x256/apps/chuk-chat.png"
    fi
    
    # Create desktop file
    cat > AppDir/usr/share/applications/chuk-chat.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Chuk Chat
Comment=Modern chat application
Exec=usr/bin/chuk_chat
Icon=chuk-chat
Terminal=false
Categories=Network;Chat;
StartupWMClass=chuk_chat
EOF
    
    # Create AppRun
    cat > AppDir/AppRun <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
exec ./usr/bin/chuk_chat "$@"
EOF
    chmod +x AppDir/AppRun
    
    # Create AppImage
    appimagetool AppDir "releases/linux/${PACKAGE_NAME}_${VERSION}_${arch}.AppImage"
    
    print_success "Created ${PACKAGE_NAME}_${VERSION}_${arch}.AppImage"
}

# Build Android APKs with split-per-abi
build_android() {
    print_info "Building Android APKs with split-per-abi (with tree-shaking - desktop code excluded)..."

    # Build with split-per-abi and optimizations
    if flutter build apk --release --split-per-abi \
        --dart-define=PLATFORM_MOBILE=true \
        --tree-shake-icons \
        --split-debug-info=build/android-debug-info \
        --obfuscate; then
        # Copy APKs to releases directory
        mkdir -p releases/android

        # Copy all generated APKs
        for apk in build/app/outputs/flutter-apk/app-*-release.apk; do
            if [ -f "$apk" ]; then
                # Extract architecture from filename
                filename=$(basename "$apk")
                arch=$(echo "$filename" | sed 's/app-\(.*\)-release.apk/\1/')
                cp "$apk" "releases/android/${PACKAGE_NAME}_${VERSION}_${arch}.apk"
                print_success "Created ${PACKAGE_NAME}_${VERSION}_${arch}.apk (desktop code tree-shaken)"
            fi
        done
    else
        print_warning "Android build failed"
    fi
}

# Main build functions
build_linux_packages() {
    print_header "Building Linux packages..."
    for arch in amd64 arm64; do
        print_header "Building Linux for architecture: $arch"
        
        if build_linux $arch; then
            create_deb $arch
            create_rpm $arch
            create_appimage $arch
            
            # Clean up for next architecture
            rm -rf debian rpm AppDir
        else
            print_warning "Skipping Linux packages for $arch due to build failure"
        fi
    done
}

build_deb_packages() {
    print_header "Building DEB packages..."
    for arch in amd64 arm64; do
        print_header "Building DEB for architecture: $arch"
        
        if build_linux $arch; then
            create_deb $arch
            rm -rf debian
        else
            print_warning "Skipping DEB package for $arch due to build failure"
        fi
    done
}

build_rpm_packages() {
    print_header "Building RPM packages..."
    for arch in amd64 arm64; do
        print_header "Building RPM for architecture: $arch"
        
        if build_linux $arch; then
            create_rpm $arch
            rm -rf rpm
        else
            print_warning "Skipping RPM package for $arch due to build failure"
        fi
    done
}

build_appimage_packages() {
    print_header "Building AppImage packages..."
    for arch in amd64 arm64; do
        print_header "Building AppImage for architecture: $arch"
        
        if build_linux $arch; then
            create_appimage $arch
            rm -rf AppDir
        else
            print_warning "Skipping AppImage for $arch due to build failure"
        fi
    done
}

# Show usage
show_usage() {
    echo "Usage: $0 [target]"
    echo ""
    echo "Targets:"
    echo "  linux    - Build all Linux packages (DEB, RPM, AppImage)"
    echo "  deb      - Build DEB packages only"
    echo "  rpm      - Build RPM packages only"
    echo "  appimage - Build AppImage packages only"
    echo "  apk      - Build Android APKs with split-per-abi"
    echo "  all      - Build everything (Linux + Android)"
    echo ""
    echo "Examples:"
    echo "  $0 linux    # Build all Linux packages"
    echo "  $0 deb      # Build DEB packages only"
    echo "  $0 apk      # Build Android APKs"
    echo "  $0 all      # Build everything"
}

# Main execution
main() {
    local target=${1:-"all"}
    
    print_header "Starting build process for $APP_NAME..."
    
    extract_app_info
    find_app_icon
    cleanup
    
    case $target in
        "linux")
            build_linux_packages
            ;;
        "deb")
            build_deb_packages
            ;;
        "rpm")
            build_rpm_packages
            ;;
        "appimage")
            build_appimage_packages
            ;;
        "apk")
            build_android
            ;;
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
    
    print_success "Build completed! All packages are in the releases/ directory:"
    echo ""
    print_info "Linux packages:"
    ls -la releases/linux/ 2>/dev/null || echo "  No Linux packages found"
    echo ""
    print_info "Android packages:"
    ls -la releases/android/ 2>/dev/null || echo "  No Android packages found"
    
    print_info "Package summary:"
    echo "  📦 Linux DEB packages: $(ls releases/linux/*.deb 2>/dev/null | wc -l) files"
    echo "  📦 Linux RPM packages: $(ls releases/linux/*.rpm 2>/dev/null | wc -l) files"
    echo "  📦 Linux AppImages: $(ls releases/linux/*.AppImage 2>/dev/null | wc -l) files"
    echo "  📱 Android APKs: $(ls releases/android/*.apk 2>/dev/null | wc -l) files"
}

# Check dependencies
check_dependencies() {
    print_info "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v flutter &> /dev/null; then
        missing_deps+=("flutter")
    fi
    
    if ! command -v dpkg-deb &> /dev/null; then
        missing_deps+=("dpkg-deb")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_error "Please install the missing dependencies and try again."
        exit 1
    fi
    
    print_success "All required dependencies found"
}

# Run the script
check_dependencies
main "$@"
