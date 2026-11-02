// lib/services/chukdoo/chukdoo_config.dart
//
// Where the built-in Chukdoo connector pairs: the chukdoo Supabase project.
//
// Same resolution order as lib/supabase_config.dart:
// 1. Compile-time defines (`--dart-define=CHUKDOO_SUPABASE_URL=...`,
//    `CHUKDOO_SUPABASE_ANON_KEY`). run.sh, build.sh and CI pass them.
// 2. lib/web_env.dart, which Dockerfile.web generates for the web build.
// 3. The runtime .env file (desktop development only, via [EnvLoader]).
//
// Either value empty = the connector is hidden. Nothing here is a secret
// beyond what the chukdoo app ships itself (an anon key), but it is still
// never logged.

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/env_loader.dart';
import 'package:chuk_chat/web_env.dart' as web_env;

class ChukdooConfig {
  ChukdooConfig._();

  static const String _defineUrl = String.fromEnvironment(
    'CHUKDOO_SUPABASE_URL',
  );
  static const String _defineAnonKey = String.fromEnvironment(
    'CHUKDOO_SUPABASE_ANON_KEY',
  );

  static String? _overrideUrl;
  static String? _overrideAnonKey;

  /// The chukdoo Supabase project URL, or '' when none is configured.
  static String get supabaseUrl {
    if (_overrideUrl != null) return _overrideUrl!;
    if (_defineUrl.isNotEmpty) return _defineUrl;
    if (web_env.webChukdooSupabaseUrl.isNotEmpty) {
      return web_env.webChukdooSupabaseUrl;
    }
    return EnvLoader.get('CHUKDOO_SUPABASE_URL') ?? '';
  }

  /// The chukdoo anon key, or '' when none is configured.
  static String get anonKey {
    if (_overrideAnonKey != null) return _overrideAnonKey!;
    if (_defineAnonKey.isNotEmpty) return _defineAnonKey;
    if (web_env.webChukdooSupabaseAnonKey.isNotEmpty) {
      return web_env.webChukdooSupabaseAnonKey;
    }
    return EnvLoader.get('CHUKDOO_SUPABASE_ANON_KEY') ?? '';
  }

  /// True when the connector can pair: both values are set.
  static bool get isConfigured =>
      supabaseUrl.trim().isNotEmpty && anonKey.trim().isNotEmpty;

  /// Loads the desktop .env file when no define carries the values. Safe to
  /// call more than once; a no-op on mobile and web.
  static Future<void> ensureLoaded() async {
    if (_defineUrl.isNotEmpty && _defineAnonKey.isNotEmpty) return;
    await EnvLoader.load();
  }

  @visibleForTesting
  static void debugOverride({String? url, String? anonKey}) {
    _overrideUrl = url;
    _overrideAnonKey = anonKey;
  }
}
