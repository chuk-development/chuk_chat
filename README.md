<p align="center">
  <img src="assets/logo.svg" width="120" alt="Chuk Chat Logo">
</p>

<h1 align="center">Chuk Chat</h1>

<p align="center">
  Secure, cross-platform chat with AI — encrypted by default.
</p>

<p align="center">
  <a href="https://chat.chuk.chat">Web App</a> &middot;
  <a href="https://github.com/chuk-development/chuk_chat/releases">Downloads</a> &middot;
  <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-BSL--1.1-blue" alt="License: BSL 1.1">
  <img src="https://img.shields.io/badge/flutter-3.24+-02569B?logo=flutter" alt="Flutter 3.24+">
  <img src="https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Linux%20%7C%20macOS%20%7C%20Windows%20%7C%20Web-brightgreen" alt="Platforms">
</p>

---

A privacy-focused chat application built with Flutter. Chat with open-weight AI models while keeping your conversations encrypted and under your control.

**Our philosophy**: We exclusively support open-weight models. We believe in transparency, accessibility, and the freedom to run AI models independently.

## Features

- **End-to-End Encryption** — All chats are encrypted client-side with AES-256-GCM before being stored or synced
- **Cross-Platform** — Works on Android, iOS, Linux, macOS, Windows, and Web
- **Open-Weight AI Models** — DeepSeek, Llama, Mistral, Qwen, and more via [OpenRouter](https://openrouter.ai)
- **Real-Time Streaming** — Watch AI responses as they're generated
- **File Attachments** — Share images, PDFs, and documents with AI
- **AI Image Generation** — Generate images directly in chat
- **Offline Support** — Access your chat history without a connection
- **Theme Customization** — Colors, backgrounds, dark/light mode, visual effects

## Security & Privacy

- **Client-side encryption** — Messages are encrypted on your device before leaving it
- **Zero-knowledge architecture** — We cannot read your chats, even if the server is compromised
- **Certificate pinning** — Protection against MITM attacks
- **No logging in production** — All debug logs are disabled in release builds

> **If you lose your password, all your chats are permanently lost.** There is no recovery mechanism by design — this ensures maximum privacy. Choose a strong password and store it safely.

For detailed security information, see [SECURITY.md](SECURITY.md).

### What is encrypted

| Data | Storage |
|------|---------|
| All chat messages | Encrypted locally + synced to cloud (still encrypted) |
| Chat titles & metadata | Encrypted |
| Starred chat status | Encrypted |
| Your encryption key | Stored in device keychain/keystore — never leaves your device |

## Development

### Prerequisites

- **Flutter SDK** 3.24+ (includes Dart)
- **Supabase** project ([supabase.com](https://supabase.com))

Platform-specific: Android Studio (Android), Xcode (iOS/macOS), Visual Studio 2022 (Windows).

### Setup

```bash
git clone https://github.com/chuk-development/chuk_chat.git
cd chuk_chat

cp .env.example .env
# Edit .env with your Supabase credentials

flutter pub get
./run.sh linux    # or: android, windows, macos, ios, web
```

### Build

```bash
# Quick release build (loads credentials from .env)
source .env && flutter build apk --release \
  --dart-define="SUPABASE_URL=$SUPABASE_URL" \
  --dart-define="SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"

# Full release (all platforms)
./scripts/build-release.sh all
```

See [docs/](docs/) for detailed build instructions, architecture, and more.

### Contributing

1. Fork the repo
2. Create a feature branch
3. Run `flutter analyze` and `dart format .`
4. Open a Pull Request

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

[Business Source License 1.1](LICENSE) — free for non-production use. Converts to GPL v3 after 3 years per release.

## Acknowledgments

Built with [Flutter](https://flutter.dev) · Backend by [Supabase](https://supabase.com) · AI via [OpenRouter](https://openrouter.ai)
