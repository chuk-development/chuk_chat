// lib/widgets/charts/chart_spec.dart
//
// The declarative chart the coworker draws with.
//
// The agent does not lay out a chart. It says "these are the categories, these
// are the values, this is the line at 5" and the app draws it: the value above
// each bar, the category under it, an axis on the left, the app's card, the
// app's radii, the app's motion. One JSON shape covers an election result, a
// gains-and-losses panel, a crypto day and a multi-series price curve.
//
// ---------------------------------------------------------------------------
// THE JSON (this comment is the contract the Python side is written against)
// ---------------------------------------------------------------------------
//
// {
//   "kind": "bar",                  // bar | column_delta | line | grouped | stacked
//   "title": "Landtagswahl Sachsen-Anhalt",
//   "subtitle": "Vorläufiges Endergebnis, Zweitstimmen",
//   "unit": "%",                    // "%" | "€" | "$" | "" | any short suffix
//   "sort": "given",                // given | desc | asc  (default: given)
//   "decimals": 1,                  // optional; inferred from the data if absent
//   "decimal_separator": ",",       // "." (default) or ","
//   "axis": {"min": 0, "max": 50},  // both optional; omit for automatic
//   "reference_line": {"value": 5, "label": "5 %-Hürde"},
//   "source": "Landeswahlleiter",
//   "retrieved_at": "2026-09-12T20:15:00Z",
//   "show_values": true,            // default true for bars, false for lines
//   "points": [                     // single-series shorthand
//     {"label": "AfD",  "value": 43.8, "color": "#0089D0"},
//     {"label": "CDU",  "value": 17.2, "color": "#151518", "note": "…"}
//   ]
// }
//
// Several series instead of one — `series` replaces `points`:
//
// {
//   "kind": "line",
//   "title": "BTC und ETH, 7 Tage",
//   "unit": "$",
//   "series": [
//     {"name": "BTC", "direction": "up",
//      "points": [{"label": "Mo", "value": 61200}, {"label": "Di", "value": 62800}]},
//     {"name": "ETH", "direction": "down", "color": "#8A92B2",
//      "points": [{"label": "Mo", "value": 3410}, {"label": "Di", "value": 3180}]}
//   ]
// }
//
// Field notes
// -----------
// * kind
//     bar            vertical bars from the baseline, the election case.
//     column_delta   the same bars, but a negative value hangs BELOW the
//                    baseline and is red while a positive one is green — the
//                    "Gewinne und Verluste" panel, or a red crypto day.
//                    Per-point "color" still wins when it is given.
//     line           a value over time. One or more series, a dot per point,
//                    the last value called out.
//     grouped        several series side by side per category.
//     stacked        several series stacked into one bar per category.
//     Unknown kinds fall back to `bar`, they never fail the render.
// * points[].label   the category, drawn UNDER the bar.
// * points[].value   number, or a numeric string ("43.8", "43,8", "12%").
// * points[].color   "#RRGGBB" or "#AARRGGBB", with or without the "#".
//                    Absent: the app's own palette, or the up/down pair.
// * points[].note    one short line shown when the point is the only one
//                    carrying a note, or in the fallback table. Never drawn
//                    over the chart.
// * series[].direction  "up" | "down" | "auto" (default). Picks the theme's
//                    green/red pair instead of a palette colour. "auto"
//                    compares the last value against the first.
// * axis.min/max     clamped to include every value; omit to let the app pick
//                    a round headroom above the tallest bar.
// * reference_line   one horizontal rule with a small label at its right end.
//                    The 5 % threshold in his picture.
// * retrieved_at     ISO-8601. Printed next to `source` as a quiet footer.
//
// Anything missing, wrong-typed or empty produces a [ChartSpec] with
// `problems` filled in; a spec with no usable point is `unusable` and the
// widget draws a quiet fallback (the values as a small table, or a one-line
// note) instead of throwing. Nothing in this file can throw on bad input —
// that is the point of it.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// What the chart draws.
enum ChartKind {
  /// Vertical bars from a zero baseline. The default.
  bar,

  /// Vertical bars that hang below the baseline when negative, coloured by
  /// sign — gains and losses.
  columnDelta,

  /// A value over time, one polyline per series.
  line,

  /// Several series side by side per category.
  grouped,

  /// Several series stacked into one bar per category.
  stacked;

  /// The kind [raw] names, or [bar] when it names nothing known.
  static ChartKind parse(Object? raw) {
    final String k = raw is String ? raw.trim().toLowerCase() : '';
    switch (k) {
      case 'bar':
      case 'bars':
      case 'column':
      case 'columns':
      case 'vbar':
        return ChartKind.bar;
      case 'column_delta':
      case 'columndelta':
      case 'delta':
      case 'deltas':
      case 'change':
      case 'gains_losses':
      case 'gains-and-losses':
      case 'gewinne_verluste':
      case 'diverging':
        return ChartKind.columnDelta;
      case 'line':
      case 'lines':
      case 'trend':
      case 'timeseries':
      case 'time_series':
      case 'area':
        return ChartKind.line;
      case 'grouped':
      case 'group':
      case 'grouped_bar':
      case 'clustered':
        return ChartKind.grouped;
      case 'stacked':
      case 'stack':
      case 'stacked_bar':
        return ChartKind.stacked;
      default:
        return ChartKind.bar;
    }
  }

  /// True when the kind paints bars rather than a polyline.
  bool get isBarFamily => this != ChartKind.line;

  /// True when several series are drawn against one category axis.
  bool get isMultiSeries =>
      this == ChartKind.grouped ||
      this == ChartKind.stacked ||
      this == ChartKind.line;
}

/// How the points are ordered before they are drawn.
enum ChartSort {
  /// The order the agent wrote them in.
  given,

  /// Biggest value first.
  descending,

  /// Smallest value first.
  ascending;

  static ChartSort parse(Object? raw) {
    final String s = raw is String ? raw.trim().toLowerCase() : '';
    switch (s) {
      case 'desc':
      case 'descending':
      case 'value_desc':
        return ChartSort.descending;
      case 'asc':
      case 'ascending':
      case 'value_asc':
        return ChartSort.ascending;
      default:
        return ChartSort.given;
    }
  }
}

/// Whether a series is a good thing going up or a bad thing going down. Used
/// to pick the theme's green/red pair instead of a palette hue.
enum ChartDirection {
  /// Pick the colour by comparing the last value to the first.
  auto,

  /// Force the theme's positive colour.
  up,

  /// Force the theme's negative colour.
  down,

  /// Never use the up/down pair — take a palette colour.
  neutral;

  static ChartDirection parse(Object? raw) {
    final String d = raw is String ? raw.trim().toLowerCase() : '';
    switch (d) {
      case 'up':
      case 'gain':
      case 'positive':
      case 'bull':
        return ChartDirection.up;
      case 'down':
      case 'loss':
      case 'negative':
      case 'bear':
        return ChartDirection.down;
      case 'auto':
        return ChartDirection.auto;
      case 'neutral':
      case 'none':
      case 'flat':
        return ChartDirection.neutral;
      default:
        return ChartDirection.auto;
    }
  }
}

/// One category and its value.
@immutable
class ChartPoint {
  const ChartPoint({
    required this.label,
    required this.value,
    this.color,
    this.note,
  });

  /// The category, drawn under the bar.
  final String label;

  /// The height of the bar. Negative hangs below the baseline.
  final double value;

  /// The colour the agent asked for, or null to let the app pick.
  final Color? color;

  /// One short line of context. Never painted over the plot.
  final String? note;

  @override
  bool operator ==(Object other) =>
      other is ChartPoint &&
      other.label == label &&
      other.value == value &&
      other.color == color &&
      other.note == note;

  @override
  int get hashCode => Object.hash(label, value, color, note);
}

/// One line or one bar family.
@immutable
class ChartSeries {
  const ChartSeries({
    required this.points,
    this.name,
    this.color,
    this.direction = ChartDirection.auto,
  });

  final List<ChartPoint> points;

  /// Shown in the legend when there is more than one series.
  final String? name;

  /// The colour for the whole series. Null lets the app pick.
  final Color? color;

  final ChartDirection direction;

  /// The sign of the series read from its own numbers: the last value against
  /// the first. Zero-length and flat series read as up.
  bool get risesOverall {
    if (points.length < 2) return true;
    return points.last.value >= points.first.value;
  }

  /// The direction to colour by, with [ChartDirection.auto] resolved.
  ChartDirection get resolvedDirection => switch (direction) {
    ChartDirection.auto =>
      risesOverall ? ChartDirection.up : ChartDirection.down,
    final ChartDirection d => d,
  };
}

/// The optional min/max the agent asked for.
@immutable
class ChartAxis {
  const ChartAxis({this.min, this.max});

  final double? min;
  final double? max;

  bool get isEmpty => min == null && max == null;
}

/// One horizontal rule across the plot — the 5 % threshold.
@immutable
class ChartReferenceLine {
  const ChartReferenceLine({required this.value, this.label, this.color});

  final double value;
  final String? label;
  final Color? color;
}

/// A parsed, validated chart.
///
/// Construction never throws. Every field that could not be read is either
/// defaulted or recorded in [problems]; when nothing drawable survived,
/// [unusable] is true and the caller draws the fallback.
@immutable
class ChartSpec {
  const ChartSpec({
    required this.kind,
    required this.series,
    this.title,
    this.subtitle,
    this.unit = '',
    this.sort = ChartSort.given,
    this.axis = const ChartAxis(),
    this.referenceLine,
    this.source,
    this.retrievedAt,
    this.decimals,
    this.decimalSeparator = '.',
    this.showValues,
    this.height,
    this.problems = const <String>[],
    this.rawFallbackText,
  });

  final ChartKind kind;

  /// Always at least one entry for a usable spec. A single-series chart holds
  /// exactly one.
  final List<ChartSeries> series;

  final String? title;
  final String? subtitle;

  /// A short suffix: "%", "€", "$", "kg". Drawn on the axis and, when it fits,
  /// on the value labels.
  final String unit;

  final ChartSort sort;
  final ChartAxis axis;
  final ChartReferenceLine? referenceLine;
  final String? source;
  final DateTime? retrievedAt;

  /// Digits after the separator. Null means "work it out from the values".
  final int? decimals;

  /// "." or ",". German charts want the comma.
  final String decimalSeparator;

  /// Null means the kind decides: bars print their value, lines do not.
  final bool? showValues;

  /// A plot height in logical pixels, when the agent insists. Clamped later.
  final double? height;

  /// Everything that was wrong with the input, in the order it was found.
  /// A usable chart can still carry problems (a dropped point, say).
  final List<String> problems;

  /// What the fallback shows when the input was not even a chart object —
  /// the original text, trimmed.
  final String? rawFallbackText;

  /// True when there is nothing to draw.
  bool get unusable =>
      series.isEmpty || series.every((ChartSeries s) => s.points.isEmpty);

  /// The categories, in drawing order, taken from the longest series.
  List<String> get categories {
    if (series.isEmpty) return const <String>[];
    ChartSeries longest = series.first;
    for (final ChartSeries s in series) {
      if (s.points.length > longest.points.length) longest = s;
    }
    return longest.points.map((ChartPoint p) => p.label).toList();
  }

  /// Every value in every series.
  Iterable<double> get values =>
      series.expand((ChartSeries s) => s.points.map((ChartPoint p) => p.value));

  /// True when any value is below zero — the plot then needs a baseline in
  /// the middle rather than at the bottom.
  bool get hasNegative => values.any((double v) => v < 0);

  /// Whether values are printed at the bars.
  bool get drawsValueLabels => showValues ?? kind.isBarFamily;

  /// True when the unit is printed ONCE, over the axis, instead of on every
  /// bar. Ten bars on a phone cannot each carry "43,8 %" — the newspaper
  /// answer is a "%" at the top of the axis and bare numbers on the bars.
  bool get unitOverAxis => unit.isNotEmpty && kind.isBarFamily;

  /// How many digits to print, worked out from the data when the agent did
  /// not say. Two at the most: a bar label is not a spreadsheet cell.
  int get effectiveDecimals {
    final int? asked = decimals;
    if (asked != null) return asked.clamp(0, 4);
    int most = 0;
    for (final double v in values) {
      if (v == v.roundToDouble()) continue;
      final String s = v.abs().toStringAsFixed(4);
      final String frac = s.split('.').last.replaceAll(RegExp(r'0+$'), '');
      if (frac.length > most) most = frac.length;
      if (most >= 2) return 2;
    }
    return most;
  }

  /// [value] as it is printed at a bar or on the axis.
  String format(double value, {bool withUnit = true, bool signed = false}) {
    final int d = effectiveDecimals;
    String text = value.toStringAsFixed(d);
    if (decimalSeparator != '.') {
      text = text.replaceFirst('.', decimalSeparator);
    }
    if (signed && value > 0) text = '+$text';
    if (withUnit && unit.isNotEmpty) {
      // A currency sign leads, everything else trails. "$12" but "12 %".
      if (unit == r'$' || unit == '£' || unit == '¥') {
        final bool negative = text.startsWith('-');
        text = negative ? '-$unit${text.substring(1)}' : '$unit$text';
      } else {
        text = '$text $unit';
      }
    }
    return text;
  }

  /// The spec with [sort] applied. Multi-series charts share one category
  /// order, so the first series decides it and the rest follow by label.
  ChartSpec sorted() {
    if (sort == ChartSort.given || series.isEmpty) return this;
    final ChartSeries first = series.first;
    final List<ChartPoint> ordered = List<ChartPoint>.of(first.points)
      ..sort(
        (ChartPoint a, ChartPoint b) => sort == ChartSort.descending
            ? b.value.compareTo(a.value)
            : a.value.compareTo(b.value),
      );
    final List<String> order = ordered
        .map((ChartPoint p) => p.label)
        .toList(growable: false);
    List<ChartPoint> reorder(ChartSeries s) {
      final Map<String, ChartPoint> byLabel = <String, ChartPoint>{
        for (final ChartPoint p in s.points) p.label: p,
      };
      final List<ChartPoint> out = <ChartPoint>[];
      for (final String label in order) {
        final ChartPoint? p = byLabel.remove(label);
        if (p != null) out.add(p);
      }
      out.addAll(byLabel.values);
      return out;
    }

    return copyWith(
      series: <ChartSeries>[
        for (final ChartSeries s in series)
          ChartSeries(
            points: identical(s, first) ? ordered : reorder(s),
            name: s.name,
            color: s.color,
            direction: s.direction,
          ),
      ],
      sort: ChartSort.given,
    );
  }

  ChartSpec copyWith({
    ChartKind? kind,
    List<ChartSeries>? series,
    ChartSort? sort,
    List<String>? problems,
  }) => ChartSpec(
    kind: kind ?? this.kind,
    series: series ?? this.series,
    title: title,
    subtitle: subtitle,
    unit: unit,
    sort: sort ?? this.sort,
    axis: axis,
    referenceLine: referenceLine,
    source: source,
    retrievedAt: retrievedAt,
    decimals: decimals,
    decimalSeparator: decimalSeparator,
    showValues: showValues,
    height: height,
    problems: problems ?? this.problems,
    rawFallbackText: rawFallbackText,
  );

  /// A spec that draws nothing but says why.
  factory ChartSpec.broken(List<String> problems, {String? raw, String? title}) =>
      ChartSpec(
        kind: ChartKind.bar,
        series: const <ChartSeries>[],
        title: title,
        problems: problems,
        rawFallbackText: raw,
      );

  /// Reads a chart out of anything: a decoded map, a JSON string, a list of
  /// points. Never throws; a hopeless input comes back [unusable].
  factory ChartSpec.parse(Object? input) {
    if (input == null) {
      return ChartSpec.broken(const <String>['no chart data']);
    }
    if (input is String) {
      final String text = input.trim();
      if (text.isEmpty) {
        return ChartSpec.broken(const <String>['no chart data']);
      }
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException catch (e) {
        return ChartSpec.broken(<String>[
          'the chart is not valid JSON (${e.message})',
        ], raw: text);
      }
      final ChartSpec spec = ChartSpec.parse(decoded);
      return spec.unusable && spec.rawFallbackText == null
          ? ChartSpec(
              kind: spec.kind,
              series: spec.series,
              title: spec.title,
              problems: spec.problems,
              rawFallbackText: text,
            )
          : spec;
    }
    if (input is List) {
      // A bare list of points is a bar chart.
      return ChartSpec.parse(<String, Object?>{'points': input});
    }
    if (input is! Map) {
      return ChartSpec.broken(<String>[
        'a chart must be an object, not ${input.runtimeType}',
      ], raw: '$input');
    }

    final Map<Object?, Object?> map = input;
    final List<String> problems = <String>[];

    Object? at(List<String> keys) {
      for (final String k in keys) {
        final Object? v = map[k];
        if (v != null) return v;
      }
      return null;
    }

    final ChartKind kind = ChartKind.parse(at(<String>['kind', 'type', 'chart']));
    final String? title = _asText(at(<String>['title', 'headline', 'name']));
    final String? subtitle = _asText(
      at(<String>['subtitle', 'caption', 'sub_title', 'subhead']),
    );
    final String unit = _asText(at(<String>['unit', 'suffix', 'units'])) ?? '';
    final ChartSort sort = ChartSort.parse(at(<String>['sort', 'order']));
    final String? source = _asText(at(<String>['source', 'credit']));
    final DateTime? retrievedAt = _asDate(
      at(<String>['retrieved_at', 'retrievedAt', 'as_of', 'asOf', 'date']),
    );
    final int? decimals = _asInt(at(<String>['decimals', 'precision']));
    final String sep =
        _asText(
          at(<String>['decimal_separator', 'decimalSeparator']),
        )?.trim() ??
        '.';
    final bool? showValues = _asBool(
      at(<String>['show_values', 'showValues', 'value_labels']),
    );
    final double? height = _asNumber(at(<String>['height', 'plot_height']));

    // --- axis -------------------------------------------------------------
    ChartAxis axis = const ChartAxis();
    final Object? axisRaw = at(<String>['axis', 'y_axis', 'yAxis', 'scale']);
    if (axisRaw is Map) {
      axis = ChartAxis(
        min: _asNumber(axisRaw['min'] ?? axisRaw['minimum']),
        max: _asNumber(axisRaw['max'] ?? axisRaw['maximum']),
      );
    } else if (axisRaw != null) {
      problems.add('axis must be an object with min and max');
    }
    final double? flatMin = _asNumber(at(<String>['min', 'y_min']));
    final double? flatMax = _asNumber(at(<String>['max', 'y_max']));
    if (axis.isEmpty && (flatMin != null || flatMax != null)) {
      axis = ChartAxis(min: flatMin, max: flatMax);
    }

    // --- reference line ----------------------------------------------------
    ChartReferenceLine? reference;
    final Object? refRaw = at(<String>[
      'reference_line',
      'referenceLine',
      'threshold',
      'hurdle',
      'target',
    ]);
    if (refRaw is Map) {
      final double? v = _asNumber(refRaw['value'] ?? refRaw['at'] ?? refRaw['y']);
      if (v == null) {
        problems.add('the reference line has no numeric value');
      } else {
        reference = ChartReferenceLine(
          value: v,
          label: _asText(refRaw['label'] ?? refRaw['text']),
          color: parseChartColor(refRaw['color']),
        );
      }
    } else if (refRaw is num) {
      reference = ChartReferenceLine(value: refRaw.toDouble());
    } else if (refRaw != null) {
      problems.add('the reference line must be a number or an object');
    }

    // --- series ------------------------------------------------------------
    final List<ChartSeries> series = <ChartSeries>[];
    final Object? seriesRaw = at(<String>['series', 'datasets', 'lines']);
    final Object? pointsRaw = at(<String>[
      'points',
      'rows',
      'data',
      'values',
      'bars',
      'items',
    ]);

    if (seriesRaw is List) {
      for (int i = 0; i < seriesRaw.length; i++) {
        final Object? s = seriesRaw[i];
        if (s is! Map) {
          problems.add('series ${i + 1} is not an object');
          continue;
        }
        final Object? sp =
            s['points'] ?? s['data'] ?? s['values'] ?? s['rows'];
        final List<ChartPoint> pts = _parsePoints(
          sp,
          problems,
          where: 'series ${i + 1}, ',
          xLabels: _labelList(at(<String>['x_labels', 'xLabels', 'labels'])),
        );
        if (pts.isEmpty) continue;
        series.add(
          ChartSeries(
            points: pts,
            name: _asText(s['name'] ?? s['label'] ?? s['title']),
            color: parseChartColor(s['color']),
            direction: ChartDirection.parse(s['direction'] ?? s['trend']),
          ),
        );
      }
    } else if (seriesRaw != null) {
      problems.add('series must be a list');
    }

    if (series.isEmpty) {
      final List<ChartPoint> pts = _parsePoints(
        pointsRaw,
        problems,
        where: '',
        xLabels: _labelList(at(<String>['x_labels', 'xLabels', 'labels'])),
      );
      if (pts.isNotEmpty) {
        series.add(
          ChartSeries(
            points: pts,
            name: _asText(at(<String>['series_name', 'seriesName'])),
            color: parseChartColor(at(<String>['color'])),
            direction: ChartDirection.parse(at(<String>['direction', 'trend'])),
          ),
        );
      }
    }

    if (series.isEmpty && problems.isEmpty) {
      problems.add('the chart has no points');
    }

    final ChartSpec spec = ChartSpec(
      kind: kind,
      series: series,
      title: title,
      subtitle: subtitle,
      unit: unit,
      sort: sort,
      axis: axis,
      referenceLine: reference,
      source: source,
      retrievedAt: retrievedAt,
      decimals: decimals,
      decimalSeparator: sep == ',' ? ',' : '.',
      showValues: showValues,
      height: height,
      problems: problems,
      rawFallbackText: series.isEmpty ? _preview(map) : null,
    );
    return spec.sorted();
  }

  /// A short, readable echo of an object that did not parse, for the fallback.
  static String _preview(Object? value) {
    try {
      final String text = const JsonEncoder.withIndent('  ').convert(value);
      return text.length > 1200 ? '${text.substring(0, 1200)}…' : text;
    } catch (_) {
      return '$value';
    }
  }
}

/// Reads a list of points. Accepts three shapes, because all three turn up in
/// model output: a list of objects, a list of `[label, value]` pairs, and a
/// bare list of numbers (labelled from `x_labels`, or 1..n).
List<ChartPoint> _parsePoints(
  Object? raw,
  List<String> problems, {
  required String where,
  List<String>? xLabels,
}) {
  if (raw == null) return const <ChartPoint>[];
  if (raw is Map) {
    // {"AfD": 43.8, "CDU": 17.2} — an ordered map is a perfectly good chart.
    final List<ChartPoint> out = <ChartPoint>[];
    raw.forEach((Object? k, Object? v) {
      final double? value = _asNumber(v);
      if (value == null) return;
      out.add(ChartPoint(label: '$k', value: value));
    });
    if (out.isEmpty) problems.add('${where}the points hold no numbers');
    return out;
  }
  if (raw is! List) {
    problems.add('${where}the points must be a list');
    return const <ChartPoint>[];
  }

  final List<ChartPoint> out = <ChartPoint>[];
  for (int i = 0; i < raw.length; i++) {
    final Object? item = raw[i];
    String? label;
    double? value;
    Color? color;
    String? note;

    if (item is Map) {
      label = _asText(
        item['label'] ??
            item['name'] ??
            item['category'] ??
            item['party'] ??
            item['x'] ??
            item['key'],
      );
      value = _asNumber(item['value'] ?? item['y'] ?? item['amount']);
      color = parseChartColor(item['color'] ?? item['colour']);
      note = _asText(item['note'] ?? item['annotation']);
    } else if (item is List && item.length >= 2) {
      label = _asText(item[0]);
      value = _asNumber(item[1]);
    } else {
      value = _asNumber(item);
    }

    if (value == null) {
      problems.add(
        '${where}entry ${i + 1}${label == null ? '' : ' ($label)'} '
        'is not a number',
      );
      continue;
    }
    label ??= (xLabels != null && i < xLabels.length)
        ? xLabels[i]
        : '${i + 1}';
    out.add(ChartPoint(label: label, value: value, color: color, note: note));
  }
  return out;
}

List<String>? _labelList(Object? raw) {
  if (raw is! List) return null;
  return raw.map((Object? e) => '$e').toList(growable: false);
}

String? _asText(Object? raw) {
  if (raw == null) return null;
  final String s = raw is String ? raw : '$raw';
  final String t = s.trim();
  return t.isEmpty ? null : t;
}

bool? _asBool(Object? raw) {
  if (raw is bool) return raw;
  if (raw is String) {
    final String s = raw.trim().toLowerCase();
    if (s == 'true' || s == 'yes') return true;
    if (s == 'false' || s == 'no') return false;
  }
  return null;
}

int? _asInt(Object? raw) {
  final double? d = _asNumber(raw);
  return d?.round();
}

/// A number out of a number, or out of the many ways a model writes one:
/// "43.8", "43,8", "12 %", "$1,240.50", "1.240,50".
double? _asNumber(Object? raw) {
  if (raw is num) {
    final double v = raw.toDouble();
    return v.isFinite ? v : null;
  }
  if (raw is! String) return null;
  String s = raw.trim();
  if (s.isEmpty) return null;
  // Strip currency and percent decoration, keep the sign.
  s = s.replaceAll(RegExp(r'[%\s €$£¥]'), '');
  if (s.isEmpty) return null;
  final double? plain = double.tryParse(s);
  if (plain != null && plain.isFinite) return plain;
  final int lastComma = s.lastIndexOf(',');
  final int lastDot = s.lastIndexOf('.');
  if (lastComma >= 0 && lastDot >= 0) {
    // Whichever comes last is the decimal mark; the other groups thousands.
    if (lastComma > lastDot) {
      s = s.replaceAll('.', '').replaceFirst(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
  } else if (lastComma >= 0) {
    // "1,5" is a decimal; "1,240" with exactly three digits is a group.
    final String tail = s.substring(lastComma + 1);
    s = tail.length == 3 && s.indexOf(',') != lastComma
        ? s.replaceAll(',', '')
        : s.replaceFirst(',', '.');
  }
  final double? v = double.tryParse(s);
  return (v != null && v.isFinite) ? v : null;
}

DateTime? _asDate(Object? raw) {
  if (raw is DateTime) return raw;
  if (raw is! String) return null;
  return DateTime.tryParse(raw.trim());
}

/// "#RRGGBB", "RRGGBB", "#AARRGGBB" or an int, into a [Color]. Anything else
/// is null, because a colour the model invented ("blue") is not a reason to
/// lose the chart.
Color? parseChartColor(Object? raw) {
  if (raw is int) return Color(raw);
  if (raw is! String) return null;
  String hex = raw.trim();
  if (hex.isEmpty) return null;
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.startsWith('0x') || hex.startsWith('0X')) hex = hex.substring(2);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
  if (hex.length == 3) {
    hex = hex.split('').map((String c) => '$c$c').join();
  }
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final int? v = int.tryParse(hex, radix: 16);
  return v == null ? null : Color(v);
}
