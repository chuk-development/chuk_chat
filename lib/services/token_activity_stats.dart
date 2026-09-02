import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/usage_logs_service.dart';

/// How the token-activity heatmap colours each day cell.
///
/// The grid always has one cell per calendar day; the mode only changes the
/// value each cell is coloured by:
/// * [daily] — that day's own token sum.
/// * [weekly] — the total of the ISO week (Mon–Sun) the day belongs to, so
///   every cell in a week shares one colour.
/// * [cumulative] — the running total of every day up to and including this
///   one, so the grid darkens monotonically from oldest to newest.
enum HeatmapMode { daily, weekly, cumulative }

/// One calendar day of token activity.
///
/// [day] is a local-date midnight (`DateTime(year, month, day)`), never a
/// timestamp. [tokens] is the sum of `totalTokens` for that day. [requests]
/// is the number of `usage_logs` rows that fell on that day; a day is
/// "active" for streak purposes when [requests] `>= 1`, independent of the
/// token count (a media request can carry tokens but no text, and a row can
/// legitimately report zero tokens).
@immutable
class DailyTokenPoint {
  const DailyTokenPoint({
    required this.day,
    required this.tokens,
    required this.requests,
  });

  final DateTime day;
  final int tokens;
  final int requests;

  bool get isActive => requests >= 1;

  @override
  bool operator ==(Object other) =>
      other is DailyTokenPoint &&
      other.day == day &&
      other.tokens == tokens &&
      other.requests == requests;

  @override
  int get hashCode => Object.hash(day, tokens, requests);

  @override
  String toString() =>
      'DailyTokenPoint(day: $day, tokens: $tokens, requests: $requests)';
}

/// The result of aggregating a single [UsageLogsService] fetch for the
/// token-activity panel: the per-active-day series plus both streak numbers.
///
/// The heatmap and both streaks are derived here from the same list so they
/// can never drift apart.
@immutable
class TokenActivityStats {
  const TokenActivityStats({
    required this.daily,
    required this.currentStreak,
    required this.longestStreak,
  });

  /// One point per active day (a day with `>= 1` row), sorted ascending by
  /// [DailyTokenPoint.day]. Days with no activity are NOT present here; use
  /// [TokenActivityStatsService.denseSeries] to get a gap-filled series for
  /// the grid.
  final List<DailyTokenPoint> daily;

  /// Consecutive active days ending at (or the day before) today. See
  /// [TokenActivityStatsService.computeCurrentStreak] for the exact "today
  /// not yet active" rule.
  final int currentStreak;

  /// The longest run of consecutive active days ever recorded.
  final int longestStreak;

  bool get isEmpty => daily.isEmpty;

  int get totalActiveDays => daily.length;
}

/// Pure aggregation for the token-activity panel. Stateless: every method is
/// a deterministic function of its inputs (pass `now` to pin "today"), which
/// keeps the streak and bucketing maths unit-testable without a widget or a
/// live clock.
class TokenActivityStatsService {
  const TokenActivityStatsService._();

  /// Strip a [DateTime] to its local calendar date (midnight). Timezone /
  /// offset information is dropped on purpose: two timestamps on the same
  /// wall-clock day must bucket together.
  static DateTime dateOnly(DateTime value) {
    final DateTime local = value.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// Add [days] calendar days to a local date. Built from the date components
  /// (not `Duration`) so it is DST-safe — a 23h or 25h day never shifts the
  /// result onto the wrong calendar date.
  static DateTime addDays(DateTime day, int days) =>
      DateTime(day.year, day.month, day.day + days);

  /// The Monday (ISO week start) of the week that contains [day].
  static DateTime mondayOf(DateTime day) {
    final DateTime d = dateOnly(day);
    return addDays(d, -(d.weekday - DateTime.monday));
  }

  /// Build the full token-activity aggregate from one already-fetched list of
  /// usage entries.
  ///
  /// Entries with a null [UsageLogEntry.createdAt] are skipped. Days are
  /// bucketed by their LOCAL calendar date. Pass [now] to pin "today" for
  /// deterministic tests; it defaults to `DateTime.now()`.
  static TokenActivityStats build(
    List<UsageLogEntry> entries, {
    DateTime? now,
  }) {
    final Map<DateTime, _DayAggregate> byDay = <DateTime, _DayAggregate>{};

    for (final UsageLogEntry entry in entries) {
      final DateTime? createdAt = entry.createdAt;
      if (createdAt == null) {
        continue;
      }
      final DateTime day = dateOnly(createdAt);
      final _DayAggregate agg = byDay.putIfAbsent(day, _DayAggregate.new);
      agg.tokens += entry.totalTokens;
      agg.requests += 1;
    }

    final List<DailyTokenPoint> daily =
        byDay.entries
            .map(
              (entry) => DailyTokenPoint(
                day: entry.key,
                tokens: entry.value.tokens,
                requests: entry.value.requests,
              ),
            )
            .toList(growable: false)
          ..sort((a, b) => a.day.compareTo(b.day));

    final Set<DateTime> activeDays = byDay.keys.toSet();
    final DateTime today = dateOnly(now ?? DateTime.now());

    return TokenActivityStats(
      daily: daily,
      currentStreak: computeCurrentStreak(activeDays, today),
      longestStreak: computeLongestStreak(activeDays),
    );
  }

  /// Consecutive active days ending at [today].
  ///
  /// Rule: if [today] is active, the streak counts today and every earlier
  /// unbroken day. If today has no activity yet but yesterday does, the
  /// streak still counts — anchored at yesterday — so a day that has simply
  /// not started does not reset a run the reader is still on. If neither
  /// today nor yesterday is active, the current streak is 0.
  static int computeCurrentStreak(Set<DateTime> activeDays, DateTime today) {
    final DateTime anchor = dateOnly(today);
    DateTime cursor;
    if (activeDays.contains(anchor)) {
      cursor = anchor;
    } else if (activeDays.contains(addDays(anchor, -1))) {
      cursor = addDays(anchor, -1);
    } else {
      return 0;
    }

    int streak = 0;
    while (activeDays.contains(cursor)) {
      streak += 1;
      cursor = addDays(cursor, -1);
    }
    return streak;
  }

  /// The longest run of consecutive active days anywhere in [activeDays].
  static int computeLongestStreak(Set<DateTime> activeDays) {
    if (activeDays.isEmpty) {
      return 0;
    }

    final List<DateTime> days = activeDays.toList(growable: false)
      ..sort((a, b) => a.compareTo(b));

    int longest = 1;
    int run = 1;
    for (int i = 1; i < days.length; i++) {
      if (days[i] == addDays(days[i - 1], 1)) {
        run += 1;
      } else {
        run = 1;
      }
      if (run > longest) {
        longest = run;
      }
    }
    return longest;
  }

  /// A gap-filled, week-aligned day series for the heatmap grid.
  ///
  /// The series starts on the Monday of the earliest week to show and ends on
  /// [now]/today, with one [DailyTokenPoint] per calendar day (missing days
  /// get tokens 0, requests 0). Starting on a Monday keeps the 7-row grid
  /// columns aligned. [maxWeeks] caps how far back the window reaches
  /// (default 53, about a year, like a GitHub contribution graph). Returns an
  /// empty list when [stats] has no activity.
  static List<DailyTokenPoint> denseSeries(
    TokenActivityStats stats, {
    DateTime? now,
    int maxWeeks = 53,
  }) {
    if (stats.daily.isEmpty) {
      return const <DailyTokenPoint>[];
    }

    final DateTime today = dateOnly(now ?? DateTime.now());
    final DateTime firstActive = stats.daily.first.day;

    // Oldest Monday we will draw: the later of the first activity's week and
    // the window cap counted back from today's week.
    final DateTime windowStart = mondayOf(addDays(today, -(maxWeeks - 1) * 7));
    final DateTime firstMonday = mondayOf(firstActive);
    final DateTime start = firstMonday.isAfter(windowStart)
        ? firstMonday
        : windowStart;

    final Map<DateTime, DailyTokenPoint> lookup = <DateTime, DailyTokenPoint>{
      for (final DailyTokenPoint point in stats.daily) point.day: point,
    };

    final List<DailyTokenPoint> series = <DailyTokenPoint>[];
    DateTime cursor = start;
    while (!cursor.isAfter(today)) {
      series.add(
        lookup[cursor] ?? DailyTokenPoint(day: cursor, tokens: 0, requests: 0),
      );
      cursor = addDays(cursor, 1);
    }
    return series;
  }

  /// The value each cell of [series] is coloured by, in the given [mode]. The
  /// returned list is parallel to [series] (same length, same order). Pure so
  /// the mode toggle is unit-testable without a widget.
  static List<int> heatmapValues(
    List<DailyTokenPoint> series,
    HeatmapMode mode,
  ) {
    switch (mode) {
      case HeatmapMode.daily:
        return series.map((point) => point.tokens).toList(growable: false);
      case HeatmapMode.cumulative:
        int running = 0;
        return series
            .map((point) {
              running += point.tokens;
              return running;
            })
            .toList(growable: false);
      case HeatmapMode.weekly:
        final Map<DateTime, int> weekTotals = <DateTime, int>{};
        for (final DailyTokenPoint point in series) {
          final DateTime week = mondayOf(point.day);
          weekTotals[week] = (weekTotals[week] ?? 0) + point.tokens;
        }
        return series
            .map((point) => weekTotals[mondayOf(point.day)] ?? 0)
            .toList(growable: false);
    }
  }
}

class _DayAggregate {
  int tokens = 0;
  int requests = 0;
}
