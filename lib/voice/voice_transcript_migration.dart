import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart'
    show voiceTurnMessageId;
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/voice/voice_call_store.dart';

/// Migrates only the selected, already-loaded chat (at most 200 old calls).
/// No account-wide scan or network fetch delays its initial paint.
class VoiceTranscriptMigration {
  VoiceTranscriptMigration({
    required this.getChat,
    required this.updateChat,
    required this.ownership,
  });

  static final shared = VoiceTranscriptMigration(
    getChat: ChatStorageService.getChatById,
    updateChat: ChatStorageService.updateChat,
    ownership: () =>
        EncryptionService.hasKey && SupabaseService.auth.currentUser != null
        ? (SupabaseService.auth.currentUser?.id, EncryptionService.keyIdentity)
        : null,
  );

  final StoredChat? Function(String) getChat;
  final Future<StoredChat?> Function(String, List<Map<String, dynamic>>)
  updateChat;

  /// Null while locked; equality changes with account or key ownership.
  final Object? Function() ownership;
  final Map<String, Future<StoredChat?>> _inFlight = {};

  Future<StoredChat?> migrate(String chatId) {
    final owner = ownership();
    if (owner == null || chatId.isEmpty) return Future.value();
    return _inFlight.putIfAbsent(chatId, () async {
      try {
        return await _migrate(chatId, owner);
      } on Object catch (error) {
        // Keep legacy rows for a retry on the next selection.
        if (kDebugMode) {
          debugPrint('[VoiceMigration] save failed: ${error.runtimeType}');
        }
        return null;
      } finally {
        _inFlight.remove(chatId);
      }
    });
  }

  Future<StoredChat?> _migrate(String chatId, Object owner) async {
    bool stillOwned() => ownership() == owner;
    final initial = getChat(chatId);
    if (initial == null || !initial.isFullyLoaded || initial.isLocked) {
      return null;
    }
    final records = await VoiceCallStore.forChat(chatId);
    if (!stillOwned() || !records.any((r) => r.turns.isNotEmpty)) return null;
    // Re-read after the asynchronous legacy read, preserving newly typed rows
    // and EVERY persisted field, including images, attachments and variants.
    final chat = getChat(chatId);
    if (chat == null || !chat.isFullyLoaded || chat.isLocked) return null;
    final rows = [for (final message in chat.messages) message.toJson()];
    final ids = {for (final row in rows) row['messageId']};
    final migratedIds = <String>{};
    for (final record in records) {
      for (final turn in record.turns) {
        final id = voiceTurnMessageId(turn);
        migratedIds.add(id);
        // An ordinary row already owns this identity; never downgrade it.
        if (!ids.add(id)) continue;
        rows.add({
          'role': turn.role,
          'text': turn.text,
          'messageId': id,
          'sentAt': turn.at.toUtc().toIso8601String(),
        });
      }
    }
    if (!stillOwned()) return null;
    final saved = await updateChat(chatId, rows);
    if (!stillOwned() || saved == null || !saved.isFullyLoaded) return null;
    final savedIds = {for (final message in saved.messages) message.messageId};
    // A superseding ordinary save can win the store's write queue. Leave the
    // source intact unless the returned saved payload contains every turn.
    if (!savedIds.containsAll(migratedIds)) return null;
    bool canRemoveSource() {
      if (!stillOwned()) return false;
      final current = getChat(chatId);
      return current != null &&
          current.isFullyLoaded &&
          !current.isLocked &&
          {for (final message in current.messages) message.messageId}
              .containsAll(migratedIds);
    }

    await VoiceCallStore.removeMigratedTurns(
      chatId,
      records,
      stillOwned: canRemoveSource,
    );
    return stillOwned() ? saved : null;
  }
}
