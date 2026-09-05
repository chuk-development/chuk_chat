// lib/services/api_config_base.dart
// Shared API configuration logic used by both IO and Web implementations.
//
// COWORK CHANGE (bd cowork-zrq): a debug build points at the SAME account
// backend as a release build. Upstream chuk_chat falls back to a local dev API
// server in debug; CoWork has no such server. Its own host (port 8787) does not
// serve `/v1/models_info` — the host CALLS that endpoint on the account backend
// itself (host.py, resolve_backend_model_wiring) — and the app also runs on a
// phone far away from the host, where 8787 is unreachable. Falling back to
// localhost only produced an empty model catalogue and "Cannot reach local API
// server". The catalogue is metadata, not a model call, so this does not touch
// the rule that model ANSWERS go through the paired host.
//
// A local dev server is still reachable, but only when it is asked for:
// --dart-define=LOCAL_API_URL=http://localhost:8000
//
// NOTE: On an Android emulator the host machine's localhost is reachable at
// 10.0.2.2, so pass --dart-define=LOCAL_API_URL=http://10.0.2.2:8000 when
// running on the Android emulator.
//
// Later option, recorded in the bead: carry the catalogue over the relay frame
// from the host instead of fetching it from the app.
import 'package:flutter/foundation.dart';

// Environment variable keys
const String apiConfigEnvApiUrl = String.fromEnvironment('API_BASE_URL');
const String apiConfigEnvApiHost = String.fromEnvironment('API_HOST');
const String apiConfigEnvApiPort = String.fromEnvironment('API_PORT');

// Default configuration
const String apiConfigDefaultPort = '443';
const String apiConfigDefaultProtocol = 'https';
const String apiConfigDefaultProductionUrl = 'https://api.chuk.chat';

// Local development server URL. Empty unless the build asked for one with
// --dart-define=LOCAL_API_URL=http://host:port; an empty value means "use the
// account backend", which is now the debug default too.
const String apiConfigLocalUrl = String.fromEnvironment('LOCAL_API_URL');

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
/// 2. An explicitly requested local dev server ([apiConfigLocalUrl], debug only)
/// 3. Otherwise the account backend (`https://api.chuk.chat`), in debug and
///    release alike
String getApiBaseUrl() {
  final String? configuredUrl = getConfiguredUrl();
  if (configuredUrl != null && configuredUrl.isNotEmpty) {
    return configuredUrl;
  }

  // A local dev server only when the build asked for one.
  if (kDebugMode && apiConfigLocalUrl.isNotEmpty) {
    return apiConfigLocalUrl;
  }

  return apiConfigDefaultProductionUrl;
}

/// Whether the current build is pointing at a local development server.
bool get isLocalApiServer =>
    kDebugMode && getConfiguredUrl() == null && apiConfigLocalUrl.isNotEmpty;

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
