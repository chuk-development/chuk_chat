// lib/services/api_config_service_io.dart
// Native platform implementation — uses dart:io for platform detection.
import 'dart:io';

import 'package:chuk_chat/services/api_config_base.dart' as base;

/// Service for managing API configuration across different environments and platforms.
class ApiConfigService {
  /// Gets the appropriate API base URL based on the current environment and platform.
  static String get apiBaseUrl => base.getApiBaseUrl();

  /// Gets the current environment type.
  static String get environment => base.getEnvironment();

  /// Gets the current platform name.
  static String get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'unknown';
  }

  /// Validates that the API configuration is properly set up.
  static bool get isConfigured => base.getIsConfigured();

  /// Gets a human-readable description of the current configuration.
  static String get configurationDescription =>
      base.getConfigurationDescription(platform);
}
