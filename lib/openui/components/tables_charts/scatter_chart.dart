// ScatterChart: named point sets on x/y axes (fl_chart).

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/openui/components/tables_charts/chart_common.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';

/// One point of a scatter set. [z] sizes the dot when present.
@immutable
class ScatterPoint {
  /// Creates a point.
  const ScatterPoint(this.x, this.y, [this.z]);

  /// The x value.
  final double x;

  /// The y value.
  final double y;

  /// The optional size value.
  final double? z;
}

/// One named scatter set.
@immutable
class ScatterSet {
  /// Creates a set.
  const ScatterSet(this.name, this.points);

  /// The set name.
  final String name;

  /// The valid points.
  final List<ScatterPoint> points;
}

ScatterPoint? _point(Object? x, Object? y, Object? z) {
  final px = chartNumber(x);
  final py = chartNumber(y);
  if (px == null || py == null) return null;
  return ScatterPoint(px, py, chartNumber(z));
}

/// Reads the `datasets` of a ScatterChart. `Point` items and object
/// literals `{x, y, z?}` are both read; a point without a numeric x and
/// y is skipped.
List<ScatterSet> readScatter(OpenUiProps p) {
  final out = <ScatterSet>[];
  for (final ds in p.data('datasets', type: 'ScatterSeries')) {
    final points = <ScatterPoint>[];
    for (final pt in ds.data('points', type: 'Point')) {
      final v = _point(pt.raw('x'), pt.raw('y'), pt.raw('z'));
      if (v != null) points.add(v);
    }
    for (final m in ds.mapList('points')) {
      final v = _point(m['x'], m['y'], m['z']);
      if (v != null) points.add(v);
    }
    out.add(ScatterSet(ds.string('name'), points));
  }
  // Object-literal sets: {name, points: [{x, y}]}.
  for (final m in p.mapList('datasets')) {
    final raw = m['points'];
    final points = <ScatterPoint>[
      if (raw is List)
        for (final pt in raw)
          if (pt is Map) ?_point(pt['x'], pt['y'], pt['z']),
    ];
    out.add(ScatterSet('${m['name'] ?? ''}', points));
  }
  return out;
}

/// Builds `ScatterChart(datasets, xLabel?, yLabel?)`.
Widget buildScatterChart(BuildContext context, OpenUiProps p) {
  final sets = readScatter(p);
  final height = chartHeight(p, fallback: 240);
  if (!sets.any((s) => s.points.isNotEmpty)) {
    return chartPlaceholder(context, p, height);
  }
  final colors = OpenUiChartColors.of(context);
  var x0 = double.infinity;
  var x1 = double.negativeInfinity;
  var y0 = double.infinity;
  var y1 = double.negativeInfinity;
  var z0 = double.infinity;
  var z1 = double.negativeInfinity;
  for (final s in sets) {
    for (final pt in s.points) {
      x0 = math.min(x0, pt.x);
      x1 = math.max(x1, pt.x);
      y0 = math.min(y0, pt.y);
      y1 = math.max(y1, pt.y);
      if (pt.z != null) {
        z0 = math.min(z0, pt.z!);
        z1 = math.max(z1, pt.z!);
      }
    }
  }
  final xs = AxisScale.fit(x0, x1, fromZero: x0 >= 0 && x0 < x1 * 0.5);
  final ys = AxisScale.fit(y0, y1, fromZero: y0 >= 0 && y0 < y1 * 0.5);
  final total = sets.fold<int>(0, (a, s) => a + s.points.length);
  final baseRadius = total > 200 ? 3.0 : (total > 60 ? 4.0 : 5.0);
  final surface = Theme.of(context).colorScheme.surfaceContainerLow;

  double radiusOf(double? z) {
    if (z == null || !z0.isFinite || z1 <= z0) return baseRadius;
    return 4 + (z - z0) / (z1 - z0) * 10;
  }

  final spots = <ScatterSpot>[];
  final owner = <ScatterSpot, int>{};
  for (var s = 0; s < sets.length; s++) {
    final color = colors.at(s);
    for (final pt in sets[s].points) {
      final spot = ScatterSpot(
        pt.x,
        pt.y,
        dotPainter: FlDotCirclePainter(
          radius: radiusOf(pt.z),
          color: color.withValues(alpha: 0.85),
          strokeWidth: 1,
          strokeColor: surface,
        ),
      );
      spots.add(spot);
      owner[spot] = s;
    }
  }

  final axis = chartAxisStyle(context);
  Widget tick(double value, AxisScale scale, {required bool left}) {
    final k = (value - scale.min) / scale.interval;
    if ((k - k.round()).abs() > 0.001) return const SizedBox.shrink();
    return Padding(
      padding: left
          ? const EdgeInsets.only(right: 6)
          : const EdgeInsets.only(top: 6),
      child: Text(formatAxisValue(value), style: axis, maxLines: 1),
    );
  }

  final names = [
    for (var s = 0; s < sets.length; s++)
      sets[s].name.trim().isEmpty
          ? openUiStrings(context).openUiSeriesN('${s + 1}')
          : sets[s].name,
  ];
  final grid = FlLine(color: colors.palette.grid, strokeWidth: 1);
  return ChartFrame(
    topLabel: p.stringOrNull('yLabel'),
    bottomLabel: p.stringOrNull('xLabel'),
    legend: sets.length > 1 ? ChartLegend(names: names, colors: colors) : null,
    child: SizedBox(
      height: height,
      child: ScatterChart(
        ScatterChartData(
          scatterSpots: spots,
          minX: xs.min,
          maxX: xs.max,
          minY: ys.min,
          maxY: ys.max,
          gridData: FlGridData(
            horizontalInterval: ys.interval,
            verticalInterval: xs.interval,
            getDrawingHorizontalLine: (_) => grid,
            getDrawingVerticalLine: (_) => grid,
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              bottom: BorderSide(color: colors.palette.baseline),
              left: BorderSide(color: colors.palette.baseline),
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: xs.interval,
                reservedSize: 24,
                getTitlesWidget: (v, meta) => tick(v, xs, left: false),
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: ys.interval,
                reservedSize: 40,
                getTitlesWidget: (v, meta) => tick(v, ys, left: true),
              ),
            ),
          ),
          scatterTouchData: ScatterTouchData(
            touchTooltipData: ScatterTouchTooltipData(
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              maxContentWidth: 200,
              tooltipBorderRadius: BorderRadius.circular(10),
              tooltipPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 7,
              ),
              tooltipBorder: chartTooltipBorder(context),
              getTooltipColor: (_) => chartTooltipColor(context),
              getTooltipItems: (spot) {
                final s = owner[spot] ?? 0;
                return ScatterTooltipItem(
                  sets.length > 1 ? '${names[s]}\n' : '',
                  textStyle: chartTooltipTitleStyle(context),
                  textAlign: TextAlign.left,
                  children: <TextSpan>[
                    TextSpan(
                      text:
                          '${formatChartValue(spot.x)}, '
                          '${formatChartValue(spot.y)}',
                      style: chartTooltipValueStyle(colors.inkAt(s)),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        duration: const Duration(milliseconds: 180),
      ),
    ),
  );
}
