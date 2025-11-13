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
Builds Android APKs with mobile UI using `--split-per-abi`:
- `chuk-chat_1.0.1_arm64-v8a.apk`
- `chuk-chat_1.0.1_armeabi-v7a.apk`
- `chuk-chat_1.0.1_x86_64.apk`

### `./build.sh apk-desktop`
Builds Android APKs with desktop UI mode (optimized for tablets) using `--split-per-abi`:
- `chuk-chat_1.0.1_arm64-v8a_desktop.apk`
- `chuk-chat_1.0.1_armeabi-v7a_desktop.apk`
- `chuk-chat_1.0.1_x86_64_desktop.apk`

**Note**: The desktop UI mode uses the desktop layout interface, which is better suited for tablets with larger screens. The mobile-specific code is tree-shaken out for smaller APK size.

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

### Android Development Requirements

#### Environment Variables
```bash
# Set Android SDK home
export ANDROID_HOME=/path/to/android-sdk

# Add Android tools to PATH
export PATH=$PATH:$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools
```

#### Minimum Version Requirements
- **compileSdkVersion**: 36
- **minSdkVersion**: 24
- **targetSdkVersion**: 36
- **ndkVersion**: 26.3.11579264 or newer
- **Android Gradle Plugin**: 8.1.0+

#### SDK/NDK Installation
Android SDK and NDK can be installed via:
- **Android Studio**: Recommended for GUI-based development
- **Command Line Tools**: For CI/CD and headless environments

#### NDK Version Conflicts
If you encounter NDK version conflicts with plugins, override the NDK version in `android/app/build.gradle`:
```gradle
android {
    ndkVersion "26.3.11579264"
}
```

#### Flutter Android Setup
For detailed setup instructions and compatibility information, refer to the [official Flutter Android setup guide](https://docs.flutter.dev/get-started/install/linux#android-setup).

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
# Quick Android build (mobile UI)
./build.sh apk

# Android build with desktop UI for tablets
./build.sh apk-desktop

# Quick Linux DEB build
./build.sh deb

# Complete release build
./build.sh all

# Check what was built
ls -la releases/
```
