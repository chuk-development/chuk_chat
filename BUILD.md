# Build System for chuk_chat

## 🚀 Quick Start

```bash
# Build everything (Linux + Android)
./build.sh all

# Build specific targets
./build.sh linux    # All Linux packages (DEB, RPM, AppImage)
./build.sh deb      # DEB packages only
./build.sh rpm      # RPM packages only
./build.sh appimage # AppImage packages only
./build.sh apk      # Android APKs with split-per-abi
```

## 📦 Available Targets

### `./build.sh linux`
Builds all Linux packages:
- DEB packages for amd64 and arm64
- RPM packages for amd64 and arm64  
- AppImage packages for amd64 and arm64

### `./build.sh deb`
Builds DEB packages only:
- `chuk-chat_1.0.1_amd64.deb`
- `chuk-chat_1.0.1_arm64.deb` (if supported)

### `./build.sh rpm`
Builds RPM packages only:
- `chuk-chat_1.0.1_amd64.rpm`
- `chuk-chat_1.0.1_arm64.rpm` (if supported)

### `./build.sh appimage`
Builds AppImage packages only:
- `chuk-chat_1.0.1_amd64.AppImage`
- `chuk-chat_1.0.1_arm64.AppImage` (if supported)

### `./build.sh apk`
Builds Android APKs using `--split-per-abi`:
- `chuk-chat_1.0.1_arm64-v8a.apk`
- `chuk-chat_1.0.1_armeabi-v7a.apk`
- `chuk-chat_1.0.1_x86_64.apk`

### `./build.sh all`
Builds everything (Linux + Android packages)

## 📁 Output Structure

```
releases/
├── linux/                    # Linux packages
│   ├── chuk-chat_1.0.1_amd64.deb
│   ├── chuk-chat_1.0.1_arm64.deb
│   ├── chuk-chat_1.0.1_amd64.rpm
│   ├── chuk-chat_1.0.1_arm64.rpm
│   ├── chuk-chat_1.0.1_amd64.AppImage
│   └── chuk-chat_1.0.1_arm64.AppImage
└── android/                  # Android packages
    ├── chuk-chat_1.0.1_arm64-v8a.apk
    ├── chuk-chat_1.0.1_armeabi-v7a.apk
    └── chuk-chat_1.0.1_x86_64.apk
```

## ✨ Features

- **🔧 Unified Interface**: Single script for all build types
- **📱 Split APKs**: Uses `--split-per-abi` for optimal Android builds
- **🖥️ Desktop Integration**: Proper .desktop files with app icons
- **🎨 Icon Support**: Automatically uses current app icon
- **📦 Multi-Architecture**: Supports amd64, arm64, and Android architectures
- **🛡️ Error Handling**: Graceful fallbacks and clear error messages
- **📋 Git Ignore**: Build artifacts automatically ignored

## 🛠️ Prerequisites

### Required Dependencies
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install dpkg-dev

# For RPM packages (optional)
sudo apt install rpm

# For AppImage (optional)
# Download from: https://github.com/AppImage/AppImageKit/releases
```

### Flutter Setup
```bash
flutter doctor
```

## 🎯 Key Improvements

1. **Single Build Script**: No more multiple scripts to manage
2. **Split APKs**: Uses `flutter build apk --release --split-per-abi` for optimal Android builds
3. **Git Ignore**: All build artifacts are automatically ignored
4. **Targeted Builds**: Build only what you need
5. **Desktop Integration**: Proper launcher integration with icons

## 🔍 Troubleshooting

### Permission Issues
```bash
# Fix permissions and create desktop integration
cd build_release
./install_app.sh
```

### Missing Dependencies
```bash
# Install required packages
sudo apt install dpkg-dev
```

### Build Failures
```bash
# Clean and rebuild
flutter clean
./build.sh [target]
```

## 📝 Examples

```bash
# Quick Android build
./build.sh apk

# Quick Linux DEB build
./build.sh deb

# Complete release build
./build.sh all

# Check what was built
ls -la releases/
```
