import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_crud.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/key_version_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Exception thrown by password reset recovery operations.
class RecoveryException implements Exception {
  final String message;
  const RecoveryException(this.message);

  @override
  String toString() => message;
}

/// Service for recovering or deleting chats encrypted with old keys
/// after a password reset.
class PasswordResetService {
  const PasswordResetService._();

  /// Get info about locked chats: map of key version → count.
  static Map<int, int> getLockedChatInfo() {
    final counts = <int, int>{};
    for (final chat in ChatStorageService.savedChats) {
      if (chat.isLocked) {
        // Legacy chats without kv field are assumed to be key version 1
        final version = chat.keyVersion ?? 1;
        counts[version] = (counts[version] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Total number of locked chats across all key versions.
  static int get lockedChatCount {
    return ChatStorageService.savedChats.where((c) => c.isLocked).length;
  }

  /// Attempt to recover all locked chats for a specific key version
  /// using the old password. Returns the number of recovered chats.
  ///
  /// Throws [RecoveryException] if the password is wrong or recovery fails.
  static Future<int> recoverChatsWithOldPassword({
    required String oldPassword,
    required int targetVersion,
    ValueChanged<String>? onProgress,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw const RecoveryException('Not authenticated.');
    }

    // 1. Find the salt for this key version
    final salt = KeyVersionService.getSaltForVersion(user, targetVersion);
    if (salt == null) {
      throw RecoveryException(
        'No encryption data found for key version $targetVersion.',
      );
    }

    onProgress?.call('Deriving encryption key...');

    // 2. Derive the old key (this is slow — 600k PBKDF2 iterations)
    final oldKey = await KeyVersionService.deriveKeyForVersion(
      oldPassword,
      salt,
    );

    // 3. Get all locked chats for this version (null keyVersion = legacy = version 1)
    final lockedChats = ChatStorageService.savedChats
        .where((c) => c.isLocked && (c.keyVersion ?? 1) == targetVersion)
        .toList();

    if (lockedChats.isEmpty) {
      throw const RecoveryException('No locked chats found for this version.');
    }

    onProgress?.call('Verifying password...');

    // 4. Fetch encrypted payloads from Supabase for these chats
    final chatIds = lockedChats.map((c) => c.id).toList();
    final rows = await SupabaseService.client
        .from('encrypted_chats')
        .select('id, encrypted_payload, encrypted_title, created_at, updated_at, is_starred')
        .eq('user_id', user.id)
        .inFilter('id', chatIds)
        .timeout(const Duration(seconds: 30));

    if (rows.isEmpty) {
      throw const RecoveryException('Could not fetch encrypted chats.');
    }

    // 5. Try to decrypt first payload to verify password
    final firstPayload = rows.first['encrypted_payload'] as String?;
    if (firstPayload == null || firstPayload.isEmpty) {
      throw const RecoveryException('Chat data is missing or corrupted.');
    }
    final testDecrypt = await EncryptionService.tryDecryptWithKey(
      firstPayload,
      oldKey,
    );
    if (testDecrypt == null) {
      throw const RecoveryException(
        'Wrong password. The chats could not be decrypted.',
      );
    }

    // 6. Decrypt all payloads
    final payloads = rows
        .map((r) => r['encrypted_payload'] as String?)
        .whereType<String>()
        .toList();
    if (payloads.length != rows.length) {
      throw const RecoveryException('Some chat data is missing or corrupted.');
    }
    final decrypted = await EncryptionService.tryDecryptBatchWithKey(
      payloads,
      oldKey,
    );

    // 7. Re-encrypt each chat with the current key
    int recoveredCount = 0;
    for (int i = 0; i < rows.length; i++) {
      final row = rows[i];
      final plaintext = decrypted[i];
      if (plaintext == null) continue;

      final chatId = row['id'] as String;
      onProgress?.call('Recovering chat ${i + 1} of ${rows.length}...');

      try {
        // Re-encrypt payload with current key
        final newEncPayload = await EncryptionService.encrypt(plaintext);

        // Re-encrypt title if present
        String? newEncTitle;
        final encTitle = row['encrypted_title'] as String?;
        if (encTitle != null && encTitle.isNotEmpty) {
          final plainTitle = await EncryptionService.tryDecryptWithKey(
            encTitle,
            oldKey,
          );
          if (plainTitle != null) {
            newEncTitle = await EncryptionService.encrypt(plainTitle);
          }
        }

        // Update Supabase with re-encrypted data.
        // If title re-encryption failed, clear it to avoid orphaned old-key ciphertext.
        final updateData = <String, dynamic>{
          'encrypted_payload': newEncPayload,
          'encrypted_title': newEncTitle,
        };

        await SupabaseService.client
            .from('encrypted_chats')
            .update(updateData)
            .eq('id', chatId)
            .eq('user_id', user.id)
            .timeout(const Duration(seconds: 10));

        recoveredCount++;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to recover chat $chatId: $e');
        }
        // Continue with other chats — partial recovery is acceptable
      }
    }

    // 8. If all chats recovered, remove old key entry
    if (recoveredCount == rows.length) {
      final updatedUser = await KeyVersionService.removePreviousKey(
        user,
        targetVersion,
      );
      if (kDebugMode && updatedUser != null) {
        debugPrint('Removed previous key version $targetVersion');
      }
    }

    // 9. Reload chats to refresh state
    await ChatStorageService.loadChats();

    return recoveredCount;
  }

  /// Delete all locked chats for a specific key version.
  /// Returns the number of deleted chats.
  static Future<int> deleteLockedChats({
    required int keyVersion,
    ValueChanged<String>? onProgress,
  }) async {
    final lockedChats = ChatStorageService.savedChats
        .where((c) => c.isLocked && (c.keyVersion ?? 1) == keyVersion)
        .toList();

    if (lockedChats.isEmpty) return 0;

    int deletedCount = 0;
    for (int i = 0; i < lockedChats.length; i++) {
      final chat = lockedChats[i];
      onProgress?.call('Deleting chat ${i + 1} of ${lockedChats.length}...');
      try {
        await ChatStorageCrud.deleteChat(chat.id);
        deletedCount++;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to delete locked chat ${chat.id}: $e');
        }
      }
    }

    // If all deleted, clean up previous key entry
    if (deletedCount == lockedChats.length) {
      final user = SupabaseService.auth.currentUser;
      if (user != null) {
        await KeyVersionService.removePreviousKey(user, keyVersion);
      }
    }

    // Reload chats to refresh state
    await ChatStorageService.loadChats();

    return deletedCount;
  }
}
