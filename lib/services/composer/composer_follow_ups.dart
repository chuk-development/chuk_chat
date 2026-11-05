// lib/services/composer/composer_follow_ups.dart
//
// The follow-up logic both chat screens share: what a busy send does, what
// happens to steers when a turn ends, parking on disk, and restore. The
// screens only call in at their own points (busy send, turn end, chat
// switch, stop) and send the text [takeNext] gives them.
//
// The queue is held per chat: a chat switch parks the old chat's messages
// (FollowUpParkingService) and the next chat restores its own, so a queued
// message never goes out into another chat (bead cowork-sc22).
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/composer/follow_up_queue.dart';
import 'package:chuk_chat/services/follow_up_parking_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

class ComposerFollowUps {
  ComposerFollowUps({
    required this.chatId,
    Future<void> Function(String chatId, List<String> texts)? park,
    Future<List<String>> Function(String chatId)? loadParked,
    bool Function(String? chatId)? isAgentsThread,
  }) : _park = park ?? FollowUpParkingService.save,
       _loadParked = loadParked ?? FollowUpParkingService.load,
       _isAgentsThread = isAgentsThread ?? ChatOrigin.isAgentsThread {
    SteerInbox.revision.addListener(_pruneDelivered);
  }

  /// The chat the screen shows now.
  final String? Function() chatId;
  final Future<void> Function(String chatId, List<String> texts) _park;
  final Future<List<String>> Function(String chatId) _loadParked;
  final bool Function(String? chatId) _isAgentsThread;

  final FollowUpQueue queue = FollowUpQueue();

  /// Steer goes into the running turn of a plain chat. An Agents thread has
  /// no steer on the wire, so there every busy send queues.
  bool get steerAvailable {
    final String? id = chatId();
    return id != null && !_isAgentsThread(id);
  }

  bool get isEmpty => queue.isEmpty;
  bool get hasQueued => queue.hasQueued;

  void dispose() {
    SteerInbox.revision.removeListener(_pruneDelivered);
    queue.dispose();
  }

  /// A send while the reply runs. [alternate] is Ctrl/Cmd+Enter.
  FollowUpKind enqueue(String text, {bool alternate = false}) {
    final FollowUpKind kind = busySendKind(
      ComposerBusySetting.mode.value,
      alternate: alternate,
      steerAvailable: steerAvailable,
    );
    final QueuedFollowUp item = queue.add(text, kind: kind);
    final String? id = chatId();
    if (kind == FollowUpKind.steer && id != null) {
      SteerInbox.post(id, SteerEntry(id: item.id, text: text));
    }
    park();
    return kind;
  }

  void edit(String id, String text) {
    queue.update(id, text: text);
    final String? chat = chatId();
    if (chat != null) SteerInbox.update(chat, id, text);
    park();
  }

  void remove(String id) {
    queue.remove(id);
    final String? chat = chatId();
    if (chat != null) SteerInbox.remove(chat, id);
    park();
  }

  /// A queued message goes into the running turn now.
  void steerNow(String id) {
    final QueuedFollowUp? item = queue.byId(id);
    final String? chat = chatId();
    if (item == null || chat == null || !steerAvailable) return;
    if (item.kind == FollowUpKind.steer) return;
    queue.update(id, kind: FollowUpKind.steer);
    SteerInbox.post(chat, SteerEntry(id: id, text: item.text));
  }

  /// The turn of the open chat ended. A steer the loop did not take (no
  /// further pass) becomes a queued message, in its place, so it is sent
  /// after the reply. Delivered steers leave the dock.
  void onTurnEnded() {
    final String? chat = chatId();
    final List<String> delivered = <String>[];
    // Taking a steer back out of the inbox bumps its revision; that must not
    // read as "delivered" while this loop runs.
    _muted = true;
    try {
      for (final QueuedFollowUp item in queue.items) {
        if (item.kind != FollowUpKind.steer) continue;
        if (chat != null && SteerInbox.remove(chat, item.id)) {
          queue.update(item.id, kind: FollowUpKind.queued);
        } else {
          delivered.add(item.id);
        }
      }
    } finally {
      _muted = false;
    }
    queue.removeAll(delivered);
    park();
  }

  /// The oldest message for a new turn, taken out of the queue.
  QueuedFollowUp? takeNext() {
    final QueuedFollowUp? next = queue.takeNextQueued();
    if (next != null) park();
    return next;
  }

  /// Everything waiting, as one text for the composer (the user stopped the
  /// reply, or cancelled the queue). Pending steers are withdrawn from the
  /// turn. Null when nothing waits.
  String? drainToText() {
    final String? chat = chatId();
    final List<QueuedFollowUp> all = queue.drain();
    if (all.isEmpty) return null;
    if (chat != null) {
      for (final QueuedFollowUp i in all) {
        SteerInbox.remove(chat, i.id);
      }
    }
    park();
    return all.map((i) => i.text).join('\n\n');
  }

  /// The screen leaves [oldChatId]. Its messages stay parked on disk (the
  /// open chat sends them when it is opened again, FollowUpDispatcher when no
  /// screen holds it); the steers are withdrawn and parked as queued.
  void leaveChat(String? oldChatId) {
    if (oldChatId == null) {
      queue.drain();
      return;
    }
    final List<QueuedFollowUp> all = queue.drain();
    for (final QueuedFollowUp i in all) {
      SteerInbox.remove(oldChatId, i.id);
    }
    if (all.isNotEmpty) {
      unawaited(_park(oldChatId, <String>[for (final i in all) i.text]));
    }
  }

  /// Restores the parked messages of [forChatId], if the queue is empty.
  /// True when something was restored.
  Future<bool> restoreParked(String forChatId) async {
    final List<String> parked = await _loadParked(forChatId);
    if (parked.isEmpty || chatId() != forChatId || queue.isNotEmpty) {
      return false;
    }
    queue.replaceWith(parked);
    return true;
  }

  void park() {
    final String? chat = chatId();
    if (chat == null) return;
    unawaited(_park(chat, queue.texts));
  }

  bool _muted = false;

  void _pruneDelivered() {
    if (_muted) return;
    final String? chat = chatId();
    if (chat == null) return;
    final List<String> gone = <String>[
      for (final QueuedFollowUp i in queue.items)
        if (i.kind == FollowUpKind.steer && !SteerInbox.isPending(chat, i.id))
          i.id,
    ];
    if (gone.isEmpty) return;
    queue.removeAll(gone);
    park();
  }

  @visibleForTesting
  void debugPrune() => _pruneDelivered();
}
