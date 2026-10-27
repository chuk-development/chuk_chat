// lib/services/automations/simple_schedule.dart
//
// The three schedules most routines need, as a person picks them: every day
// at a time, on chosen weekdays at a time, every N hours (bead
// chuk_chat-4p90). Each maps to the host's own spec grammar
// (docs/WIRE_CONTRACT.md, "Automations"): a 5-field cron in the host's local
// time, or `every <n>h`. Anything else stays text ("custom").
//
// Weekdays use cron numbers: 0 = Sunday, 1 = Monday ... 6 = Saturday.

/// Which picker shape a schedule has.
enum SimpleScheduleMode { daily, weekdays, everyHours, custom }

/// The weekdays a new "weekdays" schedule starts with: Monday to Friday.
const Set<int> kWorkWeek = <int>{1, 2, 3, 4, 5};

/// The interval bounds of "every N hours". A day or longer is a daily
/// schedule.
const int kMinEveryHours = 1;
const int kMaxEveryHours = 23;

class SimpleSchedule {
  const SimpleSchedule({
    required this.mode,
    this.hour = 9,
    this.minute = 0,
    this.weekdays = kWorkWeek,
    this.everyHours = 2,
    this.custom = '',
  });

  final SimpleScheduleMode mode;
  final int hour;
  final int minute;

  /// Cron weekdays, 0 = Sunday.
  final Set<int> weekdays;
  final int everyHours;

  /// The text of a custom schedule, as the user or the agent wrote it.
  final String custom;

  /// The default for a new routine: every day at 09:00.
  static const SimpleSchedule initial = SimpleSchedule(
    mode: SimpleScheduleMode.daily,
  );

  SimpleSchedule copyWith({
    SimpleScheduleMode? mode,
    int? hour,
    int? minute,
    Set<int>? weekdays,
    int? everyHours,
    String? custom,
  }) => SimpleSchedule(
    mode: mode ?? this.mode,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    weekdays: weekdays ?? this.weekdays,
    everyHours: everyHours ?? this.everyHours,
    custom: custom ?? this.custom,
  );

  /// The spec the host reads. Empty for a weekdays schedule with no day
  /// picked, which the editor then refuses like an empty field.
  String toSpec() {
    switch (mode) {
      case SimpleScheduleMode.daily:
        return '$minute $hour * * *';
      case SimpleScheduleMode.weekdays:
        if (weekdays.isEmpty) return '';
        if (weekdays.length == 7) return '$minute $hour * * *';
        return '$minute $hour * * ${cronWeekdays(weekdays)}';
      case SimpleScheduleMode.everyHours:
        return 'every ${everyHours.clamp(kMinEveryHours, kMaxEveryHours)}h';
      case SimpleScheduleMode.custom:
        return custom.trim();
    }
  }

  /// Reads a spec back into the picker. A spec the picker cannot show
  /// (a step, a day of the month, `every 30m`, a one-shot) is [custom], so an
  /// edit never changes what it does not understand.
  static SimpleSchedule fromSpec(String spec) {
    final String text = spec.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return initial;
    final RegExpMatch? every = _everyHours.firstMatch(text);
    if (every != null) {
      final int hours = int.parse(every.group(1)!);
      if (hours >= kMinEveryHours && hours <= kMaxEveryHours) {
        return SimpleSchedule(
          mode: SimpleScheduleMode.everyHours,
          everyHours: hours,
        );
      }
    }
    final List<String> fields = text.split(' ');
    if (fields.length == 5 && fields[2] == '*' && fields[3] == '*') {
      final int? minute = _plainInt(fields[0]);
      final int? hour = _plainInt(fields[1]);
      if (minute != null &&
          hour != null &&
          minute >= 0 &&
          minute <= 59 &&
          hour >= 0 &&
          hour <= 23) {
        if (fields[4] == '*') {
          return SimpleSchedule(
            mode: SimpleScheduleMode.daily,
            hour: hour,
            minute: minute,
          );
        }
        final Set<int>? days = _parseWeekdays(fields[4]);
        if (days != null && days.isNotEmpty) {
          return SimpleSchedule(
            mode: days.length == 7
                ? SimpleScheduleMode.daily
                : SimpleScheduleMode.weekdays,
            hour: hour,
            minute: minute,
            weekdays: days,
          );
        }
      }
    }
    return SimpleSchedule(mode: SimpleScheduleMode.custom, custom: spec.trim());
  }

  static final RegExp _everyHours = RegExp(
    r'^every (\d{1,2}) ?h$',
    caseSensitive: false,
  );

  static int? _plainInt(String text) =>
      RegExp(r'^\d{1,2}$').hasMatch(text) ? int.parse(text) : null;

  /// `1-5`, `1,3,5`, `0,6`, `7` (Sunday). Names and steps are not the
  /// picker's business: null.
  static Set<int>? _parseWeekdays(String field) {
    final Set<int> days = <int>{};
    for (final String part in field.split(',')) {
      final RegExpMatch? range = RegExp(r'^(\d)-(\d)$').firstMatch(part);
      if (range != null) {
        final int a = int.parse(range.group(1)!);
        final int b = int.parse(range.group(2)!);
        if (a > b || b > 7) return null;
        for (int d = a; d <= b; d++) {
          days.add(d % 7);
        }
        continue;
      }
      if (!RegExp(r'^\d$').hasMatch(part)) return null;
      final int d = int.parse(part);
      if (d > 7) return null;
      days.add(d % 7);
    }
    return days;
  }
}

/// The cron day-of-week field for [days]: a range where the days are one
/// run (`1-5`), else a list (`1,3,5`). Sunday is 0.
String cronWeekdays(Set<int> days) {
  final List<int> sorted = days.toList()..sort();
  final bool run =
      sorted.length > 1 && sorted.last - sorted.first == sorted.length - 1;
  if (run) return '${sorted.first}-${sorted.last}';
  return sorted.join(',');
}
