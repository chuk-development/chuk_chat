import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/session_tracking_service.dart';
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

  Future<void> signOut() async {
    try {
      await SessionTrackingService.deactivateCurrentSession();
      final userId = SupabaseService.auth.currentUser?.id;
      if (userId != null) {
        await PasswordRevisionService.clearCachedRevision(userId: userId);
      }
      await SupabaseService.auth.signOut();
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

  @override
  String toString() => message;
}
