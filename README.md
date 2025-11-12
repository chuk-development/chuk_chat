# chuk_chat

A secure, cross-platform chat application built with Flutter that puts privacy first. Chat with AI models while keeping your conversations encrypted and under your control.

## Features

### Core Features

- **End-to-End Encryption**: All your chats are encrypted client-side with AES-256-GCM before being stored or synced
- **Cross-Platform**: Works seamlessly on Linux (DEB, RPM, AppImage) and Android (APK)
- **Multiple AI Models**: Choose from various AI models including Claude, GPT-4, DeepSeek, and more
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

## Installation

### Android

1. Download the latest APK from the [Releases](releases/android/) page
2. Choose the APK for your device architecture:
   - `chuk_chat-arm64-v8a.apk` - Most modern Android phones (64-bit)
   - `chuk_chat-armeabi-v7a.apk` - Older Android phones (32-bit)
   - `chuk_chat-x86_64.apk` - Android emulators and x86 devices
3. Install the APK (you may need to enable "Install from Unknown Sources" in your device settings)
4. Open the app and sign up or sign in

### Linux

#### Debian/Ubuntu (DEB)

```bash
# For 64-bit systems (most common)
sudo dpkg -i releases/linux/chuk_chat_1.0.1_amd64.deb

# For ARM64 systems (Raspberry Pi 4, etc.)
sudo dpkg -i releases/linux/chuk_chat_1.0.1_arm64.deb

# Install dependencies if needed
sudo apt-get install -f
```

#### Fedora/RHEL/CentOS (RPM)

```bash
# For 64-bit systems
sudo rpm -i releases/linux/chuk_chat-1.0.1-1.x86_64.rpm

# For ARM64 systems
sudo rpm -i releases/linux/chuk_chat-1.0.1-1.aarch64.rpm
```

#### AppImage (Universal)

```bash
# Make executable
chmod +x releases/linux/chuk_chat-1.0.1-x86_64.AppImage

# Run directly (no installation needed)
./releases/linux/chuk_chat-1.0.1-x86_64.AppImage
```

## Getting Started

### First Time Setup

1. **Create an Account**
   - Open the app
   - Click "Sign Up"
   - Enter your email and a strong password (12+ characters)
   - Verify your email address

2. **Sign In**
   - Enter your credentials
   - Your encryption keys are automatically loaded
   - Your synced chats appear in the sidebar

3. **Start Chatting**
   - Click the "+" button to create a new chat
   - Select an AI model from the dropdown
   - Type your message and press Enter or click Send
   - Watch the AI response stream in real-time

### Using Advanced Features

#### Changing AI Models

- Click the model dropdown at the top of the chat
- Select a different model
- The model applies to new messages in that chat

#### Attaching Files

- Click the attachment icon (📎) in the message input area
- Select a file (images, PDFs, text files, etc.)
- The file is uploaded and converted to markdown
- Files are included in your message context

#### Customizing Theme

- Click Settings (⚙️) in the sidebar
- Choose accent colors, background colors, and icon colors
- Toggle dark/light mode
- Enable or disable film grain overlay
- Changes sync across all your devices

#### Starring Chats

- Hover over a chat in the sidebar
- Click the star icon (⭐)
- Starred chats appear at the top of your chat list

## System Requirements

### Android

- Android 7.0 (API level 24) or higher
- 100 MB free storage space
- Internet connection for syncing and AI chat

### Linux

- Ubuntu 20.04+, Debian 11+, Fedora 35+, or compatible distribution
- x86_64 or ARM64 processor
- 200 MB free storage space
- Internet connection for syncing and AI chat

## Privacy & Data

### What Data is Encrypted

- All chat messages (sent and received)
- Chat titles and metadata
- Starred chat status
- Timestamps and message history

### What Data is NOT Encrypted

- Your email address
- Theme preferences
- Model selection preferences
- API usage statistics (anonymous)

### Where is Data Stored

- **Local Device**: Encrypted chat history is cached locally for offline access
- **Supabase Cloud**: Encrypted chats are synced to the cloud (still encrypted)
- **Your Encryption Key**: Stored securely in your device's keychain/keystore

Your encryption key never leaves your device. Even if the server is compromised, your chats remain encrypted.

## Troubleshooting

### App won't connect to server

1. Check your internet connection
2. Verify you're not behind a restrictive firewall
3. Try disabling VPN if you're using one
4. Check if api.chuk.dev is accessible from your browser

### Can't see my chats after signing in

1. Make sure you're using the same email address
2. Try logging out and logging back in
3. Check if your encryption key was loaded (check logs in debug mode)
4. Contact support if issue persists

### File upload fails

1. Ensure file is under 10 MB
2. Check file type is supported (PDF, images, text, markdown)
3. Try a different file
4. Check your internet connection

### Theme changes not saving

1. Make sure you're signed in
2. Check your internet connection
3. Try changing theme again
4. Check Settings page for error messages

## Support

For bug reports and feature requests, please open an issue on the GitHub repository.

For security vulnerabilities, please see [SECURITY.md](SECURITY.md) for responsible disclosure guidelines.

---

## Development

This section is for developers who want to build, modify, or contribute to chuk_chat.

### Prerequisites

- **Flutter SDK**: Version 3.24.0 or higher
- **Dart SDK**: Version 3.5.0 or higher (comes with Flutter)
- **Android Studio** (for Android builds): Latest stable version
- **Android SDK**: API Level 36 (compileSdk), minimum API Level 24
- **Android NDK**: Version 26.3.11579264 or higher
- **Linux Build Tools** (for Linux builds):
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

   # Run on specific device
   flutter run -d linux
   flutter run -d android

   # Run with platform optimization (tree-shaking)
   flutter run -d linux --dart-define=PLATFORM_DESKTOP=true
   flutter run -d android --dart-define=PLATFORM_MOBILE=true
   ```

### Building for Release

#### Quick Build (Development/Testing)

For fast iteration during development:

```bash
# Single-architecture Android APK (~30 seconds)
flutter build apk --dart-define=PLATFORM_MOBILE=true --tree-shake-icons --target-platform android-arm64

# Linux build (optimized)
flutter build linux --dart-define=PLATFORM_DESKTOP=true --tree-shake-icons
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
- AI models provided by various providers (OpenRouter, Anthropic, OpenAI, etc.)
