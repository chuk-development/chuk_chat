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
// flutter build apk --dart-define=FEATURE_VOICE_MODE=true --dart-define=FEATURE_WORKSPACES=true
//
// Build with defaults (workspaces enabled, others off):
// flutter build apk

/// Voice mode - audio recording and transcription
const bool kFeatureVoiceMode = bool.fromEnvironment(
  'FEATURE_VOICE_MODE',
  defaultValue: false,
);

/// Workspaces — custom AI personas with system prompts, files, and memory settings
const bool kFeatureWorkspaces = bool.fromEnvironment(
  'FEATURE_WORKSPACES',
  defaultValue: true,
);

/// Artifacts - editable code/markdown/HTML/technical drawing panels alongside chat
const bool kFeatureArtifacts = bool.fromEnvironment(
  'FEATURE_ARTIFACTS',
  defaultValue: true,
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
  defaultValue: false,
);

/// Desktop system tray integration (Linux, Windows, macOS).
/// Disabled by default; enable via --dart-define=FEATURE_SYSTEM_TRAY=true.
const bool kFeatureSystemTray = bool.fromEnvironment(
  'FEATURE_SYSTEM_TRAY',
  defaultValue: false,
);

/// CoWork mode — a phone-driven agent that runs on the user's laptop with real
/// system/CLI access, sandboxed execution and a persistent tray daemon. Lives in
/// the SAME app as Chat; a top-left switcher toggles between Chat and CoWork.
/// Disabled by default; enable via --dart-define=FEATURE_COWORK=true.
/// See docs/COWORK_BUILD_PLAN.md.
const bool kFeatureCoWork = bool.fromEnvironment(
  'FEATURE_COWORK',
  defaultValue: false,
);

/// Agent Skills — named procedures the AI loads on demand via the `skill`
/// tool, following the open spec at https://agentskills.io/specification.
/// Only `name` + description sit in the prompt; the body is disclosed on
/// activation. Skills are authored in `assets/skills/` and compiled in — none
/// are fetched at runtime.
///
/// Disabled by default; enable via --dart-define=FEATURE_SKILLS=true.
/// When off, the `skill` tool is never registered and the prompt is
/// byte-identical to a build without this feature.
const bool kFeatureSkills = bool.fromEnvironment(
  'FEATURE_SKILLS',
  defaultValue: false,
);

/// Linux secure storage backend for encryption keys.
/// When disabled, Linux falls back to SharedPreferences instead of keyring.
const bool kFeatureLinuxKeyring = bool.fromEnvironment(
  'FEATURE_LINUX_KEYRING',
  defaultValue: false,
);

/// Spotify playback tool. Disabled by default — API server no longer
/// exposes Spotify OAuth endpoints. Set `--dart-define=FEATURE_SPOTIFY=true`
/// only when the backend route is re-enabled.
const bool kFeatureSpotify = bool.fromEnvironment(
  'FEATURE_SPOTIFY',
  defaultValue: false,
);

/// WHOOP health/fitness tool. Disabled by default — integration removed
/// alongside Spotify. Set `--dart-define=FEATURE_WHOOP=true` to re-enable.
const bool kFeatureWhoop = bool.fromEnvironment(
  'FEATURE_WHOOP',
  defaultValue: false,
);

/// Direct payment integration via Stripe (web + mobile + desktop).
/// Defaults to true for direct distribution.
/// MUST be set false for Google Play Store builds to comply with Google's billing policy.
const bool kFeaturePaymentsDirect = bool.fromEnvironment(
  'FEATURE_PAYMENTS_DIRECT',
  defaultValue: true,
);

