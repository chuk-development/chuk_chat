// Port of lib/features/calendar/domain/models/rrule_helper.dart (pure Dart,
// kept behaviour-identical so the MCP lists the same occurrences the app
// draws). RFC 5545 RRULE subset for calendar recurring events.
// Supported: FREQ, INTERVAL, BYDAY, BYMONTHDAY, COUNT, UNTIL, WKST

enum RecurrenceFrequency { daily, weekly, monthly, yearly }

enum Weekday { mo, tu, we, th, fr, sa, su }

class RecurrenceConfig {
  final RecurrenceFrequency frequency;
  final int interval;
  final List<Weekday>? byDay;
  final List<int>? byMonthDay;
  final int? count;
  final DateTime? until;
  final Weekday weekStart;

  const RecurrenceConfig({
    required this.frequency,
    this.interval = 1,
    this.byDay,
    this.byMonthDay,
    this.count,
    this.until,
    this.weekStart = Weekday.mo,
  });
}

class RRuleHelper {
  const RRuleHelper._();

  static const _freqMap = {
    'DAILY': RecurrenceFrequency.daily,
    'WEEKLY': RecurrenceFrequency.weekly,
    'MONTHLY': RecurrenceFrequency.monthly,
    'YEARLY': RecurrenceFrequency.yearly,
  };

  static const _dayMap = {
    'MO': Weekday.mo,
    'TU': Weekday.tu,
    'WE': Weekday.we,
    'TH': Weekday.th,
    'FR': Weekday.fr,
    'SA': Weekday.sa,
    'SU': Weekday.su,
  };

  static const _dayToString = {
    Weekday.mo: 'MO',
    Weekday.tu: 'TU',
    Weekday.we: 'WE',
    Weekday.th: 'TH',
    Weekday.fr: 'FR',
    Weekday.sa: 'SA',
    Weekday.su: 'SU',
  };

  static const _freqToString = {
    RecurrenceFrequency.daily: 'DAILY',
    RecurrenceFrequency.weekly: 'WEEKLY',
    RecurrenceFrequency.monthly: 'MONTHLY',
    RecurrenceFrequency.yearly: 'YEARLY',
  };

  /// Parse an RRULE string into a RecurrenceConfig
  static RecurrenceConfig? parseRRule(String? rule) {
    if (rule == null || rule.isEmpty) return null;

    final clean = rule.startsWith('RRULE:') ? rule.substring(6) : rule;
    final parts = clean.split(';');
    final params = <String, String>{};
    for (final part in parts) {
      final kv = part.split('=');
      if (kv.length == 2) {
        params[kv[0].toUpperCase()] = kv[1];
      }
    }

    final freqStr = params['FREQ'];
    if (freqStr == null || !_freqMap.containsKey(freqStr)) return null;

    return RecurrenceConfig(
      frequency: _freqMap[freqStr]!,
      interval: int.tryParse(params['INTERVAL'] ?? '1') ?? 1,
      byDay: params['BYDAY']
          ?.split(',')
          .map((d) => _dayMap[d.toUpperCase()])
          .whereType<Weekday>()
          .toList(),
      byMonthDay: params['BYMONTHDAY']
          ?.split(',')
          .map((d) => int.tryParse(d))
          .whereType<int>()
          .toList(),
      count: params['COUNT'] != null ? int.tryParse(params['COUNT']!) : null,
      until: params['UNTIL'] != null ? _parseUntil(params['UNTIL']!) : null,
      weekStart: _dayMap[params['WKST']?.toUpperCase()] ?? Weekday.mo,
    );
  }

  /// Build an RRULE string from a RecurrenceConfig
  static String buildRRule(RecurrenceConfig config) {
    final parts = <String>[];
    parts.add('FREQ=${_freqToString[config.frequency]}');

    if (config.interval > 1) {
      parts.add('INTERVAL=${config.interval}');
    }

    if (config.byDay != null && config.byDay!.isNotEmpty) {
      parts.add('BYDAY=${config.byDay!.map((d) => _dayToString[d]).join(',')}');
    }

    if (config.byMonthDay != null && config.byMonthDay!.isNotEmpty) {
      parts.add('BYMONTHDAY=${config.byMonthDay!.join(',')}');
    }

    if (config.count != null) {
      parts.add('COUNT=${config.count}');
    }

    if (config.until != null) {
      parts.add('UNTIL=${_formatUntil(config.until!)}');
    }

    if (config.weekStart != Weekday.mo) {
      parts.add('WKST=${_dayToString[config.weekStart]}');
    }

    return parts.join(';');
  }

  /// Expand recurring event occurrences within a date range.
  /// Returns start times of each occurrence.
  static List<DateTime> expandOccurrences(
    DateTime eventStart,
    String rrule,
    DateTime rangeStart,
    DateTime rangeEnd, {
    Set<String>? excludedDates,
  }) {
    final config = parseRRule(rrule);
    if (config == null) return [eventStart];

    final occurrences = <DateTime>[];
    var current = eventStart;
    var count = 0;
    final maxIterations = 1000;
    var iterations = 0;

    while (iterations < maxIterations) {
      iterations++;

      if (config.until != null && current.isAfter(config.until!)) break;
      if (config.count != null && count >= config.count!) break;
      if (current.isAfter(rangeEnd)) break;

      if (config.frequency == RecurrenceFrequency.weekly &&
          config.byDay != null &&
          config.byDay!.isNotEmpty) {
        // For weekly with BYDAY, check each day of the week
        final weekStart = current;
        for (final day in config.byDay!) {
          final dayOffset = _weekdayToInt(day) - weekStart.weekday;
          final adjusted = dayOffset >= 0 ? dayOffset : dayOffset + 7;
          final occurrence = weekStart.add(Duration(days: adjusted));

          if (occurrence.isAfter(rangeEnd)) continue;
          if (config.until != null && occurrence.isAfter(config.until!)) {
            continue;
          }
          if (config.count != null && count >= config.count!) break;

          final dateKey =
              '${occurrence.year}-${occurrence.month.toString().padLeft(2, '0')}-${occurrence.day.toString().padLeft(2, '0')}';
          if (excludedDates != null && excludedDates.contains(dateKey)) {
            count++;
            continue;
          }

          if (!occurrence.isBefore(rangeStart)) {
            occurrences.add(
              DateTime(
                occurrence.year,
                occurrence.month,
                occurrence.day,
                eventStart.hour,
                eventStart.minute,
                eventStart.second,
              ),
            );
          }
          count++;
        }
        current = _addInterval(weekStart, config.frequency, config.interval);
      } else {
        final dateKey =
            '${current.year}-${current.month.toString().padLeft(2, '0')}-${current.day.toString().padLeft(2, '0')}';
        final excluded =
            excludedDates != null && excludedDates.contains(dateKey);

        if (!current.isBefore(rangeStart) && !excluded) {
          occurrences.add(current);
        }
        count++;

        if (config.frequency == RecurrenceFrequency.monthly &&
            config.byMonthDay != null) {
          // Advance to next month, then check byMonthDay
          final nextMonth = DateTime(
            current.year,
            current.month + config.interval,
            1,
            eventStart.hour,
            eventStart.minute,
          );
          current = nextMonth;
          // Find first matching day in that month
          for (final day in config.byMonthDay!) {
            final daysInMonth = DateTime(
              nextMonth.year,
              nextMonth.month + 1,
              0,
            ).day;
            if (day <= daysInMonth) {
              current = DateTime(
                nextMonth.year,
                nextMonth.month,
                day,
                eventStart.hour,
                eventStart.minute,
              );
              break;
            }
          }
        } else {
          current = _addInterval(current, config.frequency, config.interval);
        }
      }
    }

    occurrences.sort();
    return occurrences;
  }

  /// Get the next occurrence after a given date
  static DateTime? getNextOccurrence(
    DateTime eventStart,
    String rrule,
    DateTime after,
  ) {
    final occurrences = expandOccurrences(
      eventStart,
      rrule,
      after,
      after.add(const Duration(days: 366)),
    );
    return occurrences.isNotEmpty ? occurrences.first : null;
  }

  static DateTime _addInterval(
    DateTime date,
    RecurrenceFrequency freq,
    int interval,
  ) {
    switch (freq) {
      case RecurrenceFrequency.daily:
        return date.add(Duration(days: interval));
      case RecurrenceFrequency.weekly:
        return date.add(Duration(days: 7 * interval));
      case RecurrenceFrequency.monthly:
        return DateTime(
          date.year,
          date.month + interval,
          date.day,
          date.hour,
          date.minute,
          date.second,
        );
      case RecurrenceFrequency.yearly:
        return DateTime(
          date.year + interval,
          date.month,
          date.day,
          date.hour,
          date.minute,
          date.second,
        );
    }
  }

  static int _weekdayToInt(Weekday day) {
    switch (day) {
      case Weekday.mo:
        return DateTime.monday;
      case Weekday.tu:
        return DateTime.tuesday;
      case Weekday.we:
        return DateTime.wednesday;
      case Weekday.th:
        return DateTime.thursday;
      case Weekday.fr:
        return DateTime.friday;
      case Weekday.sa:
        return DateTime.saturday;
      case Weekday.su:
        return DateTime.sunday;
    }
  }

  static DateTime? _parseUntil(String value) {
    // UNTIL can be YYYYMMDD or YYYYMMDDTHHMMSSZ
    try {
      if (value.length == 8) {
        return DateTime(
          int.parse(value.substring(0, 4)),
          int.parse(value.substring(4, 6)),
          int.parse(value.substring(6, 8)),
        );
      }
      final clean = value.replaceAll('T', '').replaceAll('Z', '');
      return DateTime(
        int.parse(clean.substring(0, 4)),
        int.parse(clean.substring(4, 6)),
        int.parse(clean.substring(6, 8)),
        clean.length >= 10 ? int.parse(clean.substring(8, 10)) : 0,
        clean.length >= 12 ? int.parse(clean.substring(10, 12)) : 0,
        clean.length >= 14 ? int.parse(clean.substring(12, 14)) : 0,
      );
    } catch (_) {
      return null;
    }
  }

  static String _formatUntil(DateTime date) {
    return '${date.year}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}'
        'T'
        '${date.hour.toString().padLeft(2, '0')}'
        '${date.minute.toString().padLeft(2, '0')}'
        '${date.second.toString().padLeft(2, '0')}'
        'Z';
  }
}
