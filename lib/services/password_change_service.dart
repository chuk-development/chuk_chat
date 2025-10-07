import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
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
      await _rotateChatsForPasswordChange(
        chatsSnapshot: chatsSnapshot,
        fromPassword: trimmedCurrent,
        toPassword: trimmedNew,
      );
    } on StateError catch (error) {
      throw PasswordChangeException(error.message);
    } catch (error) {
      throw PasswordChangeException(
        'Failed to prepare encrypted chats for the new password: $error',
      );
    }

    try {
      await SupabaseService.auth.updateUser(
        UserAttributes(password: trimmedNew),
      );
    } on AuthException catch (error) {
      final restored = await _tryRestoreEncryption(
        chatsSnapshot: chatsSnapshot,
        currentPassword: trimmedNew,
        previousPassword: trimmedCurrent,
      );
      final reason = restored
          ? 'Supabase rejected the password change: ${error.message}'
          : 'Supabase rejected the password change and the encrypted chats could not be restored: ${error.message}';
      throw PasswordChangeException(reason);
    } catch (error) {
      final restored = await _tryRestoreEncryption(
        chatsSnapshot: chatsSnapshot,
        currentPassword: trimmedNew,
        previousPassword: trimmedCurrent,
      );
      final reason = restored
          ? 'Failed to update password: $error'
          : 'Failed to update password and the encrypted chats could not be restored: $error';
      throw PasswordChangeException(reason);
    }

    try {
      await PasswordRevisionService.bumpRevision(user);
    } on AuthException catch (error) {
      throw PasswordChangeException(
        'Password was updated but notifying other sessions failed: ${error.message}',
      );
    } catch (error) {
      throw PasswordChangeException(
        'Password was updated but notifying other sessions failed: $error',
      );
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

  Future<void> _rotateChatsForPasswordChange({
    required List<StoredChat> chatsSnapshot,
    required String fromPassword,
    required String toPassword,
  }) async {
    await EncryptionService.rotateKeyForPasswordChange(
      currentPassword: fromPassword,
      newPassword: toPassword,
      migrateWithNewKey: () async {
        await ChatStorageService.reencryptChats(chatsSnapshot);
      },
      rollbackWithOldKey: () async {
        await ChatStorageService.reencryptChats(chatsSnapshot);
      },
    );
  }

  Future<bool> _tryRestoreEncryption({
    required List<StoredChat> chatsSnapshot,
    required String currentPassword,
    required String previousPassword,
  }) async {
    try {
      await _rotateChatsForPasswordChange(
        chatsSnapshot: chatsSnapshot,
        fromPassword: currentPassword,
        toPassword: previousPassword,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

class PasswordChangeException implements Exception {
  const PasswordChangeException(this.message);

  final String message;

  @override
  String toString() => message;
}
