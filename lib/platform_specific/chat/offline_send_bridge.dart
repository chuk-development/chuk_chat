// lib/platform_specific/chat/offline_send_bridge.dart
//
// What the mobile and the desktop chat screen share for the offline outbox
// (docs/OFFLINE_SEND.md): the decision to queue a send, the bubble update
// after a queue, and the reload when the outbox changed a chat.
import 'dart:async';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/dictation_tracker.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

abstract final class OfflineSendBridge {
  /// Whether a new send in [chatId] goes into the outbox instead of the
  /// socket: the device is offline, the chat already has rows waiting (a new
  /// message must not overtake them), or an image is only in the offline
  /// store (it must be uploaded first).
  static bool mustQueue(String chatId, {List<String>? imagePaths}) {
    if (!NetworkStatusService.isOnline) return true;
    if (ChatOrigin.isAgentsThread(chatId)) return false;
    if (OfflineSendCoordinator.hasQueuedFor(chatId)) return true;
    return imagePaths != null &&
        imagePaths.any(ImageStorageService.isOfflinePath);
  }

  /// Marks the user bubble at [userIdx] as waiting for [queueId] and drops
  /// the "Thinking..." placeholder at [placeholderIdx].
  static void markQueued(
    List<Map<String, String>> messages, {
    required int userIdx,
    required int placeholderIdx,
    required String queueId,
  }) {
    if (userIdx >= 0 && userIdx < messages.length) {
      messages[userIdx]['status'] = 'pending';
      messages[userIdx]['queueId'] = queueId;
      messages[userIdx].remove('lastError');
    }
    dropPlaceholder(messages, placeholderIdx);
  }

  /// The queue itself failed (disk full, no database): the bubble shows
  /// failed so the text is not silently gone.
  static void markEnqueueFailed(
    List<Map<String, String>> messages, {
    required int userIdx,
    required int placeholderIdx,
    required String error,
  }) {
    if (userIdx >= 0 && userIdx < messages.length) {
      messages[userIdx]['status'] = 'failed';
      messages[userIdx]['lastError'] = error;
    }
    dropPlaceholder(messages, placeholderIdx);
  }

  /// Removes the placeholder at [index] when it is still empty. A
  /// placeholder that already has text (a cut reply) stays.
  static void dropPlaceholder(List<Map<String, String>> messages, int index) {
    if (index < 0 || index >= messages.length) return;
    final m = messages[index];
    if (m['sender'] == 'user') return;
    final text = m['text'] ?? '';
    if (text.isEmpty || text == 'Thinking...') messages.removeAt(index);
  }

  /// Listens to outbox events that changed a stored chat (a reply written,
  /// a transcript or an image path applied, a row deleted or failed) and
  /// calls [onChatChanged] with the chat id.
  static StreamSubscription<OfflineRetryEvent> listen(
    void Function(String chatId) onChatChanged,
  ) => OfflineRetryManager.instance.events.listen((e) {
    final chatId = e.chatId;
    if (chatId == null || chatId.isEmpty) return;
    switch (e.type) {
      case OfflineRetryEventType.success:
      case OfflineRetryEventType.updated:
      case OfflineRetryEventType.discarded:
        onChatChanged(chatId);
      default:
        break;
    }
  });

  /// True when [queueId] names a row that still waits.
  static bool isWaiting(String? queueId) {
    final row = OfflineSendCoordinator.rowFor(queueId);
    return row != null && row.state != OutboxState.failed;
  }

  /// The user bubble of a voice message whose recording is saved but not
  /// transcribed yet. Its text arrives with the transcript.
  static Map<String, String> voiceBubble({
    required String queueId,
    required int? durationMs,
    required String modelId,
    required String provider,
  }) => <String, String>{
    'sender': 'user',
    'text': '',
    'reasoning': '',
    'modelId': modelId,
    'provider': provider,
    'sentAt': DateTime.now().toIso8601String(),
    VoiceInputKeys.inputMode: VoiceInputKeys.voice,
    if (durationMs != null) VoiceInputKeys.durationMs: '$durationMs',
    'status': 'pending',
    'queueId': queueId,
  };
}
