// lib/services/api_config_service.dart
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Service for managing API configuration across different environments and platforms.
class ApiConfigService {
  // Environment variable keys
  static const String _envApiUrl = String.fromEnvironment('API_BASE_URL');
  static const String _envApiHost = String.fromEnvironment('API_HOST');
  static const String _envApiPort = String.fromEnvironment('API_PORT');

  // Default configuration
  static const String _defaultPort = '443';
  static const String _defaultProtocol = 'https';
  static const String _defaultProductionUrl = 'https://api.chuk.chat';

  // Production configuration (should be set via environment variables)
  static const String _productionUrl = String.fromEnvironment(
    'PRODUCTION_API_URL',
  );

  /// Gets the appropriate API base URL based on the current environment and platform.
  static String get apiBaseUrl {
    // 1. Check for explicit production URL from environment
    final String? configuredUrl = _configuredUrl;
    if (configuredUrl != null && configuredUrl.isNotEmpty) {
      return configuredUrl;
    }

    // Fall back to the production API when no environment overrides are present.
    return _defaultProductionUrl;
  }

  static String? get _configuredUrl {
    // 1. Explicit production URL from environment variables.
    if (_productionUrl.isNotEmpty) {
      return _productionUrl;
    }

    // 2. Custom API URL override.
    if (_envApiUrl.isNotEmpty) {
      return _envApiUrl;
    }

    // 3. Host/port combination.
    if (_envApiHost.isNotEmpty) {
      final port = _envApiPort.isNotEmpty ? _envApiPort : _defaultPort;
      return '$_defaultProtocol://$_envApiHost:$port';
    }

    return null;
  }

  /// Gets the current environment type.
  static String get environment {
    if (kDebugMode) {
      return 'development';
    } else {
      return 'production';
    }
  }

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
  static bool get isConfigured {
    // Consider the API configured when an explicit environment override is
    // provided or when we fall back to the production endpoint.
    return _configuredUrl != null || _defaultProductionUrl.isNotEmpty;
  }

  /// Gets a human-readable description of the current configuration.
  static String get configurationDescription {
    final env = environment;
    final platform = ApiConfigService.platform;
    final url = apiBaseUrl;
    final configured = isConfigured;

    return 'Environment: $env, Platform: $platform, URL: $url, Configured: $configured';
  }
}
