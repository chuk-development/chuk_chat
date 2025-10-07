import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class PasswordChangeService {
  const PasswordChangeService();

  Future<String> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final trimmedCurrent = currentPassword.trim();
    final trimmedNew = newPassword.trim();

    if (trimmedCurrent.isEmpty) {
      throw const PasswordChangeException(
        'Enter your current password to continue.',
      );
    }
    if (trimmedNew.isEmpty) {
      throw const PasswordChangeException('Enter a new password.');
    }
    if (trimmedNew.length < 8) {
      throw const PasswordChangeException(
        'Choose a password with at least 8 characters.',
      );
    }
    if (trimmedCurrent == trimmedNew) {
      throw const PasswordChangeException(
        'New password must be different from your current password.',
      );
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw const PasswordChangeException(
        'You need to be signed in to change your password.',
      );
    }

    try {
      await EncryptionService.initializeForPassword(trimmedCurrent);
    } on StateError catch (error) {
      throw PasswordChangeException(error.message);
    }

    await ChatStorageService.loadChats();
    final chatsSnapshot = ChatStorageService.savedChats
        .map(
          (chat) =>
              chat.copyWith(messages: List<ChatMessage>.from(chat.messages)),
        )
        .toList();

    try {
      await SupabaseService.auth.updateUser(
        UserAttributes(password: trimmedNew),
      );
    } on AuthException catch (error) {
      throw PasswordChangeException(
        'Supabase rejected the password change: ${error.message}',
      );
    } catch (error) {
      throw PasswordChangeException('Failed to update password: $error');
    }

    try {
      await EncryptionService.rotateKeyForPasswordChange(
        currentPassword: trimmedCurrent,
        newPassword: trimmedNew,
        migrateWithNewKey: () async {
          await ChatStorageService.reencryptChats(chatsSnapshot);
        },
        rollbackWithOldKey: () async {
          await ChatStorageService.reencryptChats(chatsSnapshot);
        },
      );
    } on StateError catch (error) {
      await _tryRevertSupabasePassword(trimmedCurrent);
      throw PasswordChangeException(error.message);
    } catch (error) {
      await _tryRevertSupabasePassword(trimmedCurrent);
      throw PasswordChangeException('Failed to update encrypted chats: $error');
    }

    final email = user.email;
    if (email == null || email.isEmpty) {
      throw const PasswordChangeException(
        'Password updated but no email address is available to send a confirmation.',
      );
    }

    try {
      await SupabaseService.auth.signInWithOtp(email: email);
    } on AuthException catch (error) {
      throw PasswordChangeException(
        'Password updated but sending the confirmation email failed: ${error.message}',
      );
    } catch (error) {
      throw PasswordChangeException(
        'Password updated but sending the confirmation email failed: $error',
      );
    }

    await ChatStorageService.loadChats();
    return 'Password updated. Check $email to confirm the change.';
  }

  Future<void> _tryRevertSupabasePassword(String password) async {
    try {
      await SupabaseService.auth.updateUser(UserAttributes(password: password));
    } catch (_) {
      // Ignore failures while trying to undo a partial change.
    }
  }
}

class PasswordChangeException implements Exception {
  const PasswordChangeException(this.message);

  final String message;

  @override
  String toString() => message;
}
