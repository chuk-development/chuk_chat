// lib/utils/privacy_logger.dart
//
// Privacy-aware logging utility for release builds.
// ALL logs are disabled in release mode for user privacy.

import 'package:flutter/foundation.dart';

/// Privacy-aware logging utility.
///
/// In DEBUG mode: All logs are printed (for development)
/// In RELEASE mode: ALL logs are disabled (for user privacy)
///
/// Usage:
///   import 'package:chuk_chat/utils/privacy_logger.dart';
///   pLog('Message here');  // Only prints in debug mode
///   pLog.info('Info');     // With level prefix
///   pLog.error('Error');   // With error prefix
class PrivacyLogger {
  const PrivacyLogger._();

  /// Log a message (only in debug mode)
  static void call(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  /// Log info message
  static void info(String message) {
    if (kDebugMode) {
      debugPrint('ℹ️ $message');
    }
  }

  /// Log success message
  static void success(String message) {
    if (kDebugMode) {
      debugPrint('✅ $message');
    }
  }

  /// Log warning message
  static void warning(String message) {
    if (kDebugMode) {
      debugPrint('⚠️ $message');
    }
  }

  /// Log error message
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (kDebugMode) {
      debugPrint('❌ $message');
      if (error != null) {
        debugPrint('   Error: $error');
      }
      if (stackTrace != null) {
        debugPrint('   Stack: $stackTrace');
      }
    }
  }

  /// Log with custom emoji/prefix
  static void custom(String prefix, String message) {
    if (kDebugMode) {
      debugPrint('$prefix $message');
    }
  }
}

/// Shorthand for PrivacyLogger.call()
/// Usage: pLog('My message');
void pLog(String message) => PrivacyLogger.call(message);
