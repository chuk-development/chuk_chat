import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/sandbox_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class AuthService {
  const AuthService();

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      await SupabaseService.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } on AuthException catch (error) {
      throw AuthServiceException(message: error.message);
    } catch (error) {
      throw AuthServiceException(message: 'Unexpected error: $error');
    }
  }

  Future<void> signUpWithPassword({
    required String email,
    required String password,
    String? displayName,
  }) async {
    try {
      final response = await SupabaseService.auth.signUp(
        email: email,
        password: password,
        data: {
          if (displayName != null && displayName.trim().isNotEmpty)
            'display_name': displayName,
        },
      );
      // Supabase returns a fake user with empty identities when the email
      // already exists (email enumeration protection). Detect and surface it.
      if (response.user != null &&
          (response.user!.identities == null ||
              response.user!.identities!.isEmpty)) {
        throw const AuthServiceException(
          message:
              'An account with this email already exists. Try signing in instead.',
          code: AuthServiceException.codeEmailAlreadyRegistered,
        );
      }
    } on AuthServiceException {
      rethrow;
    } on AuthException catch (error) {
      final message = error.message;
      final normalized = message.toLowerCase();
      if (normalized.contains('already registered') ||
          normalized.contains('already been registered')) {
        throw const AuthServiceException(
          message:
              'An account with this email already exists. Try signing in instead.',
          code: AuthServiceException.codeEmailAlreadyRegistered,
        );
      }
      throw AuthServiceException(message: message);
    } catch (error) {
      throw AuthServiceException(message: 'Unexpected error: $error');
    }
  }

  /// Verifies the 6-digit signup confirmation code emailed to [email].
  /// On success the user is signed in with an active session.
  Future<void> verifySignupOtp({
    required String email,
    required String token,
  }) async {
    await _verifyEmailOtp(email: email, token: token, type: OtpType.signup);
  }

  /// Verifies the 6-digit password recovery code emailed to [email].
  /// On success the user holds a recovery session and may set a new password.
  Future<void> verifyRecoveryOtp({
    required String email,
    required String token,
  }) async {
    await _verifyEmailOtp(email: email, token: token, type: OtpType.recovery);
  }

  Future<void> _verifyEmailOtp({
    required String email,
    required String token,
    required OtpType type,
  }) async {
    try {
      await SupabaseService.auth.verifyOTP(
        email: email,
        token: token.trim(),
        type: type,
      );
    } on AuthException catch (error) {
      throw _mapOtpException(error);
    } catch (error) {
      throw AuthServiceException(message: 'Unexpected error: $error');
    }
  }

  /// Re-sends the signup confirmation code. Recovery codes are re-sent via
  /// [SupabaseService.auth.resetPasswordForEmail] instead (gotrue's `resend`
  /// only supports signup/emailChange).
  Future<void> resendSignupOtp({required String email}) async {
    try {
      await SupabaseService.auth.resend(email: email, type: OtpType.signup);
    } on AuthException catch (error) {
      throw _mapOtpException(error);
    } catch (error) {
      throw AuthServiceException(message: 'Unexpected error: $error');
    }
  }

  /// Maps gotrue auth errors for OTP verification/resend into distinct
  /// [AuthServiceException] codes so the UI can show targeted messages.
  AuthServiceException _mapOtpException(AuthException error) {
    final code = error.code;
    final normalized = error.message.toLowerCase();

    if (code == 'otp_expired' ||
        normalized.contains('expired') ||
        normalized.contains('invalid')) {
      return AuthServiceException(
        message: error.message,
        code: AuthServiceException.codeOtpInvalidOrExpired,
      );
    }
    if (code == 'over_email_send_rate_limit' ||
        code == 'over_request_rate_limit' ||
        normalized.contains('rate limit') ||
        normalized.contains('too many')) {
      return AuthServiceException(
        message: error.message,
        code: AuthServiceException.codeOtpRateLimited,
      );
    }
    return AuthServiceException(message: error.message);
  }

  Future<void> signOut() async {
    try {
      final userId = SupabaseService.auth.currentUser?.id;
      if (userId != null) {
        await PasswordRevisionService.clearCachedRevision(userId: userId);
      }
      await SupabaseService.auth.signOut();
      // Tear down the multiplexed /v2/ws connection so the new user (or
      // re-auth) gets a fresh socket with their token. Best-effort —
      // never blocks signOut on a hung socket teardown.
      await MultiplexSession.shutdown();
      // Drop any sandbox session ids we cached for this user's chats —
      // the next sign-in must not reuse them. Done BEFORE clearKey() so
      // that if EncryptionService.clearKey() throws, the cache is still
      // wiped (the user is already signed out at this point).
      SandboxSessionCache.clearAll();
      // Web: drop the local plaintext chat cache on logout. The next login
      // (e.g. after a password reset) then starts clean, so chats encrypted
      // with an old key correctly surface as locked. Native intentionally
      // keeps the cache — it's the user's own device and preserves access.
      if (kIsWeb && userId != null) {
        await LocalChatCacheService.clear(userId);
      }
      await EncryptionService.clearKey();
    } on AuthException catch (error) {
      throw AuthServiceException(message: error.message);
    } catch (error) {
      throw AuthServiceException(message: 'Unexpected error: $error');
    }
  }
}

class AuthServiceException implements Exception {
  const AuthServiceException({required this.message, this.code});

  final String message;
  final String? code;

  static const String codeEmailAlreadyRegistered = 'email_already_registered';
  static const String codeOtpInvalidOrExpired = 'otp_invalid_or_expired';
  static const String codeOtpRateLimited = 'otp_rate_limited';

  @override
  String toString() => message;
}
