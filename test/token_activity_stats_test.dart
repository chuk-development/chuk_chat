import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/token_activity_stats.dart';
import 'package:chuk_chat/services/usage_logs_service.dart';

/// Minimal usage entry for the stats math: only [createdAt] and the token
/// count matter here, the rest are neutral defaults.
UsageLogEntry _entry(DateTime? createdAt, {int tokens = 10}) {
  return UsageLogEntry(
    modelId: 'test-model',
    providerSlug: 'test-provider',
    promptTokens: tokens,
    completionTokens: 0,
    totalTokens: tokens,
    totalCostUsd: 0,
    creditsDeductedEur: 0,
    createdAt: createdAt,
  );
}

/// A local-date midnight, so tests never depend on the machine timezone.
DateTime _d(int year, int month, int day) => DateTime(year, month, day);

void main() {
  group('date helpers', () {
    test('dateOnly strips the time of day', () {
      final DateTime result = TokenActivityStatsService.dateOnly(
        DateTime(2026, 3, 10, 18, 42, 7),
      );
      expect(result, DateTime(2026, 3, 10));
    });

    test('addDays rolls back across a month boundary', () {
      expect(
        TokenActivityStatsService.addDays(_d(2026, 3, 1), -1),
        _d(2026, 2, 28),
      );
    });

    test('addDays rolls back across a year boundary', () {
      expect(
        TokenActivityStatsService.addDays(_d(2026, 1, 1), -1),
        _d(2025, 12, 31),
      );
    });

    test('mondayOf returns the ISO week start', () {
      // 2026-06-17 is a Wednesday; its Monday is 2026-06-15.
      expect(_d(2026, 6, 17).weekday, DateTime.wednesday);
      expect(
        TokenActivityStatsService.mondayOf(_d(2026, 6, 17)),
        _d(2026, 6, 15),
      );
      // A Monday maps to itself.
      expect(
        TokenActivityStatsService.mondayOf(_d(2026, 6, 15)),
        _d(2026, 6, 15),
      );
      // A Sunday maps back to the same week's Monday.
      expect(
        TokenActivityStatsService.mondayOf(_d(2026, 6, 21)),
        _d(2026, 6, 15),
      );
    });
  });

  group('buildTokenActivityStats — empty and null', () {
    test('empty input yields empty stats and zero streaks', () {
      final TokenActivityStats stats = TokenActivityStatsService.build(
        const <UsageLogEntry>[],
        now: _d(2026, 6, 17),
      );
      expect(stats.isEmpty, isTrue);
      expect(stats.daily, isEmpty);
      expect(stats.currentStreak, 0);
      expect(stats.longestStreak, 0);
    });

    test('entries with a null timestamp are skipped', () {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(null, tokens: 999),
        _entry(DateTime(2026, 6, 17, 9), tokens: 5),
      ], now: _d(2026, 6, 17));
      expect(stats.daily, hasLength(1));
      expect(stats.daily.single.tokens, 5);
      expect(stats.daily.single.requests, 1);
    });
  });

  group('buildTokenActivityStats — single day', () {
    test('one active day today: both streaks are 1', () {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(DateTime(2026, 6, 17, 12), tokens: 42),
      ], now: _d(2026, 6, 17));
      expect(stats.daily, hasLength(1));
      expect(stats.daily.single.day, _d(2026, 6, 17));
      expect(stats.daily.single.tokens, 42);
      expect(stats.currentStreak, 1);
      expect(stats.longestStreak, 1);
    });
  });

  group('local-date bucketing', () {
    test('two rows on the same local day merge into one bucket', () {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(DateTime(2026, 3, 10, 8, 30), tokens: 30),
        _entry(DateTime(2026, 3, 10, 20, 15), tokens: 70),
      ], now: _d(2026, 3, 10));
      expect(stats.daily, hasLength(1));
      expect(stats.daily.single.day, _d(2026, 3, 10));
      expect(stats.daily.single.tokens, 100);
      expect(stats.daily.single.requests, 2);
    });

    test('rows either side of local midnight split into two days', () {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(DateTime(2026, 3, 10, 23, 59), tokens: 1),
        _entry(DateTime(2026, 3, 11, 0, 1), tokens: 2),
      ], now: _d(2026, 3, 11));
      expect(stats.daily, hasLength(2));
      expect(stats.daily.first.day, _d(2026, 3, 10));
      expect(stats.daily.last.day, _d(2026, 3, 11));
    });

    test('a UTC instant buckets by its local calendar date', () {
      final DateTime utc = DateTime.utc(2026, 6, 17, 15, 30);
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(utc, tokens: 8),
      ], now: TokenActivityStatsService.dateOnly(utc.toLocal()));
      expect(
        stats.daily.single.day,
        TokenActivityStatsService.dateOnly(utc.toLocal()),
      );
      expect(stats.currentStreak, 1);
    });

    test('daily series is sorted ascending by day', () {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(DateTime(2026, 6, 5, 9)),
        _entry(DateTime(2026, 6, 1, 9)),
        _entry(DateTime(2026, 6, 3, 9)),
      ], now: _d(2026, 6, 5));
      expect(stats.daily.map((p) => p.day).toList(), <DateTime>[
        _d(2026, 6, 1),
        _d(2026, 6, 3),
        _d(2026, 6, 5),
      ]);
    });
  });

  group('computeCurrentStreak', () {
    test('counts consecutive days ending today', () {
      final active = <DateTime>{_d(2026, 9, 1), _d(2026, 9, 2), _d(2026, 9, 3)};
      expect(
        TokenActivityStatsService.computeCurrentStreak(active, _d(2026, 9, 3)),
        3,
      );
    });

    test('today not yet active but yesterday active still counts', () {
      final active = <DateTime>{_d(2026, 9, 1), _d(2026, 9, 2)};
      expect(
        TokenActivityStatsService.computeCurrentStreak(active, _d(2026, 9, 3)),
        2,
      );
    });

    test('neither today nor yesterday active resets to zero', () {
      final active = <DateTime>{_d(2026, 9, 1)};
      expect(
        TokenActivityStatsService.computeCurrentStreak(active, _d(2026, 9, 3)),
        0,
      );
    });

    test('a gap before today breaks the run at the gap', () {
      final active = <DateTime>{
        _d(2026, 9, 1),
        _d(2026, 9, 2),
        _d(2026, 9, 4),
        _d(2026, 9, 5),
        _d(2026, 9, 6),
      };
      expect(
        TokenActivityStatsService.computeCurrentStreak(active, _d(2026, 9, 6)),
        3,
      );
    });

    test('empty active set is zero', () {
      expect(
        TokenActivityStatsService.computeCurrentStreak(
          const <DateTime>{},
          _d(2026, 9, 6),
        ),
        0,
      );
    });

    test('current streak spans a month boundary', () {
      final active = <DateTime>{
        _d(2026, 2, 27),
        _d(2026, 2, 28),
        _d(2026, 3, 1),
      };
      expect(
        TokenActivityStatsService.computeCurrentStreak(active, _d(2026, 3, 1)),
        3,
      );
    });
  });

  group('computeLongestStreak', () {
    test('longest run differs from the current run', () {
      final active = <DateTime>{
        // A 4-day run in the past ...
        _d(2026, 8, 1),
        _d(2026, 8, 2),
        _d(2026, 8, 3),
        _d(2026, 8, 4),
        // ... then a gap and a 2-day run ending "now".
        _d(2026, 8, 10),
        _d(2026, 8, 11),
      };
      expect(TokenActivityStatsService.computeLongestStreak(active), 4);
      expect(
        TokenActivityStatsService.computeCurrentStreak(active, _d(2026, 8, 11)),
        2,
      );
    });

    test('single isolated day is a longest streak of 1', () {
      expect(
        TokenActivityStatsService.computeLongestStreak(<DateTime>{
          _d(2026, 8, 10),
        }),
        1,
      );
    });

    test('empty set is zero', () {
      expect(
        TokenActivityStatsService.computeLongestStreak(const <DateTime>{}),
        0,
      );
    });

    test('longest run crosses a month boundary', () {
      final active = <DateTime>{
        _d(2026, 1, 30),
        _d(2026, 1, 31),
        _d(2026, 2, 1),
        _d(2026, 2, 2),
      };
      expect(TokenActivityStatsService.computeLongestStreak(active), 4);
    });
  });

  group('buildDenseSeries', () {
    test('empty stats yields an empty series', () {
      final stats = TokenActivityStatsService.build(
        const <UsageLogEntry>[],
        now: _d(2026, 6, 17),
      );
      expect(
        TokenActivityStatsService.denseSeries(stats, now: _d(2026, 6, 17)),
        isEmpty,
      );
    });

    test('fills gaps, starts on a Monday, ends today', () {
      final stats = TokenActivityStatsService.build(
        <UsageLogEntry>[
          _entry(DateTime(2026, 6, 10, 9), tokens: 100), // Wed
          _entry(DateTime(2026, 6, 12, 9), tokens: 50), // Fri
        ],
        now: _d(2026, 6, 14), // Sun
      );
      final series = TokenActivityStatsService.denseSeries(
        stats,
        now: _d(2026, 6, 14),
      );

      // Starts on the Monday of the first active week.
      expect(
        series.first.day,
        TokenActivityStatsService.mondayOf(_d(2026, 6, 10)),
      );
      expect(series.first.day.weekday, DateTime.monday);
      // Ends on today.
      expect(series.last.day, _d(2026, 6, 14));
      // One point per calendar day, inclusive.
      expect(series, hasLength(7));

      // Gap days are present with zero activity.
      final DailyTokenPoint gap = series.firstWhere(
        (p) => p.day == _d(2026, 6, 11),
      );
      expect(gap.tokens, 0);
      expect(gap.requests, 0);
      expect(gap.isActive, isFalse);

      // Active days keep their tokens.
      expect(series.firstWhere((p) => p.day == _d(2026, 6, 10)).tokens, 100);
    });

    test('maxWeeks caps how far back the window reaches', () {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(DateTime(2024, 1, 1, 9)), // long ago
        _entry(DateTime(2026, 6, 14, 9)),
      ], now: _d(2026, 6, 14));
      final series = TokenActivityStatsService.denseSeries(
        stats,
        now: _d(2026, 6, 14),
        maxWeeks: 4,
      );
      // 4 weeks * 7 days, aligned to Monday and ending today.
      expect(series.length, lessThanOrEqualTo(4 * 7));
      expect(series.first.day.weekday, DateTime.monday);
      expect(series.last.day, _d(2026, 6, 14));
    });

    test(
      'activity before the window is excluded from the grid but kept in '
      'streaks and cumulative stays a window-only running total',
      () {
        final stats = TokenActivityStatsService.build(<UsageLogEntry>[
          // Far older run, before any reasonable window.
          _entry(DateTime(2024, 1, 1, 9), tokens: 5000),
          _entry(DateTime(2024, 1, 2, 9), tokens: 5000),
          // Recent activity inside the window.
          _entry(DateTime(2026, 6, 10, 9), tokens: 100),
          _entry(DateTime(2026, 6, 14, 9), tokens: 40),
        ], now: _d(2026, 6, 14));

        final series = TokenActivityStatsService.denseSeries(
          stats,
          now: _d(2026, 6, 14),
          maxWeeks: 4,
        );

        // Old days are not drawn: nothing before the window start.
        expect(series.first.day.isAfter(_d(2024, 1, 2)), isTrue);
        expect(series.any((p) => p.day == _d(2024, 1, 1)), isFalse);

        // But the full history still feeds the all-time stats.
        expect(stats.daily.first.day, _d(2024, 1, 1));

        // Cumulative is a running total across the SHOWN days only; it does
        // not fold in the 10000 pre-window tokens, matching the caption.
        final cumulative = TokenActivityStatsService.heatmapValues(
          series,
          HeatmapMode.cumulative,
        );
        expect(cumulative.last, 140);
      },
    );
  });

  group('heatmapValues', () {
    // A single ISO week (Mon 2026-06-08 .. Sun 2026-06-14) with two active
    // days, used across the mode assertions below.
    List<DailyTokenPoint> buildWeekSeries() {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(DateTime(2026, 6, 10, 9), tokens: 100), // Wed
        _entry(DateTime(2026, 6, 12, 9), tokens: 50), // Fri
      ], now: _d(2026, 6, 14));
      return TokenActivityStatsService.denseSeries(stats, now: _d(2026, 6, 14));
    }

    test('daily mode returns each day\'s own tokens', () {
      final series = buildWeekSeries();
      final values = TokenActivityStatsService.heatmapValues(
        series,
        HeatmapMode.daily,
      );
      expect(values, series.map((p) => p.tokens).toList());
      expect(values, <int>[0, 0, 100, 0, 50, 0, 0]);
    });

    test('cumulative mode returns a running total', () {
      final series = buildWeekSeries();
      final values = TokenActivityStatsService.heatmapValues(
        series,
        HeatmapMode.cumulative,
      );
      expect(values, <int>[0, 0, 100, 100, 150, 150, 150]);
    });

    test('weekly mode colours every day by its week total', () {
      final series = buildWeekSeries();
      final values = TokenActivityStatsService.heatmapValues(
        series,
        HeatmapMode.weekly,
      );
      // All seven days share the same ISO week, so all share the 150 total.
      expect(values, List<int>.filled(7, 150));
    });

    test('weekly mode separates two different weeks', () {
      final stats = TokenActivityStatsService.build(<UsageLogEntry>[
        _entry(DateTime(2026, 6, 10, 9), tokens: 100), // week of 06-08
        _entry(DateTime(2026, 6, 17, 9), tokens: 40), // week of 06-15
      ], now: _d(2026, 6, 17));
      final series = TokenActivityStatsService.denseSeries(
        stats,
        now: _d(2026, 6, 17),
      );
      final values = TokenActivityStatsService.heatmapValues(
        series,
        HeatmapMode.weekly,
      );

      for (int i = 0; i < series.length; i++) {
        final int expected =
            TokenActivityStatsService.mondayOf(series[i].day) == _d(2026, 6, 8)
            ? 100
            : 40;
        expect(values[i], expected, reason: 'day ${series[i].day}');
      }
    });
  });
}
