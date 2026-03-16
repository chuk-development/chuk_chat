// lib/platform_config.dart
// Platform configuration using compile-time constants
//
// This file uses const bool flags that can be set at compile time via --dart-define
// to enable aggressive tree-shaking. The Dart compiler can completely remove
// unused branches when these are compile-time constants.

// These can be overridden at build time with:
// flutter build linux --dart-define=PLATFORM_MOBILE=false
// flutter build apk --dart-define=PLATFORM_DESKTOP=false

const bool kPlatformMobile = bool.fromEnvironment(
  'PLATFORM_MOBILE',
  defaultValue: false,
);
const bool kPlatformDesktop = bool.fromEnvironment(
  'PLATFORM_DESKTOP',
  defaultValue: false,
);

// Auto-detect if not explicitly set
const bool kAutoDetectPlatform = !kPlatformMobile && !kPlatformDesktop;

// ============================================================================
// FEATURE FLAGS
// ============================================================================
// These flags control experimental/in-progress features.
// Set to true to enable, false to disable (hide from UI).
//
// Build with features enabled:
// flutter build apk --dart-define=FEATURE_VOICE_MODE=true --dart-define=FEATURE_PROJECTS=true
//
// Build with features disabled (default for production):
// flutter build apk  (all features disabled by default)

/// Voice mode - audio recording and transcription
const bool kFeatureVoiceMode = bool.fromEnvironment(
  'FEATURE_VOICE_MODE',
  defaultValue: false,
);

/// Projects - workspace organization with custom system prompts
const bool kFeatureProjects = bool.fromEnvironment(
  'FEATURE_PROJECTS',
  defaultValue: false,
);

/// Assistants - custom AI assistants (future feature)
const bool kFeatureAssistants = bool.fromEnvironment(
  'FEATURE_ASSISTANTS',
  defaultValue: false,
);

/// Artifacts - editable code/markdown/HTML panels alongside chat
const bool kFeatureArtifacts = bool.fromEnvironment(
  'FEATURE_ARTIFACTS',
  defaultValue: false,
);

/// Image Generation - AI image creation via Z-Image Turbo
/// Always enabled - no feature flag needed (Image Generation is production-ready)
const bool kFeatureImageGen = true;

/// Media Manager - View and manage stored media (images) in Supabase
const bool kFeatureMediaManager = true;

/// Server-backed integration tools (Spotify, GitHub, Slack, Google, Email,
/// Nextcloud). OAuth credentials are managed by the API server; tokens are
/// stored locally on the client.
const bool kFeatureServerTools = bool.fromEnvironment(
  'FEATURE_SERVER_TOOLS',
  defaultValue: true,
);

/// Linux system tray integration.
/// Enabled by default, can still be disabled via --dart-define.
const bool kFeatureLinuxTray = bool.fromEnvironment(
  'FEATURE_LINUX_TRAY',
  defaultValue: true,
);

/// Linux secure storage backend for encryption keys.
/// When disabled, Linux falls back to SharedPreferences instead of keyring.
const bool kFeatureLinuxKeyring = bool.fromEnvironment(
  'FEATURE_LINUX_KEYRING',
  defaultValue: true,
);

/// Stock market data tool (Yahoo Finance).
/// Disabled by default because the unofficial Yahoo Finance API should not be
/// used in a commercial product. Enable via --dart-define for local testing
/// only; keep disabled in release builds.
const bool kFeatureStockData = bool.fromEnvironment(
  'FEATURE_STOCK_DATA',
  defaultValue: false,
);
