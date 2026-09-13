/// The stamp in the corner of a bubble: the time, and — only when it matters —
/// one mark about the local send queue.
///
/// ## Why there are no delivery ticks
///
/// A messenger shows ticks because the other side is a person who may or may
/// not have seen the message. The other side here is a coworker that reads
/// every task it is given, so "delivered" and "read" answer a question nobody
/// asks (the user said as much: the ticks are irrelevant for an agent). What
/// IS worth knowing is the one case where the message has not gone anywhere
/// yet: it sits in the offline queue, or the send gave up. That is what the
/// mark says, and nothing else.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;

/// What the stamp adds next to the time.
enum QueueMark {
  /// Nothing to say: the message is on its way or already there.
  none,

  /// In the offline queue, waiting for a connection.
  waiting,

  /// The send gave up.
  failed,
}

/// Maps the local delivery status onto the mark. `null` and `sent` are the
/// ordinary case and carry no mark.
QueueMark queueMarkFor(ChatMessageStatus? status) {
  switch (status) {
    case ChatMessageStatus.pending:
      return QueueMark.waiting;
    case ChatMessageStatus.failed:
      return QueueMark.failed;
    case ChatMessageStatus.sent:
    case ChatMessageStatus.interrupted:
    case null:
      return QueueMark.none;
  }
}

/// The time, plus the queue mark when there is one.
class MessageStamp extends StatelessWidget {
  const MessageStamp({
    super.key,
    required this.time,
    required this.fg,
    this.mark = QueueMark.none,
    this.edited = false,
    this.errorColor,
  });

  /// The already formatted clock ("14:03"). Empty renders the mark alone.
  final String time;

  /// Time and glyph colour — the on-bubble foreground.
  final Color fg;

  final QueueMark mark;
  final bool edited;
  final Color? errorColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (edited) ...<Widget>[
          Text(
            'edited',
            style: TextStyle(
              color: fg.withValues(alpha: 0.7),
              fontSize: 11,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 5),
        ],
        if (time.isNotEmpty)
          Text(
            time,
            style: TextStyle(
              color: fg.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (mark != QueueMark.none) ...<Widget>[
          if (time.isNotEmpty) const SizedBox(width: 5),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: AppIcon(
              key: ValueKey<QueueMark>(mark),
              mark == QueueMark.waiting
                  ? Icons.schedule_rounded
                  : Icons.error_outline_rounded,
              size: 14,
              color: mark == QueueMark.failed
                  ? (errorColor ?? fg)
                  : fg.withValues(alpha: 0.85),
            ),
          ),
        ],
      ],
    );
  }
}
