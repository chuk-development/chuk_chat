// lib/services/auth_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';

class AuthService {
  AuthService._();

  static final SupabaseClient _client = Supabase.instance.client;

  static Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  static User? get currentUser => _client.auth.currentUser;

  static Future<void> sendEmailOtp(String email) {
    return _client.auth.signInWithOtp(
      email: email,
      shouldCreateUser: true,
    );
  }

  static Future<void> verifyEmailOtp({required String email, required String token}) async {
    await _client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.email,
    );
  }

  static Future<void> signOut() async {
    await _client.auth.signOut();
    ChatStorageService.clearCachedChats();
  }
}
