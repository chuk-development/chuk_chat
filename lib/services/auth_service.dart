import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
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
      await SupabaseService.auth.signUp(
        email: email,
        password: password,
        data: {
          if (displayName != null && displayName.trim().isNotEmpty)
            'display_name': displayName,
        },
      );
    } on AuthException catch (error) {
      throw AuthServiceException(message: error.message);
    } catch (error) {
      throw AuthServiceException(message: 'Unexpected error: $error');
    }
  }

  Future<void> signOut() async {
    try {
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
  const AuthServiceException({required this.message});

  final String message;

  @override
  String toString() => message;
}
