// lib/supabase_config.dart
//
// Supabase configuration.
//
// Credentials are loaded in the following priority order:
// 1. Compile-time environment variables (--dart-define)
// 2. Runtime .env file (desktop only, for local development)
//
// For production builds, always use --dart-define:
//   flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
//
// For local development on desktop, just create a .env file:
//   cp .env.example .env
//   # Edit .env with your credentials
//   flutter run -d linux
//
// Or use the run.sh helper script which handles everything.

import 'package:chuk_chat/env_loader.dart';
import 'package:chuk_chat/web_env.dart' as web_env;

class SupabaseConfig {
  // Compile-time values (from --dart-define)
  static const String _envUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _envAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static const String _placeholderUrl = 'https://your-project.supabase.co';
  static const String _placeholderKey = 'your-anon-key-here';

  static bool _initialized = false;
  static String _runtimeUrl = '';
  static String _runtimeAnonKey = '';

  /// Initialize the config by loading .env file if needed.
  /// Call this before accessing supabaseUrl or supabaseAnonKey.
  /// Safe to call multiple times.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // If compile-time values are set, use them
    if (_envUrl.isNotEmpty && _envAnonKey.isNotEmpty) {
      _runtimeUrl = _envUrl;
      _runtimeAnonKey = _envAnonKey;
      return;
    }

    // Try web-generated constants (from Dockerfile.web)
    if (web_env.webSupabaseUrl.isNotEmpty && web_env.webSupabaseAnonKey.isNotEmpty) {
      _runtimeUrl = web_env.webSupabaseUrl;
      _runtimeAnonKey = web_env.webSupabaseAnonKey;
      return;
    }

    // Try to load from .env file (desktop only)
    await EnvLoader.load();

    _runtimeUrl = EnvLoader.get('SUPABASE_URL') ?? '';
    _runtimeAnonKey = EnvLoader.get('SUPABASE_ANON_KEY') ?? '';
  }

  /// Synchronous initialization for cases where async is not possible.
  static void initializeSync() {
    if (_initialized) return;
    _initialized = true;

    if (_envUrl.isNotEmpty && _envAnonKey.isNotEmpty) {
      _runtimeUrl = _envUrl;
      _runtimeAnonKey = _envAnonKey;
      return;
    }

    if (web_env.webSupabaseUrl.isNotEmpty && web_env.webSupabaseAnonKey.isNotEmpty) {
      _runtimeUrl = web_env.webSupabaseUrl;
      _runtimeAnonKey = web_env.webSupabaseAnonKey;
      return;
    }

    EnvLoader.loadSync();

    _runtimeUrl = EnvLoader.get('SUPABASE_URL') ?? '';
    _runtimeAnonKey = EnvLoader.get('SUPABASE_ANON_KEY') ?? '';
  }

  static String get supabaseUrl {
    // Ensure initialized (sync fallback)
    if (!_initialized) initializeSync();

    // Priority: compile-time > runtime > placeholder
    if (_envUrl.isNotEmpty) return _envUrl;
    if (_runtimeUrl.isNotEmpty) return _runtimeUrl;
    return _placeholderUrl;
  }

  static String get supabaseAnonKey {
    // Ensure initialized (sync fallback)
    if (!_initialized) initializeSync();

    // Priority: compile-time > runtime > placeholder
    if (_envAnonKey.isNotEmpty) return _envAnonKey;
    if (_runtimeAnonKey.isNotEmpty) return _runtimeAnonKey;
    return _placeholderKey;
  }

  /// Returns true when credentials are not configured (still using placeholders).
  static bool get isUsingPlaceholderValues {
    // Ensure initialized (sync fallback)
    if (!_initialized) initializeSync();

    final url = supabaseUrl;
    final key = supabaseAnonKey;

    return url == _placeholderUrl || key == _placeholderKey ||
           url.isEmpty || key.isEmpty;
  }
}
