// lib/platform_specific/chat/outbox_screen_turn.dart
//
// The chat screen's side of the offline outbox send (docs/OFFLINE_SEND.md):
// when a queued message belongs to the chat on screen, the screen sends it
// through its own send path. That is the path a Retry on a message takes, so
// the turn runs the full tool loop and streams in front of the user.
//
// The screen takes a row only when its bubble is the last message of the
// chat (the send path puts the answer at the end). Otherwise, or when the
// screen is busy, it answers null and the headless turn sends the row.
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/platform_specific/chat/chat_message_edit_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/services/client_request_ids.dart';
import 'package:chuk_chat/services/follow_up_dispatcher.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';
import 'package:chuk_chat/services/streaming_manager.dart';

/// What the screen path decides from the message list alone. Pure, so the
/// rules are tested without a screen.
abstract final class OutboxScreenRules {
  /// The index of the bubble of [queueId] when the screen may send it: the
  /// bubble is the last message. -1 otherwise.
  static int sendableIndex(List<Map<String, String>> messages, String queueId) {
    if (messages.isEmpty) return -1;
    final int last = messages.length - 1;
    return messages[last]['queueId'] == queueId ? last : -1;
  }

  /// The send did not reach the server: the answer row the send path added
  /// after [bubble] (an error text) goes, and [bubble] waits again under
  /// [queueId]. Returns the error text the answer row held, if any.
  static String? restoreWaiting(
    List<Map<String, String>> messages,
    Map<String, String> bubble,
    String queueId, {
    required int lengthBefore,
  }) {
    var idx = messages.indexWhere((m) => identical(m, bubble));
    if (idx < 0) {
      idx = messages.lastIndexWhere(
        (m) => m['sender'] == 'user' && m['text'] == bubble['text'],
      );
    }
    if (idx < 0) return null;
    String? error;
    if (messages.length > lengthBefore &&
        idx + 1 < messages.length &&
        messages[idx + 1]['sender'] != 'user') {
      error = messages[idx + 1]['text'];
      messages.removeAt(idx + 1);
    }
    messages[idx]
      ..['status'] = 'pending'
      ..['queueId'] = queueId
      ..remove('lastError');
    return error;
  }

  /// Whether the answer row after [bubble] shows that the turn reached the
  /// tools (and so the server).
  static bool answerShowsWork(
    List<Map<String, String>> messages,
    Map<String, String> bubble,
  ) {
    final int idx = messages.indexWhere((m) => identical(m, bubble));
    if (idx < 0 || idx + 1 >= messages.length) return false;
    final Map<String, String> answer = messages[idx + 1];
    if (answer['sender'] == 'user') return false;
    return (answer['toolCalls'] ?? '').length > 2 ||
        (answer['contentBlocks'] ?? '').length > 2;
  }
}

mixin OutboxScreenTurnMixin<W extends StatefulWidget>
    on State<W>, ChatScrollMixin<W>, ChatMessageEditMixin<W>
    implements OutboxScreen {
  /// Whether a turn of [chatId] runs on this screen now (also between two
  /// tool passes), or the screen's send path is busy with any turn.
  bool outboxTurnRunningFor(String chatId);

  /// Loads the stored copy of [chatId] into [messages] (the outbox may have
  /// written a transcript or an uploaded image path into it).
  Future<void> outboxReloadFromStorage(String chatId);

  static const Duration _poll = Duration(milliseconds: 200);
  static const Duration _maxTurn = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    OfflineSendExecutor.registerScreen(this);
  }

  @override
  void dispose() {
    OfflineSendExecutor.unregisterScreen(this);
    // Follow-ups parked in the chat this screen held go out from the outbox.
    FollowUpDispatcher.instance.kick();
    super.dispose();
  }

  @override
  String? get outboxChatId => mounted ? activeChatId : null;

  @override
  Future<SendExecutorResult?> sendOutboxRow(
    QueuedMessage queued,
    OfflineSendPayload payload,
  ) async {
    final String chatId = payload.chatId;
    if (!mounted || activeChatId != chatId) return null;
    if (outboxTurnRunningFor(chatId)) return null;
    await outboxReloadFromStorage(chatId);
    if (!mounted || activeChatId != chatId || outboxTurnRunningFor(chatId)) {
      return null;
    }
    final int idx = OutboxScreenRules.sendableIndex(messages, queued.id);
    if (idx < 0) return null;
    final Map<String, String> bubble = messages[idx];
    final String shown = bubble['text'] ?? '';
    final String text = shown.trim().isNotEmpty ? shown : payload.messageText;
    if (text.trim().isEmpty) return null;
    final int lengthBefore = messages.length;

    setState(() {
      bubble
        ..remove('status')
        ..remove('queueId')
        ..remove('lastError');
    });

    var accepted = false;
    void noteAccepted() {
      try {
        if (StreamingManager().serverAccepted(chatId)) accepted = true;
      } catch (_) {}
    }

    final Timer poll = Timer.periodic(_poll, (_) => noteAccepted());
    // The row's own `client_request_id`s: a re-send of the row (also after
    // an app restart) is answered by the server once.
    ClientRequestIds.arm(
      chatId,
      OfflineSendCoordinator.requestBaseFor(queued, payload),
    );
    try {
      // The Retry path of a message: the bubble is the last one, so nothing
      // below it is cleared, and its attachments are rebuilt from the bubble.
      await submitEditedMessage(
        idx,
        text,
        removeFollowingAssistant: false,
        clearMessagesBelow: true,
      );
      final DateTime until = DateTime.now().add(_maxTurn);
      while (mounted &&
          outboxTurnRunningFor(chatId) &&
          DateTime.now().isBefore(until)) {
        noteAccepted();
        await Future<void>.delayed(_poll);
      }
      noteAccepted();
    } finally {
      poll.cancel();
      // A send that never started leaves the base armed; it must not reach
      // the chat's next, unrelated turn.
      ClientRequestIds.disarm(chatId);
    }

    if (accepted || OutboxScreenRules.answerShowsWork(messages, bubble)) {
      // Delivered. Whatever the turn wrote (an answer, or an error after
      // the server took it) is the chat's answer, like any send on screen.
      // Stored before the success event, which reloads the chat from disk.
      if (mounted) await persistChat(waitForCompletion: true, commit: false);
      return const SendExecutorResult.success();
    }

    // Never reached the server: the bubble waits again.
    final bool started = messages.length > lengthBefore;
    String? error;
    if (mounted) {
      setState(() {
        error = OutboxScreenRules.restoreWaiting(
          messages,
          bubble,
          queued.id,
          lengthBefore: lengthBefore,
        );
      });
      unawaited(persistChat(commit: false));
    } else {
      error = OutboxScreenRules.restoreWaiting(
        messages,
        bubble,
        queued.id,
        lengthBefore: lengthBefore,
      );
    }
    if (!started) return null; // The screen did not send: headless instead.
    final String reason = (error == null || error!.trim().isEmpty)
        ? 'not sent'
        : error!;
    return SendExecutorResult.failure(
      NetworkStatusService.isNetworkError(reason) ||
              !NetworkStatusService.isOnline
          ? 'network: $reason'
          : reason,
    );
  }
}
