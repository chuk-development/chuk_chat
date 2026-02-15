// lib/services/api_config_base.dart
// Shared API configuration logic used by both IO and Web implementations.
import 'package:flutter/foundation.dart';

// Environment variable keys
const String apiConfigEnvApiUrl = String.fromEnvironment('API_BASE_URL');
const String apiConfigEnvApiHost = String.fromEnvironment('API_HOST');
const String apiConfigEnvApiPort = String.fromEnvironment('API_PORT');

// Default configuration
const String apiConfigDefaultPort = '443';
const String apiConfigDefaultProtocol = 'https';
const String apiConfigDefaultProductionUrl = 'https://api.chuk.chat';

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
String getApiBaseUrl() {
  final String? configuredUrl = getConfiguredUrl();
  if (configuredUrl != null && configuredUrl.isNotEmpty) {
    return configuredUrl;
  }
  return apiConfigDefaultProductionUrl;
}

/// Gets the current environment type.
String getEnvironment() {
  if (kDebugMode) {
    return 'development';
  } else {
    return 'production';
  }
}

/// Checks whether the API was explicitly configured via environment variables.
/// Returns true if an explicit URL was configured, false if using the
/// hardcoded production fallback.
bool getIsConfigured() {
  return getConfiguredUrl() != null;
}

/// Gets a human-readable description of the current configuration.
String getConfigurationDescription(String platformName) {
  final env = getEnvironment();
  final url = getApiBaseUrl();
  final configured = getIsConfigured();

  return 'Environment: $env, Platform: $platformName, URL: $url, Configured: $configured';
}
