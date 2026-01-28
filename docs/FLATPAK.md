# Flatpak Packaging for chuk_chat

This document explains how to build and distribute chuk_chat as a Flatpak package for Linux desktop.

## Quick Start

```bash
# Build and install locally
./build_flatpak.sh --install

# Run the app
flatpak run dev.chuk.chat
```

## Prerequisites

### Install Flatpak Tools

```bash
# Ubuntu/Debian
sudo apt install flatpak flatpak-builder

# Fedora
sudo dnf install flatpak flatpak-builder

# Arch
sudo pacman -S flatpak flatpak-builder
```

### Add Flathub Repository (if not already added)

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

### Install Required Runtimes

```bash
flatpak install flathub org.freedesktop.Platform//23.08
flatpak install flathub org.freedesktop.Sdk//23.08
```

## Building

### Option 1: Using Fastlane (Recommended for Development)

Fastlane provides a unified interface for building all Linux packages including Flatpak:

```bash
# Install dependencies (first time only)
cd linux
bundle install

# Build Flatpak only
bundle exec fastlane build_flatpak

# Build Flatpak bundle (.flatpak file)
bundle exec fastlane build_flatpak_bundle

# Install locally for testing
bundle exec fastlane install_flatpak

# Build all Linux packages (Flatpak, AppImage, DEB, RPM)
bundle exec fastlane release

# Clean all build artifacts
bundle exec fastlane clean
```

**Available Fastlane Lanes:**
- `build_flatpak` - Build Flatpak repository
- `build_flatpak_bundle` - Create single-file .flatpak bundle
- `install_flatpak` - Install Flatpak locally for testing
- `build_appimage` - Build AppImage package
- `build_deb` - Build DEB package
- `build_rpm` - Build RPM package
- `build_flutter_linux` - Build Flutter Linux binary
- `release` - Build all Linux packages at once
- `clean` - Remove all build artifacts

### Option 2: Using Build Script (Quick Method)

```bash
# Just build
./build_flatpak.sh

# Build and install locally
./build_flatpak.sh --install

# Build and create distributable bundle
./build_flatpak.sh --bundle
```

### Option 3: Manual Build

```bash
# Build the Flatpak
flatpak-builder --force-clean --ccache --repo=repo build-dir dev.chuk.chat.yml

# Install locally
flatpak --user remote-add --if-not-exists --no-gpg-verify chuk-chat-repo repo
flatpak --user install chuk-chat-repo dev.chuk.chat

# Run
flatpak run dev.chuk.chat
```

## Environment Variables

The app requires Supabase credentials to function. There are two ways to provide them:

### 1. Build-time Configuration (Recommended)

Create a `.env` file in the project root:

```bash
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
```

The build script will automatically include these during the build process.

### 2. Runtime Configuration

If you build without credentials, users will need to configure them at runtime through the app's settings.

## Testing

### Quick Test Run

```bash
# Test without installing
flatpak-builder --run build-dir dev.chuk.chat.yml chuk_chat_launcher.sh
```

### Full Test

```bash
# Install locally
./build_flatpak.sh --install

# Run
flatpak run dev.chuk.chat

# Check logs
flatpak run dev.chuk.chat --verbose

# Uninstall
flatpak uninstall dev.chuk.chat
```

## Distribution

### Create Single-File Bundle

```bash
./build_flatpak.sh --bundle
```

This creates `chuk_chat.flatpak` which users can install with:

```bash
flatpak install chuk_chat.flatpak
```

### Publish to Flathub

To publish on Flathub:

1. Fork the [flathub/flathub](https://github.com/flathub/flathub) repository
2. Create a new repository named `dev.chuk.chat`
3. Add the manifest files:
   - `dev.chuk.chat.yml`
   - `flatpak/dev.chuk.chat.desktop`
   - `flatpak/dev.chuk.chat.metainfo.xml`
4. Submit a PR to Flathub following their [submission guidelines](https://docs.flathub.org/docs/for-app-authors/submission)

## File Structure

```
chuk_chat/
├── dev.chuk.chat.yml              # Main Flatpak manifest
├── build_flatpak.sh               # Build script
├── flatpak/
│   ├── dev.chuk.chat.desktop      # Desktop entry file
│   └── dev.chuk.chat.metainfo.xml # AppStream metadata
└── docs/
    └── FLATPAK.md                 # This file
```

## Permissions

The Flatpak has the following permissions (defined in `dev.chuk.chat.yml`):

- **Network**: Required for Supabase and AI chat (`--share=network`)
- **Display**: Wayland and X11 support (`--socket=wayland`, `--socket=fallback-x11`)
- **Graphics**: OpenGL for Flutter (`--device=dri`)
- **Audio**: For voice mode (`--socket=pulseaudio`)
- **File Access**: Downloads, documents, pictures via portals
- **Notifications**: Desktop notifications (`--talk-name=org.freedesktop.Notifications`)
- **Storage**: App data directory (`--filesystem=xdg-data/chuk_chat:create`)

## Troubleshooting

### Build Fails with "Flutter not found"

The manifest downloads Flutter automatically. If it fails:

1. Check internet connection
2. Verify the Flutter URL and SHA256 in `dev.chuk.chat.yml`
3. Try updating to the latest stable Flutter version

### Runtime Errors

```bash
# Check logs
flatpak run dev.chuk.chat --verbose

# Enter the sandbox for debugging
flatpak run --command=sh dev.chuk.chat
```

### Permission Issues

If the app can't access files or network:

1. Check permissions in `dev.chuk.chat.yml` (`finish-args` section)
2. Grant additional permissions:
   ```bash
   flatpak override --user --filesystem=home dev.chuk.chat
   ```

### Clean Build

```bash
# Remove all build artifacts
rm -rf build-dir .flatpak-builder repo

# Rebuild
./build_flatpak.sh
```

## Updating

To update the Flatpak after code changes:

```bash
# Rebuild and reinstall
./build_flatpak.sh --install

# Or update if already installed
flatpak update dev.chuk.chat
```

## CI/CD Integration

For GitHub Actions or other CI systems:

```yaml
- name: Install Flatpak tools
  run: |
    sudo apt-get update
    sudo apt-get install -y flatpak flatpak-builder
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08

- name: Build Flatpak
  run: ./build_flatpak.sh --bundle

- name: Upload artifact
  uses: actions/upload-artifact@v3
  with:
    name: chuk_chat-flatpak
    path: chuk_chat.flatpak
```

## Notes

- The Flatpak uses the stable Flutter channel (currently 3.24.5)
- All dependencies are fetched during build time
- The app runs in a sandboxed environment for security
- File picker uses XDG portals for proper sandboxing
- Secure storage is handled via the `flutter_secure_storage` plugin

## References

- [Flatpak Documentation](https://docs.flatpak.org/)
- [Flathub Submission Guide](https://docs.flathub.org/docs/for-app-authors/submission)
- [Flutter on Linux](https://docs.flutter.dev/get-started/install/linux)
- [AppStream Specification](https://www.freedesktop.org/software/appstream/docs/)
