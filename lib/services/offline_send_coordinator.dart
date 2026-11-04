// lib/services/offline_send_coordinator.dart
//
// Bridges the chat send flow to the offline outbox and the retry manager.
// Design: docs/OFFLINE_SEND.md. Keeps the payload schema
// ([OfflineSendPayload]) in one place so the executor reads the same shape
// the send paths write.
//
// Routing by chat kind ([ChatOrigin]):
//
// * a chuk_chat chat goes into [OfflineQueueService]; the executor sends it
//   once the network is back and writes the reply into the chat;
// * an Agents thread queues only the PROMPT in [AgentsTaskOutbox]. The run
//   belongs to the host, so the answer is never produced here.
// * a voice message goes into [OfflineQueueService] for both kinds: it must
//   be transcribed first. After that an Agents thread hands the text to
//   [AgentsTaskOutbox] ([OfflineRetryManager.registerAgentsHandoff]).
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/follow_up_parking_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/voice_spool_service.dart';

class OfflineSendPayload {
  const OfflineSendPayload({
    required this.chatId,
    required this.messageText,
    required this.modelId,
    required this.providerSlug,
    this.systemPrompt,
    this.imagesJson,
    this.attachmentsJson,
    this.attachedFilesJson,
    this.maxTokens,
    this.reasoningEffort,
    this.voicePath,
    this.voiceDurationMs,
    this.autoSend = true,
    this.resolvePromptAtSend = false,
  });

  factory OfflineSendPayload.fromJson(Map<String, dynamic> json) {
    return OfflineSendPayload(
      chatId: json['chatId'] as String? ?? '',
      messageText: json['messageText'] as String? ?? '',
      modelId: json['modelId'] as String? ?? '',
      providerSlug: json['providerSlug'] as String? ?? '',
      systemPrompt: json['systemPrompt'] as String?,
      imagesJson: json['imagesJson'] as String?,
      attachmentsJson: json['attachmentsJson'] as String?,
      attachedFilesJson: json['attachedFilesJson'] as String?,
      maxTokens: json['maxTokens'] is int ? json['maxTokens'] as int : null,
      reasoningEffort: json['reasoningEffort'] as String?,
      voicePath: json['voicePath'] as String?,
      voiceDurationMs: json['voiceDurationMs'] is int
          ? json['voiceDurationMs'] as int
          : null,
      autoSend: json['autoSend'] as bool? ?? true,
      resolvePromptAtSend: json['resolvePromptAtSend'] == true,
    );
  }

  final String chatId;

  /// Exactly what goes to the model: the typed text plus the documents
  /// (the composition step already put their markdown into it).
  final String messageText;
  final String modelId;
  final String providerSlug;
  final String? systemPrompt;

  /// JSON-encoded list of image storage paths. A path in the offline blob
  /// store is uploaded by the image preparer before the send.
  final String? imagesJson;

  /// JSON-encoded document attachments (file name + markdown).
  final String? attachmentsJson;

  /// JSON-encoded original AttachedFile list (for resend reconstruction).
  final String? attachedFilesJson;

  final int? maxTokens;
  final String? reasoningEffort;

  /// Voice: the saved WAV recording, until it is transcribed.
  final String? voicePath;
  final int? voiceDurationMs;

  /// Voice: send the transcript at once (the user's auto-send setting).
  /// Off: the row is held with the transcript until the user sends it.
  final bool autoSend;

  /// The row was queued with no system prompt (a follow-up the app parked
  /// while no screen held the chat): it is resolved at send time.
  final bool resolvePromptAtSend;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chatId': chatId,
    'messageText': messageText,
    'modelId': modelId,
    'providerSlug': providerSlug,
    if (systemPrompt != null && systemPrompt!.isNotEmpty)
      'systemPrompt': systemPrompt,
    if (imagesJson != null && imagesJson!.isNotEmpty) 'imagesJson': imagesJson,
    if (attachmentsJson != null && attachmentsJson!.isNotEmpty)
      'attachmentsJson': attachmentsJson,
    if (attachedFilesJson != null && attachedFilesJson!.isNotEmpty)
      'attachedFilesJson': attachedFilesJson,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    if (voicePath != null && voicePath!.isNotEmpty) 'voicePath': voicePath,
    if (voiceDurationMs != null) 'voiceDurationMs': voiceDurationMs,
    if (!autoSend) 'autoSend': false,
    if (resolvePromptAtSend) 'resolvePromptAtSend': true,
  };

  List<String>? get images {
    final json = imagesJson;
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return null;
  }
}

/// Convenience wrapper around [OfflineQueueService] + [OfflineRetryManager].
class OfflineSendCoordinator {
  OfflineSendCoordinator._();

  /// Enqueue a text payload for later send. Returns the queue id assigned to
  /// it; the caller writes it into the bubble's `queueId`.
  ///
  /// [kick] starts a flush at once (the send failed while the network may
  /// still be there, or the chat already has rows waiting).
  static Future<String> enqueue(
    OfflineSendPayload payload, {
    bool kick = false,
  }) async {
    if (ChatOrigin.isAgentsThread(payload.chatId)) {
      return _enqueueAgentsPrompt(payload);
    }
    if (kDebugMode) {
      debugPrint(
        '[OfflineSend] enqueue chat=${payload.chatId} '
        'text_len=${payload.messageText.length}',
      );
    }
    final id = await OfflineQueueService.instance.enqueue(
      chatId: payload.chatId,
      sendPayload: payload.toJson(),
    );
    if (kick) OfflineRetryManager.instance.kick('enqueue');
    return id;
  }

  /// Enqueue a voice message whose recording is saved at
  /// [OfflineSendPayload.voicePath] but not transcribed yet. Both chat kinds
  /// use the chat outbox for this; see the file comment.
  static Future<String> enqueueVoice(
    OfflineSendPayload payload, {
    bool kick = false,
  }) async {
    final id = await OfflineQueueService.instance.enqueue(
      chatId: payload.chatId,
      sendPayload: payload.toJson(),
      kind: OutboxKind.voice,
    );
    if (kick) OfflineRetryManager.instance.kick('enqueue-voice');
    return id;
  }

  /// Whether [chatId] has rows waiting. A new message in such a chat is
  /// queued behind them, so it cannot overtake them.
  /// Failed and held rows do not count: they wait for the user, and a new
  /// message must not wait behind them.
  static bool hasQueuedFor(String chatId) =>
      OfflineRetryManager.instance.rows.value.values.any(
        (r) =>
            r.chatId == chatId &&
            r.state != OutboxState.failed &&
            r.state != OutboxState.held,
      );

  /// The row behind a bubble, or null.
  static QueuedMessage? rowFor(String? queueId) => queueId == null
      ? null
      : OfflineRetryManager.instance.rows.value[queueId];

  /// AGENTS: the payload's [OfflineSendPayload.chatId] IS the executor's
  /// `session_key`, so the prompt queues under the key the flush sends it on.
  static Future<String> _enqueueAgentsPrompt(OfflineSendPayload payload) async {
    final images = payload.images;
    if (images != null && images.isNotEmpty) {
      // No image channel to the host yet: the text is queued, and the user
      // is told the image is not sent (same notice as a live send).
      AgentsChatTransport.notify(
        AgentsSendNotice(
          kind: AgentsSendNoticeKind.imagesNotSupported,
          sessionKey: payload.chatId,
          count: images.length,
        ),
      );
    }
    final OutboxTask task = await AgentsTaskOutbox.enqueue(
      sessionKey: payload.chatId,
      prompt: payload.messageText,
      modelId: payload.modelId.isEmpty ? null : payload.modelId,
      providerSlug: payload.providerSlug.isEmpty ? null : payload.providerSlug,
      reasoningEffort: payload.reasoningEffort,
    );
    return task.localId;
  }

  /// AGENTS: hands a prepared (transcribed) row of an Agents thread to the
  /// Agents outbox. Registered with [OfflineRetryManager.registerAgentsHandoff].
  static Future<SendExecutorResult> agentsHandoff(QueuedMessage row) async {
    final payload = payloadFrom(row);
    if (payload.messageText.trim().isEmpty) {
      return const SendExecutorResult.deferred('not transcribed yet');
    }
    final task = await AgentsTaskOutbox.enqueue(
      sessionKey: row.chatId,
      prompt: payload.messageText,
      modelId: payload.modelId.isEmpty ? null : payload.modelId,
      providerSlug: payload.providerSlug.isEmpty ? null : payload.providerSlug,
      reasoningEffort: payload.reasoningEffort,
    );
    // The bubble now belongs to the Agents outbox entry.
    await editQueuedMessage(row.chatId, row.id, (m) {
      m['text'] = payload.messageText;
      m['queueId'] = task.localId;
      m['status'] = 'pending';
      return m;
    });
    return const SendExecutorResult.success();
  }

  /// Triggers an immediate drain of the queue.
  static Future<void> retryNow() => OfflineRetryManager.instance.retryNow();

  /// Manual Retry of one row (also "Send" on a held voice transcript).
  static Future<void> retryRow(String queueId) async {
    final row = rowFor(queueId) ??
        await OfflineQueueService.instance.getById(queueId);
    if (row == null) {
      // Not a chat outbox row: an Agents outbox entry (failed ones go back
      // to pending), then the usual retry.
      await _bestEffort(() async {
        await AgentsTaskOutbox.requeueByLocalId(queueId);
      });
      return retryNow();
    }
    if (row.state == OutboxState.held) {
      // The user confirmed the transcript: send it now.
      await OfflineQueueService.instance.updatePayload(queueId, {
        ...row.sendPayload,
        'autoSend': true,
      });
    }
    await OfflineRetryManager.instance.retryRow(queueId);
  }

  /// Delete: drops the row, its files and the bubble.
  static Future<void> discard(String queueId) async {
    final row = await OfflineQueueService.instance.getById(queueId);
    await OfflineQueueService.instance.remove(queueId);
    if (row == null) {
      // An Agents prompt, or a bubble whose row is already gone: the entry
      // (if any) and the bubble both go.
      String? chatId;
      await _bestEffort(() async {
        chatId = (await AgentsTaskOutbox.findByLocalId(queueId))?.sessionKey;
        await AgentsTaskOutbox.discardByLocalId(queueId);
      });
      chatId ??= ChatStorageService.selectedChatId;
      final String? target = chatId;
      if (target != null && target.isNotEmpty) {
        await _bestEffort(() => removeQueuedMessage(target, queueId));
        OfflineRetryManager.instance.notify(
          OfflineRetryEvent(
            type: OfflineRetryEventType.discarded,
            queueId: queueId,
            chatId: target,
          ),
        );
      }
      return;
    }
    await OfflineRetryManager.instance.runCleanup([row]);
    await removeQueuedMessage(row.chatId, queueId);
    OfflineRetryManager.instance.notify(
      OfflineRetryEvent(
        type: OfflineRetryEventType.discarded,
        queueId: queueId,
        chatId: row.chatId,
      ),
    );
  }

  /// Sign-out: wipes every row of [userId] and their files.
  static Future<void> wipeUser(String userId) async {
    try {
      final gone = await OfflineQueueService.instance.wipeUser(userId);
      await OfflineRetryManager.instance.runCleanup(gone);
      await OfflineRetryManager.instance.refreshRows();
    } catch (e) {
      if (kDebugMode) debugPrint('[OfflineSend] wipe failed: $e');
    }
    // Files that belong to no row any more, and the parked follow-ups.
    await _bestEffort(() => VoiceSpoolService.wipeUser(userId));
    await _bestEffort(() => VoiceSpoolService.wipeUser('anon'));
    await _bestEffort(() => ImageStorageService.wipeOfflineImages(userId));
    await _bestEffort(() => FollowUpParkingService.wipeUser(userId));
    await _bestEffort(AgentsTaskOutbox.wipeAll);
  }

  static Future<void> _bestEffort(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  // ── Edits of the stored chat ────────────────────────────────────────

  /// Applies [edit] to the user message whose `queueId` is [queueId] in the
  /// stored chat, and saves the chat on this device. Returns false when the
  /// chat or the message is not found.
  static Future<bool> editQueuedMessage(
    String chatId,
    String queueId,
    Map<String, dynamic> Function(Map<String, dynamic> message) edit,
  ) async {
    final chat = await ChatStorageService.loadFullChat(chatId);
    if (chat == null) return false;
    final maps = chat.messages.map((m) => m.toJson()).toList();
    var found = false;
    for (var i = 0; i < maps.length; i++) {
      if (maps[i]['queueId'] == queueId) {
        maps[i] = edit(Map<String, dynamic>.of(maps[i]));
        found = true;
        break;
      }
    }
    if (!found) return false;
    await ChatStorageService.saveLocal(maps, chatId: chatId);
    return true;
  }

  /// Writes a voice transcript into its bubble.
  static Future<bool> applyTranscript(
    String chatId,
    String queueId,
    String text,
  ) => editQueuedMessage(chatId, queueId, (m) {
    m['text'] = text;
    return m;
  });

  /// Replaces image paths in a bubble (offline blob -> uploaded path).
  /// [mapping] maps old path to new path; `images` and `attachedFilesJson`
  /// are both rewritten.
  static Future<bool> replaceMessageImages(
    String chatId,
    String queueId,
    Map<String, String> mapping,
  ) => editQueuedMessage(chatId, queueId, (m) {
    for (final key in const ['images', 'attachedFilesJson']) {
      final v = m[key];
      if (v is String && v.isNotEmpty) {
        var s = v;
        mapping.forEach((from, to) => s = s.replaceAll(from, to));
        m[key] = s;
      }
    }
    return m;
  });

  /// Removes the bubble of a deleted row.
  static Future<void> removeQueuedMessage(String chatId, String queueId) async {
    final chat = await ChatStorageService.loadFullChat(chatId);
    if (chat == null) return;
    final kept = chat.messages
        .where((ChatMessage m) => m.queueId != queueId)
        .map((m) => m.toJson())
        .toList();
    if (kept.length == chat.messages.length) return;
    await ChatStorageService.saveLocal(kept, chatId: chatId);
  }

  /// Helper to decode a [QueuedMessage]'s payload back into a typed value.
  static OfflineSendPayload payloadFrom(QueuedMessage msg) =>
      OfflineSendPayload.fromJson(msg.sendPayload);
}
