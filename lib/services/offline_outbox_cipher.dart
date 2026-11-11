// lib/services/offline_outbox_cipher.dart
//
// Encryption at rest for the offline outbox. The queued payload holds the
// message text, the system prompt and inline images, so it is sealed with
// the user's chat key ([EncryptionService.encrypt], AES-256-GCM), the same
// key that seals the chats in the cloud.
//
// The hooks are static so tests can swap them for a fake cipher and a fixed
// user id without Supabase or a key.
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

abstract final class OutboxCipher {
  /// Seals [plaintext]. Returns null when no key is loaded: the store then
  /// keeps the row in plaintext and seals it on the next open with a key
  /// ([OfflineQueueService.sealPlaintextRows]). A message typed before the
  /// key is ready must not be lost.
  static Future<String?> Function(String plaintext) seal = _defaultSeal;

  /// Opens a value made by [seal]. Throws when the key is wrong or missing.
  static Future<String> Function(String sealed) open = _defaultOpen;

  /// Whether [open] can work right now.
  static bool Function() canOpen = _defaultCanOpen;

  /// The signed-in user, or null.
  static String? Function() currentUserId = _defaultUserId;

  static Future<String?> _defaultSeal(String plaintext) async {
    if (!EncryptionService.hasKey) return null;
    return EncryptionService.encrypt(plaintext);
  }

  static Future<String> _defaultOpen(String sealed) =>
      EncryptionService.decrypt(sealed);

  static bool _defaultCanOpen() => EncryptionService.hasKey;

  static String? _defaultUserId() {
    try {
      if (!SupabaseService.isInitialized) return null;
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void useFake({required String? userId, bool withKey = true}) {
    seal = (p) async => withKey ? 'sealed:${_rot(p)}' : null;
    open = (s) async {
      if (!s.startsWith('sealed:')) throw StateError('not sealed');
      return _rot(s.substring(7));
    };
    canOpen = () => withKey;
    currentUserId = () => userId;
  }

  @visibleForTesting
  static void reset() {
    seal = _defaultSeal;
    open = _defaultOpen;
    canOpen = _defaultCanOpen;
    currentUserId = _defaultUserId;
  }

  // Reversible scramble so a test can prove the stored text is not the
  // plaintext. Not cryptography; production uses AES-GCM.
  static String _rot(String s) =>
      String.fromCharCodes(s.runes.map((r) => r ^ 0x1));
}
