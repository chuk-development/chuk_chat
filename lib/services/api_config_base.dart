// lib/services/api_config_base.dart
// Shared API configuration logic used by both IO and Web implementations.
//
// Debug builds automatically use a local API server so you can develop and
// test API changes without pushing to production.  The local URL defaults to
// http://localhost:8000 but can be overridden with --dart-define=LOCAL_API_URL=…
//
// NOTE: On an Android emulator the host machine's localhost is reachable at
// 10.0.2.2, so pass --dart-define=LOCAL_API_URL=http://10.0.2.2:8000 when
// running on the Android emulator.
import 'package:flutter/foundation.dart';

// Environment variable keys
const String apiConfigEnvApiUrl = String.fromEnvironment('API_BASE_URL');
const String apiConfigEnvApiHost = String.fromEnvironment('API_HOST');
const String apiConfigEnvApiPort = String.fromEnvironment('API_PORT');

// Default configuration
const String apiConfigDefaultPort = '443';
const String apiConfigDefaultProtocol = 'https';
const String apiConfigDefaultProductionUrl = 'https://api.chuk.chat';

// Local development server URL (used in debug builds when no explicit URL is
// configured).  Override with --dart-define=LOCAL_API_URL=http://host:port
const String apiConfigLocalUrl = String.fromEnvironment(
  'LOCAL_API_URL',
  defaultValue: 'http://localhost:8000',
);

// Production configuration (should be set via environment variables)
const String apiConfigProductionUrl = String.fromEnvironment(
  'PRODUCTION_API_URL',
);

/// Resolves an explicitly configured URL from environment variables, or null.
String? getConfiguredUrl() {
  if (apiConfigProductionUrl.isNotEmpty) {
    return apiConfigProductionUrl;
  }
  if (apiConfigEnvApiUrl.isNotEmpty) {
    return apiConfigEnvApiUrl;
  }
  if (apiConfigEnvApiHost.isNotEmpty) {
    final port = apiConfigEnvApiPort.isNotEmpty
        ? apiConfigEnvApiPort
        : apiConfigDefaultPort;
    return '$apiConfigDefaultProtocol://$apiConfigEnvApiHost:$port';
  }
  return null;
}

/// Gets the appropriate API base URL based on the current environment.
///
/// Resolution order:
/// 1. Explicit dart-define (PRODUCTION_API_URL / API_BASE_URL / API_HOST)
/// 2. In **debug** builds: local dev server ([apiConfigLocalUrl], default
///    `http://localhost:8000`)
/// 3. In **release** builds: production (`https://api.chuk.chat`)
String getApiBaseUrl() {
  final String? configuredUrl = getConfiguredUrl();
  if (configuredUrl != null && configuredUrl.isNotEmpty) {
    return configuredUrl;
  }

  // Debug builds → local API server for development
  if (kDebugMode) {
    return apiConfigLocalUrl;
  }

  return apiConfigDefaultProductionUrl;
}

/// Whether the current build is pointing at the local development server.
bool get isLocalApiServer => kDebugMode && getConfiguredUrl() == null;

/// Gets the current environment type.
String getEnvironment() {
  if (kDebugMode) {
    return 'development';
  } else {
    return 'production';
  }
}

/// Checks whether the API was explicitly configured via environment variables,
/// or is using the automatic debug/release default.
/// Returns true if an explicit URL was configured OR if we're in debug mode
/// (which automatically uses the local server).
bool getIsConfigured() {
  return getConfiguredUrl() != null || kDebugMode;
}

/// Gets a human-readable description of the current configuration.
String getConfigurationDescription(String platformName) {
  final env = getEnvironment();
  final url = getApiBaseUrl();
  final configured = getIsConfigured();

  return 'Environment: $env, Platform: $platformName, URL: $url, Configured: $configured';
}
