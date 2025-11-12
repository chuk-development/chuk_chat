# chuk_chat

A secure, cross-platform chat application built with Flutter that puts privacy first. Chat with open-weight AI models while keeping your conversations encrypted and under your control.

**Our Philosophy**: We exclusively support open-weight models. We believe in transparency, accessibility, and the freedom to run AI models independently. Closed-source models have no place in our ecosystem.

## Features

### Core Features

- **End-to-End Encryption**: All your chats are encrypted client-side with AES-256-GCM before being stored or synced
- **Cross-Platform**: Works seamlessly on Windows, macOS, Linux, Android, and iOS
- **Open-Weight AI Models**: Access to various open-weight models including DeepSeek, Llama, Mistral, Qwen, and more
- **Real-Time Streaming**: Watch AI responses appear in real-time as they're generated
- **Offline Support**: Access your chat history even when offline
- **File Attachments**: Share images and documents with AI (PDF, images, text files)
- **Theme Customization**: Personalize colors, backgrounds, and visual effects

### Security Features

- **Client-Side Encryption**: Messages are encrypted on your device before leaving it
- **Certificate Pinning**: Protection against man-in-the-middle attacks in production
- **Strong Password Requirements**: Enforced 12+ character passwords with complexity requirements
- **Rate Limiting**: Built-in protections against API abuse
- **Input Validation**: All inputs are sanitized to prevent injection attacks
- **Secure Token Handling**: Session tokens are properly masked in logs

For detailed security information, see [SECURITY.md](SECURITY.md).

### User Interface

- **Platform-Adaptive UI**: Optimized layouts for desktop and mobile
- **Dark/Light Mode**: Switch between themes based on your preference
- **Film Grain Overlay**: Optional visual effect for a unique aesthetic
- **Message History**: Search and browse your previous conversations
- **Starred Chats**: Mark important conversations for quick access

## Important: Password Security

⚠️ **If you lose your password, all your chats are permanently lost and cannot be recovered by anyone.**

Your chats are encrypted with your password on your device. We can send you the encrypted chat data if needed, but it will remain encrypted and unreadable without your password. There is no password recovery mechanism by design - this ensures maximum privacy and security.

**Choose a strong password and store it safely.**

## Privacy & Data

### What Data is Encrypted

- All chat messages (sent and received)
- Chat titles and metadata
- Starred chat status
- Timestamps and message history

### Where is Data Stored

- **Local Device**: Encrypted chat history is cached locally for offline access
- **Supabase Cloud**: Encrypted chats are synced to the cloud (still encrypted)
- **Your Encryption Key**: Stored securely in your device's keychain/keystore

Your encryption key never leaves your device. Even if the server is compromised, your chats remain encrypted.

---

## Development

This section is for developers who want to build, modify, or contribute to chuk_chat.

### Prerequisites

- **Flutter SDK**: Version 3.24.0 or higher
- **Dart SDK**: Version 3.5.0 or higher (comes with Flutter)

**Platform-Specific Requirements:**

- **Android**: Android Studio, Android SDK (API 36), Android NDK 26.3.11579264+
- **iOS**: Xcode (latest stable), macOS required for iOS builds
- **Windows**: Visual Studio 2022 or later with Desktop development with C++ workload
- **macOS**: Xcode command line tools
- **Linux**:
  - `dpkg-dev` (for DEB packages)
  - `rpm` (for RPM packages, optional)
  - `appimagetool` (for AppImage packages, optional)

### Development Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/chuk_chat.git
   cd chuk_chat
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Configure Supabase** (optional, for local development)
   - Create a `.env` file or set environment variables:
     ```bash
     export SUPABASE_URL="your_supabase_url"
     export SUPABASE_ANON_KEY="your_anon_key"
     ```
   - Or modify `lib/supabase_config.dart` directly (not recommended for production)

4. **Run the app**
   ```bash
   # Auto-detect platform
   flutter run

   # Run on specific platform
   flutter run -d windows
   flutter run -d macos
   flutter run -d linux
   flutter run -d android
   flutter run -d ios

   # Run with platform optimization (tree-shaking)
   flutter run -d windows --dart-define=PLATFORM_DESKTOP=true
   flutter run -d macos --dart-define=PLATFORM_DESKTOP=true
   flutter run -d linux --dart-define=PLATFORM_DESKTOP=true
   flutter run -d android --dart-define=PLATFORM_MOBILE=true
   flutter run -d ios --dart-define=PLATFORM_MOBILE=true
   ```

### Building for Release

#### Quick Build (Development/Testing)

For fast iteration during development:

```bash
# Desktop platforms (optimized with tree-shaking)
flutter build windows --dart-define=PLATFORM_DESKTOP=true --tree-shake-icons
flutter build macos --dart-define=PLATFORM_DESKTOP=true --tree-shake-icons
flutter build linux --dart-define=PLATFORM_DESKTOP=true --tree-shake-icons

# Mobile platforms (optimized with tree-shaking)
flutter build apk --dart-define=PLATFORM_MOBILE=true --tree-shake-icons --target-platform android-arm64  # Fast single-arch build
flutter build ios --dart-define=PLATFORM_MOBILE=true --tree-shake-icons  # Requires macOS
```

#### Full Release Builds

Use the unified build script for production releases:

```bash
# Build everything (Linux + Android)
./build.sh all

# Build specific targets
./build.sh linux      # All Linux packages (DEB, RPM, AppImage)
./build.sh deb        # DEB only (amd64 + arm64)
./build.sh rpm        # RPM only (amd64 + arm64)
./build.sh appimage   # AppImage only (amd64 + arm64)
./build.sh apk        # Android APKs (all architectures, ~2 minutes)
```

Output location:
- Linux packages: `releases/linux/`
- Android APKs: `releases/android/`

For detailed build instructions, see [BUILD.md](BUILD.md).

### Project Structure

```
lib/
├── main.dart                     # App entry point
├── constants.dart                # Theme constants and builders
├── platform_config.dart          # Platform detection and tree-shaking config
├── supabase_config.dart          # Supabase configuration
├── models/                       # Data models
│   ├── model_item.dart
│   ├── attached_file.dart
│   └── chat_stream_event.dart
├── pages/                        # App screens
│   ├── login_page.dart
│   ├── settings_page.dart
│   └── ...
├── platform_specific/            # Platform-adaptive UI
│   ├── root_wrapper.dart         # Conditional import wrapper
│   ├── root_wrapper_io.dart      # Platform detection logic
│   ├── root_wrapper_desktop.dart # Desktop layout
│   ├── root_wrapper_mobile.dart  # Mobile layout
│   ├── sidebar_desktop.dart
│   ├── sidebar_mobile.dart
│   └── chat/
│       ├── chat_ui_desktop.dart
│       └── chat_ui_mobile.dart
├── services/                     # Business logic and API
│   ├── auth_service.dart
│   ├── encryption_service.dart
│   ├── chat_storage_service.dart
│   ├── streaming_chat_service.dart
│   ├── websocket_chat_service.dart
│   ├── file_conversion_service.dart
│   └── ...
├── utils/                        # Utilities and helpers
│   ├── input_validator.dart
│   ├── file_upload_validator.dart
│   ├── certificate_pinning.dart
│   ├── api_rate_limiter.dart
│   ├── secure_token_handler.dart
│   └── ...
└── widgets/                      # Reusable UI components
    ├── password_strength_meter.dart
    └── ...
```

### Architecture Overview

**Platform Abstraction**:
- Uses conditional imports for platform-specific code
- Tree-shaking removes unused platform code at compile time
- Desktop builds exclude mobile code, Android builds exclude desktop code
- See `TREE_SHAKING.md` for details

**State Management**:
- Theme state: Managed at `ChukChatApp` level with `SharedPreferences` + Supabase sync
- Auth state: Managed via Supabase `auth.onAuthStateChange` stream
- Chat state: Managed in `ChatStorageService` with encrypted local storage

**Services Architecture**:
- Singleton-like pattern with static methods or const constructors
- Services initialized in `main.dart` as needed
- Encryption service loaded on login
- Theme settings synced bidirectionally between local and cloud

For detailed architecture documentation, see [CLAUDE.md](CLAUDE.md).

### Code Quality

```bash
# Analyze code for issues
flutter analyze

# Format code
dart format .

# Run tests (when available)
flutter test

# Run with coverage
flutter test --coverage
```

### Common Development Tasks

#### Adding a New Service

1. Create service file in `lib/services/`
2. Use const constructor or static methods
3. Initialize in `main.dart` if needed at startup
4. Update platform-specific UIs if service affects UI

#### Adding a New Page

1. Create page in `lib/pages/`
2. Add navigation in appropriate sidebar (desktop/mobile)
3. Apply theme colors consistently using `Theme.of(context)`
4. Test on both platforms

#### Modifying Theme System

1. Update `lib/constants.dart` for new properties
2. Add state management in `_ChukChatAppState`
3. Update `ThemeSettings` model in `ThemeSettingsService`
4. Update Supabase schema if server-synced
5. Pass new callbacks to root wrappers

#### Testing Security Features

1. Build in release mode: `flutter build apk --release`
2. Test certificate pinning (enabled in production only)
3. Test rate limiting with real API calls
4. Test file upload validation with edge cases
5. Test input validation with malicious inputs

### Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run `flutter analyze` and `dart format .`
5. Test on both desktop and mobile if applicable
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

Please ensure your PR:
- Follows existing code style
- Includes comments for complex logic
- Updates documentation if needed
- Doesn't introduce security vulnerabilities
- Passes `flutter analyze` without errors

### Security Considerations for Developers

- Never commit API keys or secrets
- Use environment variables for sensitive configuration
- Wrap debug logging in `kDebugMode` checks
- Use existing validation utilities for new inputs
- Test security features in both debug and release modes
- See [SECURITY.md](SECURITY.md) for detailed guidelines

### Dependency Management

Major dependencies:
- `supabase_flutter`: Backend and authentication
- `dio`: HTTP client with certificate pinning support
- `flutter_secure_storage`: Secure key storage
- `cryptography`: AES-256-GCM encryption
- `shared_preferences`: Local settings storage
- `archive`: Zip bomb detection
- `file_picker`: File selection
- `image_picker`: Image selection

Update dependencies:
```bash
flutter pub upgrade
flutter pub outdated  # Check for updates
```

### Debugging

Enable debug logging:
```dart
// Already enabled in debug mode via kDebugMode checks
// Logs appear in console when running with flutter run
```

Common debug tasks:
```bash
# View real-time logs
flutter logs

# Clear build cache
flutter clean

# Rebuild from scratch
flutter clean && flutter pub get && flutter run
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Built with [Flutter](https://flutter.dev)
- Backend powered by [Supabase](https://supabase.com)
- Open-weight AI models accessed via [OpenRouter](https://openrouter.ai)
