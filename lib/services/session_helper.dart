// lib/services/session_helper.dart
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/service_logger.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of session validation
class SessionValidationResult {
  final bool isValid;
  final String? errorMessage;
  final Session? session;
  final String? accessToken;

  const SessionValidationResult({
    required this.isValid,
    this.errorMessage,
    this.session,
    this.accessToken,
  });

  factory SessionValidationResult.valid(Session session, String accessToken) {
    return SessionValidationResult(
      isValid: true,
      session: session,
      accessToken: accessToken,
    );
  }

  factory SessionValidationResult.invalid(String message) {
    return SessionValidationResult(
      isValid: false,
      errorMessage: message,
    );
  }
}

/// Helper for session management and validation
class SessionHelper {
  const SessionHelper._();

  /// Get current session with automatic refresh if expired
  /// Returns null if session cannot be refreshed
  static Future<Session?> getValidSession() async {
    ServiceLogger.operationStart('getValidSession', context: 'SessionHelper');

    try {
      // Try to refresh session first
      final refreshedSession = await SupabaseService.refreshSession();
      if (refreshedSession != null) {
        ServiceLogger.success(
          'Session refreshed successfully',
          context: 'SessionHelper',
        );
        return refreshedSession;
      }

      // Fall back to current session if refresh didn't return a new one
      final currentSession = SupabaseService.auth.currentSession;
      if (currentSession != null) {
        ServiceLogger.info(
          'Using current session',
          context: 'SessionHelper',
        );
        return currentSession;
      }

      ServiceLogger.warning(
        'No valid session available',
        context: 'SessionHelper',
      );
      return null;
    } catch (e) {
      ServiceLogger.error(
        'Failed to get valid session',
        context: 'SessionHelper',
        exception: e,
      );
      return null;
    }
  }

  /// Validate session and get access token
  /// Returns SessionValidationResult with error message if invalid
  static Future<SessionValidationResult> validateAndGetToken() async {
    ServiceLogger.operationStart(
      'validateAndGetToken',
      context: 'SessionHelper',
    );

    final session = await getValidSession();
    if (session == null) {
      return SessionValidationResult.invalid(
        'Session expired. Please sign in again.',
      );
    }

    final accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      return SessionValidationResult.invalid(
        'Unable to authenticate your session.',
      );
    }

    ServiceLogger.success(
      'Session validated successfully',
      context: 'SessionHelper',
    );

    return SessionValidationResult.valid(session, accessToken);
  }

  /// Check if user is authenticated
  static bool isAuthenticated() {
    final session = SupabaseService.auth.currentSession;
    return session != null && session.accessToken.isNotEmpty;
  }

  /// Get current user ID
  static String? getCurrentUserId() {
    return SupabaseService.auth.currentSession?.user.id;
  }

  /// Get current user email
  static String? getCurrentUserEmail() {
    return SupabaseService.auth.currentSession?.user.email;
  }

  /// Check if session is expired or about to expire (within 5 minutes)
  static bool isSessionExpiringSoon() {
    final session = SupabaseService.auth.currentSession;
    if (session == null) return true;

    final expiresAt = session.expiresAt;
    if (expiresAt == null) return false;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresIn = expiresAt - now;

    // Consider expired if less than 5 minutes remaining
    return expiresIn < 300;
  }

  /// Refresh session if it's expiring soon
  static Future<Session?> refreshIfNeeded() async {
    if (!isSessionExpiringSoon()) {
      return SupabaseService.auth.currentSession;
    }

    ServiceLogger.info(
      'Session expiring soon, refreshing...',
      context: 'SessionHelper',
    );

    return await getValidSession();
  }

  /// Sign out and clear session
  static Future<void> signOut() async {
    ServiceLogger.operationStart('signOut', context: 'SessionHelper');

    try {
      await SupabaseService.signOut();
      ServiceLogger.success('Signed out successfully', context: 'SessionHelper');
    } catch (e) {
      ServiceLogger.error(
        'Failed to sign out',
        context: 'SessionHelper',
        exception: e,
      );
      rethrow;
    }
  }

  /// Execute an operation with session validation
  /// Automatically handles session refresh and error cases
  static Future<T?> executeWithSession<T>({
    required Future<T> Function(Session session, String accessToken) operation,
    required String operationName,
    void Function(String error)? onError,
  }) async {
    ServiceLogger.operationStart(operationName, context: 'SessionHelper');

    final validationResult = await validateAndGetToken();
    if (!validationResult.isValid) {
      final error = validationResult.errorMessage ?? 'Session validation failed';
      ServiceLogger.error(
        'Session validation failed for $operationName',
        context: 'SessionHelper',
      );
      onError?.call(error);
      return null;
    }

    try {
      final result = await operation(
        validationResult.session!,
        validationResult.accessToken!,
      );
      ServiceLogger.operationComplete(operationName, context: 'SessionHelper');
      return result;
    } catch (e) {
      ServiceLogger.operationFailed(
        operationName,
        context: 'SessionHelper',
        exception: e,
      );
      onError?.call('Operation failed: $e');
      return null;
    }
  }
}
