# Linux Builds with Fastlane

This document explains how to build all Linux distribution formats (Flatpak, AppImage, DEB, RPM) using Fastlane for chuk_chat.

## Overview

chuk_chat supports multiple Linux distribution formats:

| Format | Use Case | Distribution Method |
|--------|----------|-------------------|
| **Flatpak** | Modern sandboxed apps | Flathub, direct install |
| **AppImage** | Universal portable apps | Direct download |
| **DEB** | Debian/Ubuntu systems | APT repositories, direct install |
| **RPM** | Fedora/RHEL systems | DNF/YUM repositories, direct install |

All formats can be built using Fastlane for a consistent development experience.

## Prerequisites

### System Requirements

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev rpm fuse libfuse2 wget file \
  flatpak flatpak-builder \
  ruby-full

# Fedora
sudo dnf install -y \
  clang cmake ninja-build pkg-config gtk3-devel xz-devel \
  libstdc++-devel rpm fuse fuse-libs wget file \
  flatpak flatpak-builder \
  ruby ruby-devel

# Arch
sudo pacman -S \
  clang cmake ninja pkg-config gtk3 xz \
  rpm fuse2 wget file \
  flatpak flatpak-builder \
  ruby
```

### Install Flutter

Follow the [Flutter Linux installation guide](https://docs.flutter.dev/get-started/install/linux).

### Setup Fastlane

```bash
cd linux
bundle install
```

This installs Fastlane and all Ruby dependencies.

## Quick Start

### Build Everything (Full Release)

```bash
# Set environment variables
export SUPABASE_URL="your-supabase-url"
export SUPABASE_ANON_KEY="your-anon-key"

# Or use .env file
cp .env.example .env
# Edit .env with your credentials
source .env

# Build all formats
cd linux
bundle exec fastlane release
```

This will build:
- Flutter Linux binary
- Flatpak package and bundle
- AppImage
- DEB package
- RPM package

**Output files:**
- `chuk_chat-{version}-linux.flatpak`
- `chuk_chat-{version}-x86_64.AppImage`
- `chuk_chat_{version}_amd64.deb`
- `chuk_chat-{version}-1.x86_64.rpm`

## Fastlane Lanes

### Flatpak Lanes

```bash
cd linux

# Build Flatpak repository
bundle exec fastlane build_flatpak

# Build single-file .flatpak bundle
bundle exec fastlane build_flatpak_bundle

# Install locally for testing
bundle exec fastlane install_flatpak
```

### Traditional Package Lanes

```bash
cd linux

# Build AppImage
bundle exec fastlane build_appimage

# Build DEB package
bundle exec fastlane build_deb

# Build RPM package
bundle exec fastlane build_rpm
```

### Utility Lanes

```bash
cd linux

# Build just the Flutter binary (required for AppImage/DEB/RPM)
bundle exec fastlane build_flutter_linux

# Clean all build artifacts
bundle exec fastlane clean
```

## Detailed Usage

### Building Flatpak

Flatpak is built from the manifest file `dev.chuk.chat.yml` which includes Flutter SDK and all dependencies.

```bash
cd linux
bundle exec fastlane build_flatpak
```

**What it does:**
1. Checks if `flatpak-builder` is installed
2. Installs Freedesktop Platform 23.08 if needed
3. Downloads Flutter SDK (3.24.5 stable)
4. Builds the Flatpak using the manifest
5. Creates a local repository in `repo/`

**Testing:**
```bash
# Install locally
bundle exec fastlane install_flatpak

# Run
flatpak run dev.chuk.chat

# Uninstall
flatpak uninstall dev.chuk.chat
```

**Create distributable bundle:**
```bash
bundle exec fastlane build_flatpak_bundle
```

This creates a single `.flatpak` file users can install directly.

### Building AppImage

AppImage creates a portable executable that runs on any Linux distribution.

```bash
cd linux
bundle exec fastlane build_appimage
```

**What it does:**
1. Builds Flutter Linux binary if not present
2. Uses `scripts/package-linux.sh` to create AppImage
3. Downloads `appimagetool` if needed
4. Creates `chuk_chat-{version}-x86_64.AppImage`

**Testing:**
```bash
chmod +x chuk_chat-*.AppImage
./chuk_chat-*.AppImage
```

### Building DEB Package

DEB packages are for Debian-based distributions (Debian, Ubuntu, Linux Mint, etc.)

```bash
cd linux
bundle exec fastlane build_deb
```

**What it does:**
1. Builds Flutter Linux binary if not present
2. Creates DEB package structure
3. Builds `chuk_chat_{version}_amd64.deb`

**Testing:**
```bash
sudo dpkg -i chuk_chat_*.deb

# Run
chuk_chat

# Uninstall
sudo apt remove chuk_chat
```

### Building RPM Package

RPM packages are for Red Hat-based distributions (Fedora, RHEL, CentOS, openSUSE, etc.)

```bash
cd linux
bundle exec fastlane build_rpm
```

**What it does:**
1. Builds Flutter Linux binary if not present
2. Creates RPM package structure
3. Builds `chuk_chat-{version}-1.x86_64.rpm`

**Testing:**
```bash
sudo rpm -i chuk_chat-*.rpm

# Or on Fedora
sudo dnf install ./chuk_chat-*.rpm

# Run
chuk_chat

# Uninstall
sudo rpm -e chuk_chat
```

## Environment Variables

### Required for Building

```bash
SUPABASE_URL          # Your Supabase project URL
SUPABASE_ANON_KEY     # Your Supabase anonymous key
```

### Optional

```bash
# If not set, credentials will need to be configured at runtime
```

## CI/CD Integration

The GitHub Actions workflow `.github/workflows/release-linux.yml` uses Fastlane to build all Linux packages automatically on release tags.

### Manual Workflow Trigger

To build locally as CI does:

```bash
# Install all dependencies
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev rpm fuse libfuse2 wget file \
  flatpak flatpak-builder ruby-full

# Setup Flatpak runtimes
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo flatpak install -y flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08

# Get dependencies
flutter pub get
cd linux && bundle install

# Build everything
export SUPABASE_URL="your-url"
export SUPABASE_ANON_KEY="your-key"
bundle exec fastlane release
```

## Troubleshooting

### Flatpak: "flatpak-builder not found"

```bash
sudo apt install flatpak flatpak-builder
```

### Flatpak: "Freedesktop Platform not found"

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08
```

### AppImage: "appimagetool not found"

The build script downloads it automatically. If it fails:

```bash
wget -O appimagetool https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool
sudo mv appimagetool /usr/local/bin/
```

### DEB: "dpkg-deb not found"

```bash
sudo apt install dpkg-dev
```

### RPM: "rpmbuild not found"

```bash
# Ubuntu/Debian
sudo apt install rpm

# Fedora
sudo dnf install rpm-build
```

### Build Fails: "SUPABASE_URL not set"

Set environment variables or use `.env` file:

```bash
export SUPABASE_URL="your-url"
export SUPABASE_ANON_KEY="your-key"
```

Or:
```bash
cp .env.example .env
# Edit .env with credentials
source .env
```

### Clean Build

If you encounter issues, clean and rebuild:

```bash
cd linux
bundle exec fastlane clean
bundle exec fastlane release
```

## File Structure

```
chuk_chat/
├── linux/
│   ├── fastlane/
│   │   ├── Fastfile        # Lane definitions
│   │   └── Appfile         # App identifier
│   └── Gemfile             # Ruby dependencies
├── dev.chuk.chat.yml       # Flatpak manifest
├── build_flatpak.sh        # Standalone Flatpak script
├── flatpak/
│   ├── dev.chuk.chat.desktop      # Desktop entry
│   └── dev.chuk.chat.metainfo.xml # AppStream metadata
└── scripts/
    └── package-linux.sh    # AppImage/DEB/RPM packaging
```

## Distribution

### GitHub Releases

All formats are automatically uploaded to GitHub Releases by CI/CD:

```
https://github.com/your-org/chuk_chat/releases/latest
```

### Manual Distribution

**Flatpak:**
- Direct: Share the `.flatpak` file
- Flathub: Submit to Flathub following their [submission guide](https://docs.flathub.org/docs/for-app-authors/submission)

**AppImage:**
- Direct download from website/GitHub
- AppImageHub (community catalog)

**DEB:**
- APT repository (requires server setup)
- Direct download and `sudo dpkg -i`

**RPM:**
- DNF/YUM repository (requires server setup)
- Direct download and `sudo rpm -i`

## Version Management

Version is read from `pubspec.yaml`:

```yaml
version: 1.0.14+4012
```

Format: `MAJOR.MINOR.PATCH+BUILD`

All packages use this version automatically.

## Performance Notes

### Build Times (Approximate)

| Package | Build Time | Size |
|---------|-----------|------|
| Flutter Binary | 2-5 min | ~80 MB |
| Flatpak | 5-15 min | ~100 MB |
| AppImage | 1-2 min | ~90 MB |
| DEB | 1 min | ~80 MB |
| RPM | 1 min | ~80 MB |

**Full release:** ~15-20 minutes (parallel builds not implemented)

### Caching

Fastlane caches:
- Flutter SDK download (in Flatpak)
- Flatpak build artifacts (ccache enabled)
- Ruby gems (via bundler)

First build is slower, subsequent builds are faster.

## References

- [Fastlane Documentation](https://docs.fastlane.tools/)
- [Flatpak Documentation](https://docs.flatpak.org/)
- [AppImage Documentation](https://docs.appimage.org/)
- [Debian Package Guide](https://www.debian.org/doc/manuals/maint-guide/)
- [RPM Packaging Guide](https://rpm-packaging-guide.github.io/)
- [Flutter Linux Desktop](https://docs.flutter.dev/platform-integration/linux)
