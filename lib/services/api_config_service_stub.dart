// lib/services/api_config_service_stub.dart
// Web stub — no dart:io Platform access.
import 'package:chuk_chat/services/api_config_base.dart' as base;

/// Service for managing API configuration across different environments and platforms.
/// Web stub — returns 'web' for platform.
class ApiConfigService {
  /// Gets the appropriate API base URL based on the current environment and platform.
  static String get apiBaseUrl => base.getApiBaseUrl();

  /// Gets the current environment type.
  static String get environment => base.getEnvironment();

  /// Gets the current platform name.
  static String get platform => 'web';

  /// Validates that the API configuration is properly set up.
  static bool get isConfigured => base.getIsConfigured();

  /// Gets a human-readable description of the current configuration.
  static String get configurationDescription =>
      base.getConfigurationDescription(platform);
}
