// lib/platform_config.dart
// Platform configuration using compile-time constants
//
// This file uses const bool flags that can be set at compile time via --dart-define
// to enable aggressive tree-shaking. The Dart compiler can completely remove
// unused branches when these are compile-time constants.

// These can be overridden at build time with:
// flutter build linux --dart-define=PLATFORM_MOBILE=false
// flutter build apk --dart-define=PLATFORM_DESKTOP=false

const bool kPlatformMobile = bool.fromEnvironment('PLATFORM_MOBILE', defaultValue: false);
const bool kPlatformDesktop = bool.fromEnvironment('PLATFORM_DESKTOP', defaultValue: false);

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
const bool kFeatureVoiceMode = bool.fromEnvironment('FEATURE_VOICE_MODE', defaultValue: false);

/// Projects - workspace organization with custom system prompts
const bool kFeatureProjects = bool.fromEnvironment('FEATURE_PROJECTS', defaultValue: false);

/// Assistants - custom AI assistants (future feature)
const bool kFeatureAssistants = bool.fromEnvironment('FEATURE_ASSISTANTS', defaultValue: false);

/// Image Generation - AI image creation via Z-Image Turbo
const bool kFeatureImageGen = bool.fromEnvironment('FEATURE_IMAGE_GEN', defaultValue: false);
