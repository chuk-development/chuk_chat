/// The date chip between two days of a conversation.
///
/// A messenger breaks its thread by day: a small centred pill that says "Today",
/// "Yesterday", the weekday inside the last week, or the date. It answers "when
/// was this said" for a whole run of messages, which the per-bubble clock alone
/// does not.
///
/// A row without a timestamp shows no chip: an undated message is not evidence
/// of a day (see the clock rule in message_bubble/layout.dart).
library;

import 'package:flutter/material.dart';

/// True when [a] and [b] fall on the same calendar day.
bool sameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The label for a day: "Today", "Yesterday", a weekday inside the last week,
/// else `d.m.yyyy`.
String dayLabel(DateTime when, {DateTime? now}) {
  final DateTime today = now ?? DateTime.now();
  final DateTime day = DateTime(when.year, when.month, when.day);
  final DateTime start = DateTime(today.year, today.month, today.day);
  final int days = start.difference(day).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) {
    const List<String> names = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[when.weekday - 1];
  }
  return '${when.day}.${when.month}.${when.year}';
}

class ChatDayDivider extends StatelessWidget {
  const ChatDayDivider({super.key, required this.when, this.now});

  final DateTime when;

  /// Injectable clock, so a test's "Today" is deterministic.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: ShapeDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
            shape: const StadiumBorder(),
          ),
          child: Text(
            dayLabel(when, now: now),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}
