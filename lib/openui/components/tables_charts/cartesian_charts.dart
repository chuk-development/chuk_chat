// The 2D charts on x/y axes: BarChart, LineChart, AreaChart (fl_chart)
// and HorizontalBarChart (plain widgets: a ranked list reads best as
// rows with the label above each bar, also at phone width).

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/openui/components/tables_charts/chart_common.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_theme.dart';

/// The time fl_chart takes to move to new data (a stream adds values).
const Duration _kSwap = Duration(milliseconds: 180);

/// The smallest room one x label gets before labels are skipped.
const double _kMinLabelSlot = 46;

double _textWidth(String text, TextStyle style, TextScaler scaler) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

/// The room the y axis labels need.
double _leftReserved(BuildContext context, AxisScale scale) {
  final style = chartAxisStyle(context);
  final scaler = MediaQuery.textScalerOf(context);
  var w = 0.0;
  for (
    var v = scale.min;
    v <= scale.max + scale.interval / 2;
    v += scale.interval
  ) {
    w = math.max(w, _textWidth(formatAxisValue(v), style, scaler));
  }
  return (w + 8).clamp(24.0, 72.0);
}

/// The step between two printed x labels, so labels never collide.
int _labelStep(int count, double plotWidth) {
  if (count <= 0) return 1;
  final fit = math.max(1, (plotWidth / _kMinLabelSlot).floor());
  return math.max(1, (count / fit).ceil());
}

Widget _xLabel(
  BuildContext context,
  List<String> labels,
  double value,
  int step,
  double slot,
) {
  final idx = value.round();
  if ((value - idx).abs() > 0.01 || idx < 0 || idx >= labels.length) {
    return const SizedBox.shrink();
  }
  if (idx % step != 0) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: SizedBox(
      width: math.max(24, slot * step - 4),
      child: Text(
        labels[idx],
        style: chartAxisStyle(context),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

FlTitlesData _titles(
  BuildContext context, {
  required List<String> labels,
  required AxisScale scale,
  required double leftReserved,
  required int step,
  required double slot,
}) {
  final axis = chartAxisStyle(context);
  return FlTitlesData(
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: labels.any((l) => l.isNotEmpty),
        interval: 1,
        reservedSize: 26,
        getTitlesWidget: (value, meta) =>
            _xLabel(context, labels, value, step, slot),
      ),
    ),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: scale.interval,
        reservedSize: leftReserved,
        getTitlesWidget: (value, meta) {
          // fl_chart also asks for the exact min and max; print only
          // the round ticks.
          final k = (value - scale.min) / scale.interval;
          if ((k - k.round()).abs() > 0.001) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              formatAxisValue(value),
              style: axis,
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          );
        },
      ),
    ),
  );
}

FlGridData _grid(OpenUiChartColors colors, AxisScale scale) => FlGridData(
  drawVerticalLine: false,
  horizontalInterval: scale.interval,
  getDrawingHorizontalLine: (v) => FlLine(
    color: v == 0 ? colors.palette.baseline : colors.palette.grid,
    strokeWidth: 1,
  ),
);

FlBorderData _border(OpenUiChartColors colors) => FlBorderData(
  show: true,
  border: Border(bottom: BorderSide(color: colors.palette.baseline)),
);

String _seriesName(ChartSeries s, int i) =>
    s.name.trim().isEmpty ? 'Series ${i + 1}' : s.name;

Widget? _legend(Chart2D data, OpenUiChartColors colors) {
  if (data.series.length < 2) return null;
  return ChartLegend(
    names: [
      for (var i = 0; i < data.series.length; i++)
        _seriesName(data.series[i], i),
    ],
    colors: colors,
  );
}

// -------------------------------------------------------------- BarChart

/// Builds `BarChart(labels, series, variant?, xLabel?, yLabel?, height?)`.
Widget buildBarChart(BuildContext context, OpenUiProps p) {
  final data = readChart2D(p);
  final height = chartHeight(p);
  if (!data.hasData) return chartPlaceholder(context, p, height);
  final stacked = p.choice('variant', fallback: 'grouped') == 'stacked';
  final colors = OpenUiChartColors.of(context);
  return ChartFrame(
    topLabel: p.stringOrNull('yLabel'),
    bottomLabel: p.stringOrNull('xLabel'),
    legend: _legend(data, colors),
    child: SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, c) =>
            _barChart(context, data, colors, stacked, c.maxWidth),
      ),
    ),
  );
}

Widget _barChart(
  BuildContext context,
  Chart2D data,
  OpenUiChartColors colors,
  bool stacked,
  double width,
) {
  final n = data.length;
  var lo = 0.0;
  var hi = 0.0;
  if (stacked) {
    for (var i = 0; i < n; i++) {
      var pos = 0.0;
      var neg = 0.0;
      for (final s in data.series) {
        final v = s.at(i) ?? 0;
        if (v >= 0) {
          pos += v;
        } else {
          neg += v;
        }
      }
      hi = math.max(hi, pos);
      lo = math.min(lo, neg);
    }
  } else {
    for (final v in data.allValues) {
      hi = math.max(hi, v);
      lo = math.min(lo, v);
    }
  }
  final scale = AxisScale.fit(lo, hi);
  final left = _leftReserved(context, scale);
  final plot = math.max(40.0, width - left);
  final slot = plot / math.max(1, n);
  final seriesCount = math.max(1, data.series.length);
  final rodWidth = stacked
      ? (slot * 0.62).clamp(4.0, 40.0)
      : ((slot * 0.72) / seriesCount).clamp(2.0, 28.0);
  const radius = Radius.circular(4);

  final groups = <BarChartGroupData>[];
  // The source series of each rod: a gap gives no rod, so the rod index
  // is not the series index.
  final rodSeries = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    if (stacked) {
      final items = <BarChartRodStackItem>[];
      var pos = 0.0;
      var neg = 0.0;
      for (var s = 0; s < data.series.length; s++) {
        final v = data.series[s].at(i);
        if (v == null || v == 0) continue;
        if (v > 0) {
          items.add(BarChartRodStackItem(pos, pos + v, colors.at(s)));
          pos += v;
        } else {
          items.add(BarChartRodStackItem(neg + v, neg, colors.at(s)));
          neg += v;
        }
      }
      groups.add(
        BarChartGroupData(
          x: i,
          barRods: <BarChartRodData>[
            if (items.isNotEmpty)
              BarChartRodData(
                fromY: neg,
                toY: pos,
                width: rodWidth,
                color: Colors.transparent,
                rodStackItems: items,
                borderRadius: BorderRadius.circular(4),
              ),
          ],
        ),
      );
    } else {
      final rods = <BarChartRodData>[];
      final sources = <int>[];
      for (var s = 0; s < data.series.length; s++) {
        final v = data.series[s].at(i);
        if (v == null) continue;
        sources.add(s);
        rods.add(
          BarChartRodData(
            toY: v,
            width: rodWidth,
            color: colors.at(s),
            borderRadius: v >= 0
                ? const BorderRadius.vertical(top: radius)
                : const BorderRadius.vertical(bottom: radius),
          ),
        );
      }
      rodSeries[i] = sources;
      groups.add(
        BarChartGroupData(
          x: i,
          barRods: rods,
          barsSpace: math.min(4, rodWidth * 0.25),
        ),
      );
    }
  }

  final titleStyle = chartTooltipTitleStyle(context);
  return BarChart(
    BarChartData(
      minY: scale.min,
      maxY: scale.max,
      alignment: BarChartAlignment.spaceAround,
      barGroups: groups,
      gridData: _grid(colors, scale),
      borderData: _border(colors),
      titlesData: _titles(
        context,
        labels: data.labels,
        scale: scale,
        leftReserved: left,
        step: _labelStep(n, plot),
        slot: slot,
      ),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
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
          getTooltipItem: (group, groupIndex, rod, rodIndex) {
            final i = group.x;
            final label = i >= 0 && i < n ? data.labels[i] : '';
            final lines = <TextSpan>[];
            if (stacked) {
              for (var s = data.series.length - 1; s >= 0; s--) {
                final v = data.series[s].at(i);
                if (v == null) continue;
                lines.add(
                  TextSpan(
                    text:
                        '\n${_seriesName(data.series[s], s)}: '
                        '${formatChartValue(v)}',
                    style: chartTooltipValueStyle(colors.inkAt(s)),
                  ),
                );
              }
            } else {
              final sources = rodSeries[i] ?? const <int>[];
              final s = rodIndex < sources.length ? sources[rodIndex] : 0;
              final name = data.series.length > 1
                  ? '${_seriesName(data.series[s], s)}: '
                  : '';
              lines.add(
                TextSpan(
                  text: '\n$name${formatChartValue(rod.toY)}',
                  style: chartTooltipValueStyle(colors.inkAt(s)),
                ),
              );
            }
            return BarTooltipItem(
              label,
              titleStyle,
              textAlign: TextAlign.left,
              children: lines,
            );
          },
        ),
      ),
    ),
    duration: _kSwap,
  );
}

// ------------------------------------------------------ Line / AreaChart

/// Builds `LineChart(labels, series, variant?, xLabel?, yLabel?, height?)`.
Widget buildLineChart(BuildContext context, OpenUiProps p) =>
    _buildLineLike(context, p, area: false);

/// Builds `AreaChart(labels, series, variant?, xLabel?, yLabel?, height?)`.
Widget buildAreaChart(BuildContext context, OpenUiProps p) =>
    _buildLineLike(context, p, area: true);

Widget _buildLineLike(
  BuildContext context,
  OpenUiProps p, {
  required bool area,
}) {
  final data = readChart2D(p);
  final height = chartHeight(p);
  if (!data.hasData) return chartPlaceholder(context, p, height);
  final variant = p.choice('variant', fallback: 'linear');
  final colors = OpenUiChartColors.of(context);
  return ChartFrame(
    topLabel: p.stringOrNull('yLabel'),
    bottomLabel: p.stringOrNull('xLabel'),
    legend: _legend(data, colors),
    child: SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, c) => _lineChart(
          context,
          data,
          colors,
          variant: variant,
          area: area,
          width: c.maxWidth,
        ),
      ),
    ),
  );
}

Widget _lineChart(
  BuildContext context,
  Chart2D data,
  OpenUiChartColors colors, {
  required String variant,
  required bool area,
  required double width,
}) {
  final n = data.length;
  var lo = double.infinity;
  var hi = double.negativeInfinity;
  for (final v in data.allValues) {
    lo = math.min(lo, v);
    hi = math.max(hi, v);
  }
  // An area starts at 0. A line starts at 0 too, unless the values sit
  // far from 0 (prices): then a flat line would hide the trend.
  final fromZero = area || lo <= 0 || lo < hi * 0.5;
  final scale = AxisScale.fit(lo, hi, fromZero: fromZero);
  final left = _leftReserved(context, scale);
  final plot = math.max(40.0, width - left);
  final slot = plot / math.max(1, n);
  final dark = colors.palette.isDark;
  final surface = Theme.of(context).colorScheme.surfaceContainerLow;

  final bars = <LineChartBarData>[];
  for (var s = 0; s < data.series.length; s++) {
    final series = data.series[s];
    final color = colors.at(s);
    final spots = <FlSpot>[
      for (var i = 0; i < n; i++)
        if (series.at(i) case final v?)
          FlSpot(i.toDouble(), v)
        else
          FlSpot.nullSpot,
    ];
    final points = series.values.where((v) => v != null).length;
    bars.add(
      LineChartBarData(
        spots: spots,
        color: color,
        barWidth: n > 100 ? 1.6 : 2.4,
        isCurved: variant == 'natural',
        preventCurveOverShooting: true,
        curveSmoothness: 0.3,
        isStepLineChart: variant == 'step',
        isStrokeCapRound: true,
        isStrokeJoinRound: true,
        dotData: FlDotData(
          show: n <= 24 || points == 1,
          getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
            radius: 3,
            color: color,
            strokeWidth: 1.5,
            strokeColor: surface,
          ),
        ),
        belowBarData: BarAreaData(
          show: area,
          color: color.withValues(
            alpha: data.series.length > 1
                ? (dark ? 0.16 : 0.12)
                : (dark ? 0.24 : 0.18),
          ),
        ),
      ),
    );
  }

  return LineChart(
    LineChartData(
      minX: n == 1 ? -0.5 : 0,
      maxX: n == 1 ? 0.5 : (n - 1).toDouble(),
      minY: scale.min,
      maxY: scale.max,
      lineBarsData: bars,
      gridData: _grid(colors, scale),
      borderData: _border(colors),
      titlesData: _titles(
        context,
        labels: data.labels,
        scale: scale,
        leftReserved: left,
        step: _labelStep(n, plot),
        slot: slot,
      ),
      lineTouchData: LineTouchData(
        getTouchedSpotIndicator: (bar, indexes) => [
          for (final _ in indexes)
            TouchedSpotIndicatorData(
              FlLine(color: colors.palette.baseline, strokeWidth: 1),
              FlDotData(
                getDotPainter: (spot, percent, b, index) => FlDotCirclePainter(
                  radius: 4.5,
                  color: b.color ?? colors.at(0),
                  strokeWidth: 2,
                  strokeColor: surface,
                ),
              ),
            ),
        ],
        touchTooltipData: LineTouchTooltipData(
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
          getTooltipItems: (spots) => <LineTooltipItem?>[
            for (var k = 0; k < spots.length; k++)
              _lineTooltip(context, data, colors, spots[k], first: k == 0),
          ],
        ),
      ),
    ),
    duration: _kSwap,
  );
}

LineTooltipItem _lineTooltip(
  BuildContext context,
  Chart2D data,
  OpenUiChartColors colors,
  LineBarSpot spot, {
  required bool first,
}) {
  final s = spot.barIndex;
  final name = data.series.length > 1 && s < data.series.length
      ? '${_seriesName(data.series[s], s)}: '
      : '';
  final value = TextSpan(
    text: '$name${formatChartValue(spot.y)}',
    style: chartTooltipValueStyle(colors.inkAt(s)),
  );
  final i = spot.x.round();
  final label = first && i >= 0 && i < data.length ? data.labels[i] : '';
  return LineTooltipItem(
    label.isEmpty ? '' : '$label\n',
    chartTooltipTitleStyle(context),
    textAlign: TextAlign.left,
    children: <TextSpan>[value],
  );
}

// ---------------------------------------------------- HorizontalBarChart

/// Builds `HorizontalBarChart(labels, series, variant?, xLabel?, yLabel?)`.
///
/// One row per category: the label above, the bar under it, the value
/// at the right in tabular figures. Long labels stay readable at phone
/// width, which is what upstream picks this chart for.
Widget buildHorizontalBarChart(BuildContext context, OpenUiProps p) {
  final data = readChart2D(p);
  if (!data.hasData) return chartPlaceholder(context, p, 160);
  final stacked = p.choice('variant', fallback: 'grouped') == 'stacked';
  final colors = OpenUiChartColors.of(context);
  final yLabel = p.string('yLabel').trim();
  final xLabel = p.string('xLabel').trim();
  final caption = chartCaptionStyle(context)
      .copyWith(fontWeight: FontWeight.w600);
  return ChartFrame(
    legend: _legend(data, colors),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (yLabel.isNotEmpty || xLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    yLabel,
                    style: caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (xLabel.isNotEmpty)
                  Expanded(
                    child: Text(
                      xLabel,
                      style: caption,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        _HorizontalBars(data: data, colors: colors, stacked: stacked),
      ],
    ),
  );
}

class _HorizontalBars extends StatelessWidget {
  const _HorizontalBars({
    required this.data,
    required this.colors,
    required this.stacked,
  });

  final Chart2D data;
  final OpenUiChartColors colors;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final n = data.length;
    var lo = 0.0;
    var hi = 0.0;
    final totals = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      var pos = 0.0;
      var neg = 0.0;
      for (final s in data.series) {
        final v = s.at(i);
        if (v == null) continue;
        if (stacked) {
          if (v >= 0) {
            pos += v;
          } else {
            neg += v;
          }
          totals[i] += v;
        } else {
          hi = math.max(hi, v);
          lo = math.min(lo, v);
        }
      }
      if (stacked) {
        hi = math.max(hi, pos);
        lo = math.min(lo, neg);
      }
    }
    if (hi == lo) hi = lo + 1;

    final labelStyle = TextStyle(
      fontSize: 12.5,
      height: 1.25,
      color: t.textColor,
    );
    final valueStyle = TextStyle(
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w600,
      color: t.textColor,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final scaler = MediaQuery.textScalerOf(context);
    var valueWidth = 0.0;
    for (var i = 0; i < n; i++) {
      if (stacked) {
        valueWidth = math.max(
          valueWidth,
          _textWidth(formatChartValue(totals[i]), valueStyle, scaler),
        );
      } else {
        for (final s in data.series) {
          final v = s.at(i);
          if (v == null) continue;
          valueWidth = math.max(
            valueWidth,
            _textWidth(formatChartValue(v), valueStyle, scaler),
          );
        }
      }
    }
    valueWidth = math.min(valueWidth + 2, 96);
    final barHeight = stacked || data.series.length == 1 ? 12.0 : 8.0;
    final track = colors.palette.grid;

    Widget barRow(Widget bar, String value, {Color? valueColor}) => SizedBox(
      height: math.max(barHeight, 16),
      child: Row(
        children: <Widget>[
          Expanded(child: bar),
          const SizedBox(width: 8),
          SizedBox(
            width: valueWidth,
            child: Text(
              value,
              style: valueStyle.copyWith(color: valueColor),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
            ),
          ),
        ],
      ),
    );

    final rows = <Widget>[];
    for (var i = 0; i < n; i++) {
      final bars = <Widget>[];
      if (stacked) {
        final parts = <(double, double, Color)>[];
        var pos = 0.0;
        var neg = 0.0;
        for (var s = 0; s < data.series.length; s++) {
          final v = data.series[s].at(i);
          if (v == null || v == 0) continue;
          if (v > 0) {
            parts.add((pos, pos + v, colors.at(s)));
            pos += v;
          } else {
            parts.add((neg + v, neg, colors.at(s)));
            neg += v;
          }
        }
        bars.add(
          barRow(
            _BarTrack(
              lo: lo,
              hi: hi,
              parts: parts,
              height: barHeight,
              track: track,
            ),
            formatChartValue(totals[i]),
          ),
        );
      } else {
        for (var s = 0; s < data.series.length; s++) {
          final v = data.series[s].at(i);
          if (v == null) continue;
          bars.add(
            barRow(
              _BarTrack(
                lo: lo,
                hi: hi,
                parts: <(double, double, Color)>[
                  (math.min(0, v), math.max(0, v), colors.at(s)),
                ],
                height: barHeight,
                track: track,
              ),
              formatChartValue(v),
              valueColor: data.series.length > 1 ? colors.inkAt(s) : null,
            ),
          );
        }
      }
      if (bars.isEmpty) continue;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                data.labels[i].isEmpty ? '${i + 1}' : data.labels[i],
                style: labelStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              for (var b = 0; b < bars.length; b++)
                Padding(
                  padding: EdgeInsets.only(top: b == 0 ? 0 : 3),
                  child: bars[b],
                ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

/// One horizontal bar on a quiet track. [parts] are value ranges with
/// their colours, on the scale [lo]..[hi].
class _BarTrack extends StatelessWidget {
  const _BarTrack({
    required this.lo,
    required this.hi,
    required this.parts,
    required this.height,
    required this.track,
  });

  final double lo;
  final double hi;
  final List<(double, double, Color)> parts;
  final double height;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth.isFinite ? c.maxWidth : 0.0;
            double x(double v) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0) * w;
            final r = Radius.circular(height / 2);
            return ClipRRect(
              borderRadius: BorderRadius.all(r),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(child: ColoredBox(color: track)),
                  for (var k = 0; k < parts.length; k++)
                    Positioned(
                      left: x(parts[k].$1),
                      width: math.max(
                        0,
                        x(parts[k].$2) -
                            x(parts[k].$1) -
                            (k < parts.length - 1 ? 2 : 0),
                      ),
                      top: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: parts[k].$3,
                          borderRadius: BorderRadius.all(r),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
