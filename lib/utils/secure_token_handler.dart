import 'package:flutter/foundation.dart';

/// Utility for secure handling of authentication tokens.
///
/// Provides methods for:
/// - Token masking in logs and error messages
/// - Safe debug printing (disabled in production)
/// - Token validation
class SecureTokenHandler {
  SecureTokenHandler._();

  /// Masks a token for safe display in logs and error messages.
  ///
  /// Shows first 8 and last 4 characters, masks the rest.
  /// Example: "eyJhbGc...xyz" -> "eyJhbGc...xyz"
  static String maskToken(String? token) {
    if (token == null || token.isEmpty) {
      return '[empty]';
    }

    if (token.length <= 12) {
      // For very short tokens, mask everything except first 2 chars
      return '${token.substring(0, 2)}${'*' * (token.length - 2)}';
    }

    // Show first 8 and last 4 characters
    final prefix = token.substring(0, 8);
    final suffix = token.substring(token.length - 4);
    final maskedLength = token.length - 12;

    return '$prefix${'*' * maskedLength}$suffix';
  }

  /// Validates if a token is present and non-empty.
  static bool isTokenValid(String? token) {
    return token != null && token.isNotEmpty;
  }


  /// Creates a masked authorization header value for logging.
  static String maskAuthHeader(String authHeader) {
    if (authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      return 'Bearer ${maskToken(token)}';
    }
    return maskToken(authHeader);
  }

  /// Validates token and returns a safe error message if invalid.
  static String? validateTokenForRequest(
    String? token, {
    String context = 'Request',
  }) {
    if (token == null || token.isEmpty) {
      return '$context failed: Authentication token is missing';
    }

    // Basic validation: JWT tokens should have at least 3 parts separated by dots
    if (token.startsWith('ey') && token.contains('.')) {
      final parts = token.split('.');
      if (parts.length >= 3) {
        return null; // Token looks valid
      }
    }

    // For other token formats, just check length
    if (token.length < 20) {
      return '$context failed: Authentication token appears to be invalid';
    }

    return null; // Token looks valid
  }

  /// Creates a safe error message that doesn't expose tokens.
  static String createSafeErrorMessage(String baseMessage, {String? token}) {
    if (token != null && token.isNotEmpty) {
      // Ensure the error message doesn't contain the actual token
      if (baseMessage.contains(token)) {
        return baseMessage.replaceAll(token, maskToken(token));
      }
    }
    return baseMessage;
  }

  /// Logs an API request with masked tokens.
  static void logApiRequest({
    required String endpoint,
    required String method,
    String? accessToken,
    Map<String, dynamic>? payload,
  }) {
    if (!kDebugMode) return;

    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('📤 API REQUEST');
    debugPrint('Method: $method');
    debugPrint('Endpoint: $endpoint');

    if (accessToken != null) {
      debugPrint('Authorization: Bearer ${maskToken(accessToken)}');
    }

    if (payload != null && payload.isNotEmpty) {
      // Create a safe copy of payload with masked sensitive data
      final safePayload = Map<String, dynamic>.from(payload);

      // Mask any fields that might contain tokens
      for (final key in ['token', 'access_token', 'refresh_token', 'api_key']) {
        if (safePayload.containsKey(key) && safePayload[key] is String) {
          safePayload[key] = maskToken(safePayload[key] as String);
        }
      }

      debugPrint('Payload: $safePayload');
    }

    debugPrint('═══════════════════════════════════════════════════════════');
  }

  /// Logs an API response with masked tokens.
  static void logApiResponse({
    required String endpoint,
    required int statusCode,
    String? error,
    bool success = true,
  }) {
    if (!kDebugMode) return;

    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint(success ? '✅ API SUCCESS' : '❌ API ERROR');
    debugPrint('Endpoint: $endpoint');
    debugPrint('Status: $statusCode');

    if (error != null) {
      // Make sure error doesn't contain any tokens
      final safeError = error.replaceAllMapped(
        RegExp(r'[a-zA-Z0-9._-]{40,}'),
        (match) => maskToken(match.group(0) ?? ''),
      );
      debugPrint('Error: $safeError');
    }

    debugPrint('═══════════════════════════════════════════════════════════');
  }


}
