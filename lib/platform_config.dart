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
