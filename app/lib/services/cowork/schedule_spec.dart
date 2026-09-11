import 'package:flutter/foundation.dart' show immutable;

/// The four schedule shapes CoWork accepts.
///
/// The model writes the schedule as a short string. This file is the only
/// place that string is interpreted, and the interpretation is deterministic:
/// no clock reads, no locale, no I/O, no plugins.
enum ScheduleKind {
  /// `every 30m` — repeats forever.
  interval,

  /// `0 9 * * *` — a 5-field cron expression.
  cron,

  /// `2026-02-03T14:00` — one run at a local wall-clock time.
  oneShotAt,

  /// `30m` — one run, that far from now.
  oneShotIn,
}

/// Thrown when a schedule string cannot be read.
///
/// The [message] names the problem in one short line. It is written for a
/// person, so it can go straight into the UI.
class ScheduleFormatException implements Exception {
  /// Creates an exception that carries [message].
  const ScheduleFormatException(this.message);

  /// A short description of what is wrong with the input.
  final String message;

  @override
  String toString() => 'ScheduleFormatException: $message';
}

/// A parsed schedule, plus the calculation of when it fires next.
///
/// Accepted input:
///
/// * `every 30m`, `every 2h`, `every 1d`, `every 45s` (one space inside the
///   duration is tolerated: `every 30 m`) — [ScheduleKind.interval].
/// * `0 9 * * *` — a 5-field cron expression, [ScheduleKind.cron].
/// * `2026-02-03T14:00` — ISO-8601 **local** date-time, [ScheduleKind.oneShotAt].
/// * `30m` — a bare duration, [ScheduleKind.oneShotIn].
///
/// Anything else raises [ScheduleFormatException].
@immutable
class ScheduleSpec {
  const ScheduleSpec._({
    required this.kind,
    required this.source,
    this.interval,
    this.at,
    _CronSchedule? cronSchedule,
  }) : _cronSchedule = cronSchedule;

  /// Which shape this schedule has.
  final ScheduleKind kind;

  /// The input text as typed, trimmed.
  final String source;

  /// Set for [ScheduleKind.interval] and [ScheduleKind.oneShotIn].
  final Duration? interval;

  /// Set for [ScheduleKind.oneShotAt]. Always a local-time [DateTime].
  final DateTime? at;

  final _CronSchedule? _cronSchedule;

  /// The normalised 5-field cron string. Set for [ScheduleKind.cron].
  ///
  /// Normalisation is whitespace only: the five fields are joined by one
  /// space each. Field text is kept as written, so `0 9 * * 7` stays `7`
  /// even though it is read as Sunday.
  String? get cron => _cronSchedule?.text;

  /// Longest scan [nextRuns] does for a cron schedule.
  static const Duration _cronScanWindow = Duration(days: 366);

  /// Reads [input] or throws [ScheduleFormatException].
  static ScheduleSpec parse(String input) {
    final String text = input.trim();
    if (text.isEmpty) {
      throw const ScheduleFormatException('the schedule is empty');
    }

    final List<String> tokens = text.split(RegExp(r'\s+'));

    if (tokens.first.toLowerCase() == 'every') {
      final String rest = tokens.skip(1).join();
      if (rest.isEmpty) {
        throw const ScheduleFormatException(
          '"every" needs a duration, for example "every 30m"',
        );
      }
      final Duration every = _parseDuration(rest);
      return ScheduleSpec._(
        kind: ScheduleKind.interval,
        source: text,
        interval: every,
      );
    }

    // A date always starts with `yyyy-mm-dd`, which no cron field can. The
    // check therefore comes before the field count, so that a date written
    // with a space instead of `T` gets a date error, not a cron error.
    if (_isoLike.hasMatch(text)) {
      final DateTime? when = DateTime.tryParse(text);
      if (when == null) {
        throw ScheduleFormatException('"$text" is not a valid date and time');
      }
      // A bare ISO string is local time. A string with a zone (`Z` or an
      // offset) is converted, never taken as local.
      return ScheduleSpec._(
        kind: ScheduleKind.oneShotAt,
        source: text,
        at: when.isUtc ? when.toLocal() : when,
      );
    }

    if (tokens.length == 5) {
      return ScheduleSpec._(
        kind: ScheduleKind.cron,
        source: text,
        cronSchedule: _CronSchedule.parse(tokens),
      );
    }

    if (tokens.length > 1) {
      throw ScheduleFormatException(
        'a cron schedule needs 5 fields; got ${tokens.length} in "$text"',
      );
    }

    if (_durationLike.hasMatch(text)) {
      return ScheduleSpec._(
        kind: ScheduleKind.oneShotIn,
        source: text,
        interval: _parseDuration(text),
      );
    }

    throw ScheduleFormatException(
      '"$text" is not a schedule; use "every 30m", "30m", '
      '"0 9 * * *" or "2026-02-03T14:00"',
    );
  }

  /// Reads [input] and returns `null` instead of throwing.
  static ScheduleSpec? tryParse(String input) {
    try {
      return parse(input);
    } on ScheduleFormatException {
      return null;
    }
  }

  /// A short, plain summary of this schedule.
  String describe() {
    switch (kind) {
      case ScheduleKind.interval:
        return 'interval: every ${_prettyDuration(interval!)}';
      case ScheduleKind.cron:
        return 'cron: $cron';
      case ScheduleKind.oneShotAt:
        return 'once at ${_prettyDateTime(at!)}';
      case ScheduleKind.oneShotIn:
        return 'once in ${_prettyDuration(interval!)}';
    }
  }

  /// The next [count] run times after [from], in order.
  ///
  /// * [ScheduleKind.interval] gives `from + interval`, `from + 2*interval`, …
  /// * [ScheduleKind.oneShotIn] gives exactly one time, `from + interval`.
  /// * [ScheduleKind.oneShotAt] gives one time if [at] is after [from], and an
  ///   empty list otherwise.
  /// * [ScheduleKind.cron] scans minute by minute from the next whole minute
  ///   after [from]. The scan stops after 366 days, so a schedule that cannot
  ///   fire returns fewer times, or none, instead of running forever.
  List<DateTime> nextRuns(DateTime from, {int count = 3}) {
    if (count <= 0) {
      return const <DateTime>[];
    }
    switch (kind) {
      case ScheduleKind.interval:
        final List<DateTime> runs = <DateTime>[];
        DateTime cursor = from;
        for (int i = 0; i < count; i++) {
          cursor = cursor.add(interval!);
          runs.add(cursor);
        }
        return runs;
      case ScheduleKind.oneShotIn:
        return <DateTime>[from.add(interval!)];
      case ScheduleKind.oneShotAt:
        final DateTime when = at!;
        return when.isAfter(from) ? <DateTime>[when] : const <DateTime>[];
      case ScheduleKind.cron:
        return _cronSchedule!.nextRuns(from, count, _cronScanWindow);
    }
  }

  static final RegExp _isoLike = RegExp(r'^\d{4}-\d{2}-\d{2}([Tt ]|$)');
  static final RegExp _durationLike = RegExp(r'^\d+[smhdSMHD]$');
  static final RegExp _duration = RegExp(r'^(\d+)([smhd])$');

  static Duration _parseDuration(String text) {
    final RegExpMatch? match = _duration.firstMatch(text.toLowerCase());
    if (match == null) {
      throw ScheduleFormatException(
        '"$text" is not a duration; use a number and s, m, h or d, '
        'for example "30m"',
      );
    }
    final int value = int.parse(match.group(1)!);
    if (value <= 0) {
      throw ScheduleFormatException(
        'the duration in "$text" must be more than zero',
      );
    }
    switch (match.group(2)!) {
      case 's':
        return Duration(seconds: value);
      case 'm':
        return Duration(minutes: value);
      case 'h':
        return Duration(hours: value);
      default:
        return Duration(days: value);
    }
  }

  static String _prettyDuration(Duration value) {
    final int seconds = value.inSeconds;
    if (seconds % Duration.secondsPerDay == 0) {
      return _plural(seconds ~/ Duration.secondsPerDay, 'day');
    }
    if (seconds % Duration.secondsPerHour == 0) {
      return _plural(seconds ~/ Duration.secondsPerHour, 'hour');
    }
    if (seconds % Duration.secondsPerMinute == 0) {
      return _plural(seconds ~/ Duration.secondsPerMinute, 'minute');
    }
    return _plural(seconds, 'second');
  }

  static String _plural(int count, String unit) =>
      count == 1 ? '$count $unit' : '$count ${unit}s';

  static String _prettyDateTime(DateTime value) {
    final String date =
        '${_pad(value.year, 4)}-${_pad(value.month, 2)}-'
        '${_pad(value.day, 2)}';
    final String time = '${_pad(value.hour, 2)}:${_pad(value.minute, 2)}';
    if (value.second == 0) {
      return '$date $time';
    }
    return '$date $time:${_pad(value.second, 2)}';
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}

/// One field of a cron expression, expanded into the values it matches.
@immutable
class _CronField {
  const _CronField(this.values, {required this.restricted});

  /// The matching values, already range-checked and normalised.
  final Set<int> values;

  /// `false` when the field is plain `*`. Only the day fields care.
  final bool restricted;

  bool matches(int value) => values.contains(value);

  /// Reads one field, for example `*`, `5`, `1,3,5`, `1-5`, `*/5` or `1-9/2`.
  static _CronField parse(
    String text,
    String name,
    int min,
    int max, {
    int Function(int value)? normalise,
  }) {
    if (text.isEmpty) {
      throw ScheduleFormatException('the $name field is empty');
    }
    final bool restricted = text != '*';
    final Set<int> values = <int>{};

    for (final String part in text.split(',')) {
      if (part.isEmpty) {
        throw ScheduleFormatException(
          'the $name field "$text" has an empty item',
        );
      }

      final List<String> slashed = part.split('/');
      if (slashed.length > 2) {
        throw ScheduleFormatException(
          'the $name field item "$part" has more than one "/"',
        );
      }

      int step = 1;
      if (slashed.length == 2) {
        step = _positiveInt(slashed[1], name, part, 'step');
      }

      final String range = slashed[0];
      int first;
      int last;
      if (range == '*') {
        first = min;
        last = max;
      } else if (range.contains('-')) {
        final List<String> ends = range.split('-');
        if (ends.length != 2) {
          throw ScheduleFormatException(
            'the $name field item "$part" is not a range',
          );
        }
        first = _boundedInt(ends[0], name, part, min, max);
        last = _boundedInt(ends[1], name, part, min, max);
        if (first > last) {
          throw ScheduleFormatException(
            'the $name field range "$range" runs backwards',
          );
        }
      } else {
        first = _boundedInt(range, name, part, min, max);
        last = first;
        if (slashed.length == 2) {
          throw ScheduleFormatException(
            'the $name field item "$part" needs "*" or a range before "/"',
          );
        }
      }

      for (int value = first; value <= last; value += step) {
        values.add(normalise == null ? value : normalise(value));
      }
    }

    return _CronField(Set<int>.unmodifiable(values), restricted: restricted);
  }

  static int _positiveInt(String text, String name, String part, String what) {
    final int? value = _plainInt(text);
    if (value == null || value < 1) {
      throw ScheduleFormatException(
        'the $name field item "$part" has a bad $what',
      );
    }
    return value;
  }

  static int _boundedInt(
    String text,
    String name,
    String part,
    int min,
    int max,
  ) {
    final int? value = _plainInt(text);
    if (value == null) {
      throw ScheduleFormatException(
        'the $name field item "$part" is not a number',
      );
    }
    if (value < min || value > max) {
      throw ScheduleFormatException(
        'the $name value $value is outside $min-$max',
      );
    }
    return value;
  }

  static final RegExp _digits = RegExp(r'^\d+$');

  static int? _plainInt(String text) =>
      _digits.hasMatch(text) ? int.parse(text) : null;
}

/// A parsed 5-field cron expression and the forward scan over it.
@immutable
class _CronSchedule {
  const _CronSchedule({
    required this.text,
    required this.minutes,
    required this.hours,
    required this.daysOfMonth,
    required this.months,
    required this.daysOfWeek,
  });

  /// The five fields joined by single spaces.
  final String text;
  final _CronField minutes;
  final _CronField hours;
  final _CronField daysOfMonth;
  final _CronField months;
  final _CronField daysOfWeek;

  static _CronSchedule parse(List<String> fields) {
    assert(fields.length == 5, 'a cron expression has 5 fields');
    return _CronSchedule(
      text: fields.join(' '),
      minutes: _CronField.parse(fields[0], 'minute', 0, 59),
      hours: _CronField.parse(fields[1], 'hour', 0, 23),
      daysOfMonth: _CronField.parse(fields[2], 'day-of-month', 1, 31),
      months: _CronField.parse(fields[3], 'month', 1, 12),
      // Cron takes both 0 and 7 for Sunday. Both are stored as 0.
      daysOfWeek: _CronField.parse(
        fields[4],
        'day-of-week',
        0,
        7,
        normalise: (int value) => value == 7 ? 0 : value,
      ),
    );
  }

  /// Standard cron day rule: when the day-of-month field and the day-of-week
  /// field are **both** restricted, a day matches if **either** matches.
  /// Otherwise both must match.
  bool _matchesDay(DateTime when) {
    final bool byMonthDay = daysOfMonth.matches(when.day);
    // Dart counts Monday as 1 and Sunday as 7. Cron counts Sunday as 0.
    final bool byWeekDay = daysOfWeek.matches(when.weekday % 7);
    if (daysOfMonth.restricted && daysOfWeek.restricted) {
      return byMonthDay || byWeekDay;
    }
    return byMonthDay && byWeekDay;
  }

  List<DateTime> nextRuns(DateTime from, int count, Duration window) {
    final List<DateTime> runs = <DateTime>[];
    final DateTime limit = from.add(window);

    // Truncate to the minute, then start one minute later: a run is always
    // strictly after `from`.
    DateTime cursor = DateTime(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute + 1,
    );

    // The scan cannot exceed the window, but a hard step cap keeps a broken
    // calendar from looping forever.
    int steps = 0;
    const int maxSteps = 366 * 24 * 60 + 1000;

    while (runs.length < count && cursor.isBefore(limit) && steps < maxSteps) {
      steps++;
      // Skip whole months, days and hours that cannot match. That is what
      // keeps a 366-day scan cheap enough for a widget test.
      if (!months.matches(cursor.month)) {
        cursor = DateTime(cursor.year, cursor.month + 1);
        continue;
      }
      if (!_matchesDay(cursor)) {
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
        continue;
      }
      if (!hours.matches(cursor.hour)) {
        cursor = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          cursor.hour + 1,
        );
        continue;
      }
      if (!minutes.matches(cursor.minute)) {
        cursor = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          cursor.hour,
          cursor.minute + 1,
        );
        continue;
      }
      runs.add(cursor);
      cursor = DateTime(
        cursor.year,
        cursor.month,
        cursor.day,
        cursor.hour,
        cursor.minute + 1,
      );
    }

    return runs;
  }
}
