// lib/env_loader.dart
// Runtime .env file loader for desktop platforms
//
// This allows running `flutter run` directly without --dart-define flags
// during local development. The .env file is read from the project root.

import 'package:chuk_chat/utils/io_helper.dart';

import 'package:flutter/foundation.dart';

/// Loads environment variables from .env file at runtime.
/// Only works on desktop platforms (Linux, macOS, Windows).
class EnvLoader {
  static final Map<String, String> _values = {};
  static bool _loaded = false;

  /// Load .env file from the current directory or project root.
  /// Safe to call multiple times - only loads once.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    // Only attempt file loading on desktop platforms
    if (!_isDesktop) {
      debugPrint('EnvLoader: Not a desktop platform, skipping .env file loading');
      return;
    }

    try {
      // Try multiple possible locations for the .env file
      final possiblePaths = [
        '.env',                    // Current directory (when running from project root)
        '../../../.env',           // When running from build directory
        '${Platform.environment['HOME']}/git/chuk_chat/.env', // Absolute fallback
      ];

      File? envFile;
      for (final path in possiblePaths) {
        final file = File(path);
        if (await file.exists()) {
          envFile = file;
          debugPrint('EnvLoader: Found .env at: $path');
          break;
        }
      }

      if (envFile == null) {
        debugPrint('EnvLoader: No .env file found, using compile-time values');
        return;
      }

      final contents = await envFile.readAsString();
      _parseEnvFile(contents);
      debugPrint('EnvLoader: Loaded ${_values.length} environment variables');
    } catch (e) {
      debugPrint('EnvLoader: Failed to load .env file: $e');
    }
  }

  /// Synchronous version for cases where async is not possible.
  /// Call load() first if you need guaranteed loading.
  static void loadSync() {
    if (_loaded) return;
    _loaded = true;

    if (!_isDesktop) return;

    try {
      final possiblePaths = [
        '.env',
        '../../../.env',
        '${Platform.environment['HOME']}/git/chuk_chat/.env',
      ];

      File? envFile;
      for (final path in possiblePaths) {
        final file = File(path);
        if (file.existsSync()) {
          envFile = file;
          debugPrint('EnvLoader: Found .env at: $path');
          break;
        }
      }

      if (envFile == null) {
        debugPrint('EnvLoader: No .env file found, using compile-time values');
        return;
      }

      final contents = envFile.readAsStringSync();
      _parseEnvFile(contents);
      debugPrint('EnvLoader: Loaded ${_values.length} environment variables');
    } catch (e) {
      debugPrint('EnvLoader: Failed to load .env file: $e');
    }
  }

  static void _parseEnvFile(String contents) {
    final lines = contents.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();

      // Skip empty lines and comments
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final equalsIndex = trimmed.indexOf('=');
      if (equalsIndex == -1) continue;

      final key = trimmed.substring(0, equalsIndex).trim();
      var value = trimmed.substring(equalsIndex + 1).trim();

      // Remove quotes if present
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }

      _values[key] = value;
    }
  }

  /// Get a value from the .env file, or null if not found.
  static String? get(String key) => _values[key];

  /// Get a value with a fallback default.
  static String getOrDefault(String key, String defaultValue) {
    return _values[key] ?? defaultValue;
  }

  /// Check if a key exists in the loaded .env file.
  static bool has(String key) => _values.containsKey(key);

  static bool get _isDesktop {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  }
}
