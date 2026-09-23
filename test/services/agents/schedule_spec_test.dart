import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/schedule_spec.dart';

/// 2026-02-03 is a Tuesday. Every date in this file is built from local
/// `DateTime` values, so the tests hold in any time zone.
void main() {
  group('interval parsing', () {
    test('reads every unit', () {
      expect(ScheduleSpec.parse('every 45s').interval,
          const Duration(seconds: 45));
      expect(ScheduleSpec.parse('every 30m').interval,
          const Duration(minutes: 30));
      expect(ScheduleSpec.parse('every 2h').interval, const Duration(hours: 2));
      expect(ScheduleSpec.parse('every 1d').interval, const Duration(days: 1));
    });

    test('kind is interval and source is the trimmed text', () {
      final ScheduleSpec spec = ScheduleSpec.parse('  every 30m  ');
      expect(spec.kind, ScheduleKind.interval);
      expect(spec.source, 'every 30m');
      expect(spec.at, isNull);
      expect(spec.cron, isNull);
    });

    test('tolerates one space inside the duration', () {
      expect(ScheduleSpec.parse('every 30 m').interval,
          const Duration(minutes: 30));
      expect(
          ScheduleSpec.parse('every 2 h').interval, const Duration(hours: 2));
    });

    test('tolerates upper case', () {
      final ScheduleSpec spec = ScheduleSpec.parse('EVERY 15M');
      expect(spec.kind, ScheduleKind.interval);
      expect(spec.interval, const Duration(minutes: 15));
    });
  });

  group('one-shot parsing', () {
    test('bare duration is one shot in', () {
      final ScheduleSpec spec = ScheduleSpec.parse('90s');
      expect(spec.kind, ScheduleKind.oneShotIn);
      expect(spec.interval, const Duration(seconds: 90));
      expect(spec.at, isNull);
    });

    test('all bare duration units', () {
      expect(ScheduleSpec.parse('30m').interval, const Duration(minutes: 30));
      expect(ScheduleSpec.parse('2h').interval, const Duration(hours: 2));
      expect(ScheduleSpec.parse('1d').interval, const Duration(days: 1));
    });

    test('ISO date-time without seconds is local time', () {
      final ScheduleSpec spec = ScheduleSpec.parse('2026-02-03T14:00');
      expect(spec.kind, ScheduleKind.oneShotAt);
      expect(spec.at, DateTime(2026, 2, 3, 14));
      expect(spec.at!.isUtc, isFalse);
      expect(spec.interval, isNull);
    });

    test('ISO date-time with seconds is local time', () {
      final ScheduleSpec spec = ScheduleSpec.parse('2026-02-03T14:00:30');
      expect(spec.kind, ScheduleKind.oneShotAt);
      expect(spec.at, DateTime(2026, 2, 3, 14, 0, 30));
      expect(spec.at!.isUtc, isFalse);
    });

    test('a zone in the string is honoured, then converted to local', () {
      final ScheduleSpec spec = ScheduleSpec.parse('2026-02-03T14:00:00Z');
      expect(spec.kind, ScheduleKind.oneShotAt);
      expect(spec.at!.isUtc, isFalse);
      expect(spec.at!.toUtc(), DateTime.utc(2026, 2, 3, 14));
    });
  });

  group('cron parsing', () {
    test('kind, source and normalised cron text', () {
      final ScheduleSpec spec = ScheduleSpec.parse('  0   9 * * *  ');
      expect(spec.kind, ScheduleKind.cron);
      expect(spec.source, '0   9 * * *');
      expect(spec.cron, '0 9 * * *');
      expect(spec.interval, isNull);
      expect(spec.at, isNull);
    });

    test('accepts stars, numbers, lists, ranges and steps', () {
      for (final String text in <String>[
        '* * * * *',
        '0 9 * * *',
        '1,3,5 * * * *',
        '0 9 1-5 * *',
        '*/5 * * * *',
        '1-9/2 * * * *',
        '0 0,12 1,15 1-6/2 1-5',
        '0 9 * * 0',
        '0 9 * * 7',
        '59 23 31 12 6',
      ]) {
        expect(ScheduleSpec.parse(text).kind, ScheduleKind.cron,
            reason: 'should accept "$text"');
      }
    });

    test('both 0 and 7 mean Sunday', () {
      final DateTime from = DateTime(2026, 2, 3);
      final List<DateTime> zero =
          ScheduleSpec.parse('0 9 * * 0').nextRuns(from, count: 2);
      final List<DateTime> seven =
          ScheduleSpec.parse('0 9 * * 7').nextRuns(from, count: 2);
      expect(zero, seven);
      expect(zero.first.weekday, DateTime.sunday);
      expect(zero.first, DateTime(2026, 2, 8, 9));
    });
  });

  group('rejected input', () {
    const List<String> bad = <String>[
      '',
      '   ',
      'banana',
      'every',
      'every ',
      'every 0m',
      'every -5m',
      'every 30x',
      'every 1h30m',
      '0m',
      '0s',
      '-5m',
      '30',
      'm',
      '0 9 * *',
      '0 9 * * * *',
      '0 9 *',
      '0 99 * * *',
      '99 * * * *',
      '* 24 * * *',
      '0 9 32 * *',
      '0 9 0 * *',
      '0 9 * 13 *',
      '0 9 * 0 *',
      '0 9 * * 8',
      '0 9 * * 1-',
      '5-1 * * * *',
      '*/0 * * * *',
      '1,,3 * * * *',
      '5/2 * * * *',
      '*/2/2 * * * *',
      'a * * * *',
      '1-2-3 * * * *',
    ];

    test('parse throws ScheduleFormatException', () {
      for (final String text in bad) {
        expect(
          () => ScheduleSpec.parse(text),
          throwsA(isA<ScheduleFormatException>()),
          reason: 'should reject "$text"',
        );
      }
    });

    test('tryParse returns null', () {
      for (final String text in bad) {
        expect(ScheduleSpec.tryParse(text), isNull,
            reason: 'should reject "$text"');
      }
    });

    test('the message names the problem', () {
      expect(
        () => ScheduleSpec.parse(''),
        throwsA(predicate((Object? e) =>
            e is ScheduleFormatException && e.message.contains('empty'))),
      );
      expect(
        () => ScheduleSpec.parse('0 9 * *'),
        throwsA(predicate((Object? e) =>
            e is ScheduleFormatException && e.message.contains('5 fields'))),
      );
      expect(
        () => ScheduleSpec.parse('0 99 * * *'),
        throwsA(predicate((Object? e) =>
            e is ScheduleFormatException && e.message.contains('0-23'))),
      );
      expect(
        () => ScheduleSpec.parse('every 0m'),
        throwsA(predicate((Object? e) =>
            e is ScheduleFormatException && e.message.contains('zero'))),
      );
      expect(
        const ScheduleFormatException('bad').toString(),
        'ScheduleFormatException: bad',
      );
    });

    test('tryParse returns a spec for good input', () {
      expect(ScheduleSpec.tryParse('every 30m')!.kind, ScheduleKind.interval);
      expect(ScheduleSpec.tryParse('0 9 * * *')!.kind, ScheduleKind.cron);
      expect(ScheduleSpec.tryParse('30m')!.kind, ScheduleKind.oneShotIn);
      expect(ScheduleSpec.tryParse('2026-02-03T14:00')!.kind,
          ScheduleKind.oneShotAt);
    });
  });

  group('nextRuns for interval and one shots', () {
    final DateTime from = DateTime(2026, 2, 3, 10, 30);

    test('interval repeats', () {
      expect(
        ScheduleSpec.parse('every 30m').nextRuns(from),
        <DateTime>[
          DateTime(2026, 2, 3, 11),
          DateTime(2026, 2, 3, 11, 30),
          DateTime(2026, 2, 3, 12),
        ],
      );
    });

    test('interval honours count', () {
      expect(ScheduleSpec.parse('every 2h').nextRuns(from, count: 1),
          <DateTime>[DateTime(2026, 2, 3, 12, 30)]);
      expect(ScheduleSpec.parse('every 1d').nextRuns(from, count: 5).length, 5);
      expect(ScheduleSpec.parse('every 1d').nextRuns(from, count: 0), isEmpty);
    });

    test('one shot in gives exactly one run', () {
      final List<DateTime> runs =
          ScheduleSpec.parse('2h').nextRuns(from, count: 3);
      expect(runs, <DateTime>[DateTime(2026, 2, 3, 12, 30)]);
    });

    test('one shot at gives one run when it is still ahead', () {
      expect(
        ScheduleSpec.parse('2026-02-03T14:00').nextRuns(from),
        <DateTime>[DateTime(2026, 2, 3, 14)],
      );
    });

    test('one shot at in the past gives nothing', () {
      expect(ScheduleSpec.parse('2026-02-03T09:00').nextRuns(from), isEmpty);
      // Exactly `from` is not "after" `from`.
      expect(ScheduleSpec.parse('2026-02-03T10:30').nextRuns(from), isEmpty);
    });
  });

  group('nextRuns for cron', () {
    test('daily at 09:00', () {
      expect(
        ScheduleSpec.parse('0 9 * * *').nextRuns(DateTime(2026, 2, 3, 10, 30)),
        <DateTime>[
          DateTime(2026, 2, 4, 9),
          DateTime(2026, 2, 5, 9),
          DateTime(2026, 2, 6, 9),
        ],
      );
    });

    test('daily at 09:00 fires the same day when the hour is still ahead', () {
      expect(
        ScheduleSpec.parse('0 9 * * *')
            .nextRuns(DateTime(2026, 2, 3, 8, 59), count: 1),
        <DateTime>[DateTime(2026, 2, 3, 9)],
      );
    });

    test('a run is strictly after from, and seconds are dropped', () {
      // 09:00:30 is inside the 09:00 minute, so that minute is done.
      expect(
        ScheduleSpec.parse('0 9 * * *')
            .nextRuns(DateTime(2026, 2, 3, 9, 0, 30, 500), count: 1),
        <DateTime>[DateTime(2026, 2, 4, 9)],
      );
      // Exactly 09:00:00 counts as done too.
      expect(
        ScheduleSpec.parse('0 9 * * *')
            .nextRuns(DateTime(2026, 2, 3, 9), count: 1),
        <DateTime>[DateTime(2026, 2, 4, 9)],
      );
    });

    test('every 15 minutes', () {
      final List<DateTime> runs = ScheduleSpec.parse('*/15 * * * *')
          .nextRuns(DateTime(2026, 2, 3, 10, 7), count: 4);
      expect(runs, <DateTime>[
        DateTime(2026, 2, 3, 10, 15),
        DateTime(2026, 2, 3, 10, 30),
        DateTime(2026, 2, 3, 10, 45),
        DateTime(2026, 2, 3, 11),
      ]);
      for (final DateTime run in runs) {
        expect(run.second, 0);
        expect(run.millisecond, 0);
        expect(run.microsecond, 0);
      }
    });

    test('first of the month at midnight', () {
      expect(
        ScheduleSpec.parse('0 0 1 * *').nextRuns(DateTime(2026, 2, 3, 10, 30)),
        <DateTime>[
          DateTime(2026, 3, 1),
          DateTime(2026, 4, 1),
          DateTime(2026, 5, 1),
        ],
      );
    });

    test('weekdays only at noon', () {
      // 2026-02-07 is a Saturday, so the next run is Monday the 9th.
      final List<DateTime> runs = ScheduleSpec.parse('0 12 * * 1-5')
          .nextRuns(DateTime(2026, 2, 7), count: 6);
      expect(runs, <DateTime>[
        DateTime(2026, 2, 9, 12),
        DateTime(2026, 2, 10, 12),
        DateTime(2026, 2, 11, 12),
        DateTime(2026, 2, 12, 12),
        DateTime(2026, 2, 13, 12),
        DateTime(2026, 2, 16, 12),
      ]);
      for (final DateTime run in runs) {
        expect(run.weekday, lessThanOrEqualTo(DateTime.friday));
      }
    });

    test('day-of-month and day-of-week both set means OR', () {
      // The 5th of the month, or any Friday. 2026-02-05 is a Thursday and
      // 2026-02-06 is a Friday, so both fire.
      expect(
        ScheduleSpec.parse('0 12 5 * 5').nextRuns(DateTime(2026, 2, 1)),
        <DateTime>[
          DateTime(2026, 2, 5, 12),
          DateTime(2026, 2, 6, 12),
          DateTime(2026, 2, 13, 12),
        ],
      );
    });

    test('only day-of-month set means that day alone', () {
      expect(
        ScheduleSpec.parse('0 12 5 * *').nextRuns(DateTime(2026, 2, 1)),
        <DateTime>[
          DateTime(2026, 2, 5, 12),
          DateTime(2026, 3, 5, 12),
          DateTime(2026, 4, 5, 12),
        ],
      );
    });

    test('only day-of-week set means that weekday alone', () {
      expect(
        ScheduleSpec.parse('0 12 * * 5').nextRuns(DateTime(2026, 2, 1)),
        <DateTime>[
          DateTime(2026, 2, 6, 12),
          DateTime(2026, 2, 13, 12),
          DateTime(2026, 2, 20, 12),
        ],
      );
    });

    test('a schedule that cannot fire within a year returns nothing', () {
      // 2026 and 2027 are not leap years, so 30 February never comes.
      final Stopwatch watch = Stopwatch()..start();
      final List<DateTime> runs =
          ScheduleSpec.parse('0 0 30 2 *').nextRuns(DateTime(2026, 2, 3));
      watch.stop();
      expect(runs, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('a rare schedule returns fewer runs than asked for', () {
      // 29 February 2028 is more than 366 days after the start, so only the
      // first hit inside the window is returned.
      final List<DateTime> runs = ScheduleSpec.parse('0 0 29 2 *')
          .nextRuns(DateTime(2028, 1, 1), count: 3);
      expect(runs, <DateTime>[DateTime(2028, 2, 29)]);
    });

    test('every minute fills the whole count', () {
      expect(
        ScheduleSpec.parse('* * * * *')
            .nextRuns(DateTime(2026, 2, 3, 23, 58), count: 3),
        <DateTime>[
          DateTime(2026, 2, 3, 23, 59),
          DateTime(2026, 2, 4),
          DateTime(2026, 2, 4, 0, 1),
        ],
      );
    });

    test('count of zero or less returns nothing', () {
      final ScheduleSpec spec = ScheduleSpec.parse('* * * * *');
      expect(spec.nextRuns(DateTime(2026, 2, 3), count: 0), isEmpty);
      expect(spec.nextRuns(DateTime(2026, 2, 3), count: -1), isEmpty);
    });
  });

  group('describe', () {
    test('interval', () {
      expect(ScheduleSpec.parse('every 30m').describe(),
          'interval: every 30 minutes');
      expect(
          ScheduleSpec.parse('every 1d').describe(), 'interval: every 1 day');
      expect(
          ScheduleSpec.parse('every 2h').describe(), 'interval: every 2 hours');
      expect(ScheduleSpec.parse('every 45s').describe(),
          'interval: every 45 seconds');
    });

    test('cron uses the normalised text', () {
      expect(ScheduleSpec.parse('0   9 * * *').describe(), 'cron: 0 9 * * *');
      expect(ScheduleSpec.parse('*/15 * * * *').describe(),
          'cron: */15 * * * *');
    });

    test('one shot at', () {
      expect(ScheduleSpec.parse('2026-02-03T14:00').describe(),
          'once at 2026-02-03 14:00');
      expect(ScheduleSpec.parse('2026-02-03T14:00:30').describe(),
          'once at 2026-02-03 14:00:30');
    });

    test('one shot in', () {
      expect(ScheduleSpec.parse('2h').describe(), 'once in 2 hours');
      expect(ScheduleSpec.parse('1h').describe(), 'once in 1 hour');
      expect(ScheduleSpec.parse('90s').describe(), 'once in 90 seconds');
    });
  });
}
