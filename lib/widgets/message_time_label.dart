// lib/widgets/message_time_label.dart
//
// The centred time line of an Agents thread: "Today 8:39 PM",
// "Yesterday 9:03 AM", "Wed, Nov 4 8:39 PM", "Nov 4, 2025 8:39 PM". It stands
// above the first message of a day and above the first message after a long
// pause, like a messenger (docs/DESIGN.md §9, "Time lines").

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';

/// Test hook: the clock the label compares against. Null = the real clock.
@visibleForTesting
DateTime Function()? debugMessageTimeNow;

DateTime _now() => (debugMessageTimeNow ?? DateTime.now)();

/// The label for [when], relative to [now]: the day, then the clock time.
///
/// Today and yesterday say so. Other days in the same year give the weekday
/// and the date; another year gives the date with the year. The time follows
/// the device (12 or 24 hours).
String messageTimeLabel(BuildContext context, DateTime when, {DateTime? now}) {
  final DateTime local = when.toLocal();
  final DateTime current = (now ?? _now()).toLocal();
  final MaterialLocalizations material = MaterialLocalizations.of(context);
  final AppLocalizations? loc = AppLocalizations.of(context);
  final String time = material.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat:
        MediaQuery.maybeAlwaysUse24HourFormatOf(context) ?? false,
  );
  // Calendar days, not 24-hour blocks: 23:50 yesterday is "Yesterday". UTC
  // dates, so a daylight-saving switch cannot make a day 23 hours long.
  final DateTime day = DateTime.utc(local.year, local.month, local.day);
  final DateTime today = DateTime.utc(current.year, current.month, current.day);
  final int days = today.difference(day).inDays;
  if (days <= 0) return '${loc?.today ?? 'Today'} $time';
  if (days == 1) return '${loc?.yesterday ?? 'Yesterday'} $time';
  if (local.year == current.year) {
    return '${material.formatMediumDate(local)} $time';
  }
  return '${material.formatShortDate(local)} $time';
}

/// The quiet centred line with the day and the time.
class MessageTimeDivider extends StatelessWidget {
  const MessageTimeDivider({super.key, required this.when});

  final DateTime when;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: const ValueKey<String>('message-time-divider'),
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Text(
        messageTimeLabel(context, when),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11))
            .copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
            ),
      ),
    );
  }
}
