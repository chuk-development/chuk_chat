<p align="center">
  <img src="assets/logo.svg" width="120" alt="Chuk Chat Logo">
</p>

<h1 align="center">Chuk Chat</h1>

<p align="center">
  Private AI That Actually Belongs to You
</p>

<p align="center">
  A simple monthly subscription, full control, no data mining.<br>
  Chat, write, code, research — powered entirely by transparent open-weight models.
</p>

<p align="center">
  <a href="https://chuk.chat">Website</a> &middot;
  <a href="https://chat.chuk.chat">Web App</a> &middot;
  <a href="https://docs.chuk.chat">Docs</a> &middot;
  <a href="https://github.com/chuk-development/chuk_chat/releases">Downloads</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-BSL--1.1-blue" alt="License: BSL 1.1">
  <img src="https://img.shields.io/badge/flutter-3.24+-02569B?logo=flutter" alt="Flutter 3.24+">
  <img src="https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Linux%20%7C%20macOS%20%7C%20Windows%20%7C%20Web-brightgreen" alt="Platforms">
</p>

---

## Why Chuk Chat?

We use only open-weight models — no black boxes and no silent data collection. You know exactly what runs your AI.

- **Clear monthly pricing** — One straightforward fee. No pay-as-you-go, no hidden costs.
- **Open-weight only** — DeepSeek, Llama, Mistral, Qwen, and more via [OpenRouter](https://openrouter.ai). No closed-source models.
- **Privacy first** — Encrypted chats, no tracking, no profiling. Built like a tool, not a marketing funnel.
- **Your data, your control** — We store nothing you don't want. Fully deletable. Fully controllable. Fully yours.

## Features

- **End-to-End Encryption** — All chats encrypted client-side with AES-256-GCM before being stored or synced
- **Cross-Platform** — Android, iOS, Linux, macOS, Windows, and Web
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

### What is encrypted

| Data | Storage |
|------|---------|
| All chat messages | Encrypted locally + synced to cloud (still encrypted) |
| Chat titles & metadata | Encrypted |
| Starred chat status | Encrypted |
| Your encryption key | Stored in device keychain/keystore — never leaves your device |

For detailed security information, see [SECURITY.md](SECURITY.md).

## Pricing

**€20/month** — all models, all platforms, €16 in AI credits included.

See [chuk.chat/en/pricing](https://chuk.chat/en/pricing) for details.

## Development

### Prerequisites

- **Flutter SDK** 3.24+ (includes Dart 3.9.2+)
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

### Documentation

Full developer and architecture documentation is available at [docs.chuk.chat](https://docs.chuk.chat).

See also the [docs/](docs/) folder for build instructions, architecture, database schema, and more.

### Contributing

1. Fork the repo
2. Create a feature branch
3. Run `flutter analyze` and `dart format .`
4. Open a Pull Request

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Framework | [Flutter](https://flutter.dev) (Dart) |
| Backend | [Supabase](https://supabase.com) |
| Encryption | AES-256-GCM with PBKDF2 key derivation |
| AI Models | [OpenRouter](https://openrouter.ai) |
| Hosting | Dokploy + Cloudflare |

## License

[Business Source License 1.1](LICENSE) — free for non-production use. Converts to GPL v3 after 3 years per release.

## Links

- [Website](https://chuk.chat) — Product page & pricing
- [Web App](https://chat.chuk.chat) — Use Chuk Chat in the browser
- [Documentation](https://docs.chuk.chat) — Full docs
- [Privacy Policy](https://chuk.chat/en/privacy)
- [Status](https://status.chuk.chat)
- [Blog](https://chuk.dev/en/blog)
