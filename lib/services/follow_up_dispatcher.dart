// lib/services/follow_up_dispatcher.dart
//
// Sends follow-ups the user typed while a reply streamed, when no screen
// holds their chat any more (docs/OFFLINE_SEND.md, "Follow-ups").
//
// The chat screen keeps such follow-ups in memory and sends them when its
// turn ends; [FollowUpParkingService] keeps a copy on disk. When the user
// leaves the chat before the turn ends, or the app is killed, the screen no
// longer sends them. This service does: once the chat's turn is over and no
// screen shows the chat, every parked follow-up becomes an outbox row with a
// waiting bubble at the end of the chat. The outbox then sends it the normal
// way (headless, with tools), in order.
//
// A chat on screen is left alone: the screen restores and sends its own
// parked follow-ups when it opens the chat.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/follow_up_parking_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';

class FollowUpDispatcher {
  FollowUpDispatcher._();

  static final FollowUpDispatcher instance = FollowUpDispatcher._();

  /// How long a chat must be idle (no turn) before its follow-ups go out.
  /// The screen's background save of the finished answer lands in this
  /// time, so the follow-up is put after the answer, not before it.
  static Duration settle = const Duration(seconds: 3);

  /// How often a parked chat is looked at while one waits.
  static Duration pollEvery = const Duration(seconds: 3);

  // ── Test seams ──────────────────────────────────────────────────────
  @visibleForTesting
  static bool Function(String chatId) isOnScreen = _defaultOnScreen;
  @visibleForTesting
  static bool Function(String chatId) isTurnRunning =
      OfflineSendExecutor.isTurnRunning;
  @visibleForTesting
  static Future<String> Function(OfflineSendPayload payload) enqueue =
      _defaultEnqueue;
  @visibleForTesting
  static DateTime Function() now = DateTime.now;
  @visibleForTesting
  static void Function() kickOutbox = _defaultKickOutbox;
  @visibleForTesting
  static Future<StoredChat?> Function(String chatId) loadChat =
      ChatStorageService.loadFullChat;
  @visibleForTesting
  static Future<void> Function(String chatId, List<Map<String, dynamic>> maps)
  saveChat = _defaultSave;

  static Future<void> _defaultSave(
    String chatId,
    List<Map<String, dynamic>> maps,
  ) async {
    await ChatStorageService.saveLocal(maps, chatId: chatId);
  }

  static void _defaultKickOutbox() =>
      OfflineRetryManager.instance.kick('follow-up');

  static bool _defaultOnScreen(String chatId) =>
      OfflineSendExecutor.screenFor(chatId) != null;

  static Future<String> _defaultEnqueue(OfflineSendPayload payload) =>
      OfflineSendCoordinator.enqueue(payload);

  @visibleForTesting
  static void resetSeams() {
    isOnScreen = _defaultOnScreen;
    isTurnRunning = OfflineSendExecutor.isTurnRunning;
    enqueue = _defaultEnqueue;
    now = DateTime.now;
    kickOutbox = _defaultKickOutbox;
    loadChat = ChatStorageService.loadFullChat;
    saveChat = _defaultSave;
    settle = const Duration(seconds: 3);
    pollEvery = const Duration(seconds: 3);
    instance._reset();
  }

  final Map<String, DateTime> _idleSince = <String, DateTime>{};
  Timer? _timer;
  bool _running = false;
  bool _again = false;

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _idleSince.clear();
    _running = false;
    _again = false;
  }

  /// Looks at every parked chat now, and again later while one waits.
  void kick() => unawaited(runOnce());

  /// One pass over the parked chats. Returns how many follow-ups went into
  /// the outbox.
  Future<int> runOnce() async {
    if (_running) {
      _again = true;
      return 0;
    }
    _running = true;
    var queued = 0;
    var waiting = false;
    try {
      do {
        _again = false;
        final String? user = OutboxCipher.currentUserId();
        if (user == null) break;
        final List<String> chats = await FollowUpParkingService.parkedChats();
        for (final String chatId in chats) {
          final ({int queued, bool waiting}) r = await _dispatch(chatId);
          queued += r.queued;
          waiting = waiting || r.waiting;
        }
      } while (_again);
    } catch (e) {
      if (kDebugMode) debugPrint('[FollowUpDispatcher] pass failed: $e');
    } finally {
      _running = false;
    }
    _timer?.cancel();
    _timer = waiting ? Timer(pollEvery, kick) : null;
    return queued;
  }

  /// [chatId]: parked follow-ups to the outbox when the chat is free.
  Future<({int queued, bool waiting})> _dispatch(String chatId) async {
    if (isOnScreen(chatId)) {
      // The screen owns them; it sends them when its turn ends.
      _idleSince.remove(chatId);
      return (queued: 0, waiting: false);
    }
    if (isTurnRunning(chatId)) {
      _idleSince.remove(chatId);
      return (queued: 0, waiting: true);
    }
    final DateTime idle = _idleSince.putIfAbsent(chatId, now);
    if (now().difference(idle) < settle) return (queued: 0, waiting: true);
    _idleSince.remove(chatId);

    final List<String> texts = await FollowUpParkingService.load(chatId);
    if (texts.isEmpty) {
      await FollowUpParkingService.save(chatId, const <String>[]);
      return (queued: 0, waiting: false);
    }
    // Taken off the park first: a second pass, or the screen opening the
    // chat, must not send them a second time.
    await FollowUpParkingService.save(chatId, const <String>[]);

    final chat = await loadChat(chatId);
    final messages = chat?.messages.toList() ?? <ChatMessage>[];
    String modelId = '';
    String provider = '';
    for (final m in messages.reversed) {
      if ((m.modelId ?? '').isNotEmpty) {
        modelId = m.modelId!;
        provider = m.provider ?? '';
        break;
      }
    }
    final List<Map<String, dynamic>> maps = messages
        .map((m) => m.toJson())
        .toList();
    var queued = 0;
    final List<String> left = <String>[];
    for (final String text in texts) {
      if (text.trim().isEmpty) continue;
      try {
        final String queueId = await enqueue(
          OfflineSendPayload(
            chatId: chatId,
            messageText: text,
            modelId: modelId,
            providerSlug: provider,
            resolvePromptAtSend: true,
          ),
        );
        maps.add(<String, dynamic>{
          'role': 'user',
          'text': text,
          'status': 'pending',
          'queueId': queueId,
          if (modelId.isNotEmpty) 'modelId': modelId,
          if (provider.isNotEmpty) 'provider': provider,
          'sentAt': DateTime.now().toIso8601String(),
        });
        queued++;
      } catch (e) {
        if (kDebugMode) debugPrint('[FollowUpDispatcher] enqueue failed: $e');
        left.add(text);
      }
    }
    if (left.isNotEmpty) await FollowUpParkingService.save(chatId, left);
    if (queued > 0) {
      // The bubbles are stored before the outbox may send: the send finds
      // its question by queue id.
      await saveChat(chatId, maps);
      kickOutbox();
      OfflineRetryManager.instance.notify(
        OfflineRetryEvent(
          type: OfflineRetryEventType.updated,
          queueId: '',
          chatId: chatId,
        ),
      );
    }
    return (queued: queued, waiting: left.isNotEmpty);
  }
}
