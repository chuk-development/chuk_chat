#!/bin/bash
# build-release.sh - Build local releases (Android, Linux, Web)
# Usage: ./scripts/build-release.sh [android|linux|web|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Load environment variables
if [ -f ".env" ]; then
    source .env
else
    echo "ERROR: .env file not found!"
    echo "Copy .env.example to .env and fill in your credentials"
    exit 1
fi

# Check required env vars
if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
    echo "ERROR: SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env"
    exit 1
fi

# Get version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
echo "Building version: $VERSION"

# Common dart-defines
DART_DEFINES="--dart-define=SUPABASE_URL=$SUPABASE_URL \
    --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
    --dart-define=FEATURE_PROJECTS=true \
    --dart-define=FEATURE_IMAGE_GEN=true \
    --dart-define=FEATURE_VOICE_MODE=true"

build_android() {
    echo ""
    echo "=========================================="
    echo "Building Android APK..."
    echo "=========================================="

    flutter build apk --release \
        $DART_DEFINES \
        --dart-define=PLATFORM_MOBILE=true \
        --tree-shake-icons

    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    APK_SIZE=$(du -h "$APK_PATH" | cut -f1)

    echo "Android APK built: $APK_PATH ($APK_SIZE)"
}

build_linux() {
    echo ""
    echo "=========================================="
    echo "Building Linux..."
    echo "=========================================="

    flutter build linux --release $DART_DEFINES --tree-shake-icons

    # Create tarball
    cd build/linux/x64/release/bundle
    tar -czf "../../../../../chuk_chat-$VERSION-linux-x64.tar.gz" *
    cd "$PROJECT_DIR"

    TARBALL="chuk_chat-$VERSION-linux-x64.tar.gz"
    TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)

    echo "Linux tarball built: $TARBALL ($TARBALL_SIZE)"
}

build_web() {
    echo ""
    echo "=========================================="
    echo "Building Web..."
    echo "=========================================="

    flutter build web --release $DART_DEFINES

    # Create ZIP
    cd build/web
    zip -r "../../chuk_chat-$VERSION-web.zip" *
    cd "$PROJECT_DIR"

    ZIP="chuk_chat-$VERSION-web.zip"
    ZIP_SIZE=$(du -h "$ZIP" | cut -f1)

    echo "Web ZIP built: $ZIP ($ZIP_SIZE)"
}

show_summary() {
    echo ""
    echo "=========================================="
    echo "BUILD SUMMARY"
    echo "=========================================="
    echo "Version: $VERSION"
    echo ""

    [ -f "build/app/outputs/flutter-apk/app-release.apk" ] && \
        echo "Android: build/app/outputs/flutter-apk/app-release.apk"

    [ -f "chuk_chat-$VERSION-linux-x64.tar.gz" ] && \
        echo "Linux:   chuk_chat-$VERSION-linux-x64.tar.gz"

    [ -f "chuk_chat-$VERSION-web.zip" ] && \
        echo "Web:     chuk_chat-$VERSION-web.zip"

    echo ""
    echo "To upload to GitHub Release:"
    echo "  gh release upload v$VERSION <files>"
    echo ""
    echo "CI builds (Windows/iOS) triggered automatically on tag push."
}

# Main
case "${1:-all}" in
    android)
        build_android
        ;;
    linux)
        build_linux
        ;;
    web)
        build_web
        ;;
    all)
        build_android
        build_linux
        build_web
        show_summary
        ;;
    *)
        echo "Usage: $0 [android|linux|web|all]"
        exit 1
        ;;
esac
