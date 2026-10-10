// The 1D charts (PieChart, RadialChart, SingleStackedBarChart) and the
// RadarChart.
//
// The 1D charts are painted here, not with fl_chart: the semi-circle,
// the ring gaps and the radial bars need full control, and the legend
// prints every value and its share (a phone has no hover).

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/openui/components/tables_charts/cartesian_charts.dart';
import 'package:chuk_chat/openui/components/tables_charts/chart_common.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';

/// Above this width the round chart and its legend sit side by side.
const double _kSideBySide = 440;

/// Lays out a round chart [figure] and its legend.
Widget _roundLayout({
  required Widget Function(double size) figure,
  required Widget legend,
  double maxSize = 220,
  double heightFactor = 1,
}) {
  return LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 360.0;
      if (w >= _kSideBySide) {
        final size = math.min(maxSize, w * 0.42);
        return Row(
          children: <Widget>[
            SizedBox(
              width: size,
              height: size * heightFactor,
              child: figure(size),
            ),
            const SizedBox(width: 24),
            Expanded(child: legend),
          ],
        );
      }
      final size = math.min(maxSize, w);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: SizedBox(
              width: size,
              height: size * heightFactor,
              child: figure(size),
            ),
          ),
          const SizedBox(height: 14),
          legend,
        ],
      );
    },
  );
}

/// The slices a round chart can draw: positive values only.
List<ChartSlice> _drawable(List<ChartSlice> slices) => [
  for (final s in slices)
    if (s.value > 0) s,
];

// -------------------------------------------------------------- PieChart

/// Builds `PieChart(labels, values, variant?, appearance?)`.
Widget buildPieChart(BuildContext context, OpenUiProps p) {
  final slices = _drawable(readChart1D(p));
  if (slices.isEmpty) return chartPlaceholder(context, p, 180);
  final donut = p.choice('variant', fallback: 'pie') == 'donut';
  final semi = p.choice('appearance', fallback: 'circular') == 'semiCircular';
  final colors = OpenUiChartColors.of(context);
  final t = OpenUiTheme.of(context);
  final total = slices.fold<double>(0, (a, s) => a + s.value);
  return ChartFrame(
    child: _roundLayout(
      heightFactor: semi ? 0.56 : 1,
      figure: (size) => Stack(
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _PiePainter(
                values: [for (final s in slices) s.value],
                colors: [for (var i = 0; i < slices.length; i++) colors.at(i)],
                gapColor: t.cardColor,
                donut: donut,
                semi: semi,
              ),
            ),
          ),
          if (donut)
            Align(
              alignment: semi ? Alignment.bottomCenter : Alignment.center,
              child: _CenterTotal(total: total, size: size),
            ),
        ],
      ),
      legend: SliceLegend(slices: slices, colors: colors),
    ),
  );
}

class _CenterTotal extends StatelessWidget {
  const _CenterTotal({required this.total, required this.size});

  final double total;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return SizedBox(
      width: size * 0.5,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formatChartValue(total),
              maxLines: 1,
              style: TextStyle(
                fontSize: (size * 0.1).clamp(14.0, 22.0),
                fontWeight: FontWeight.w700,
                color: t.textColor,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(
            openUiStrings(context).openUiTotal,
            style: chartCaptionStyle(context),
          ),
        ],
      ),
    );
  }
}

class _PiePainter extends CustomPainter {
  _PiePainter({
    required this.values,
    required this.colors,
    required this.gapColor,
    required this.donut,
    required this.semi,
  });

  final List<double> values;
  final List<Color> colors;
  final Color gapColor;
  final bool donut;
  final bool semi;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (a, v) => a + v);
    if (total <= 0 || size.isEmpty) return;
    final radius = semi
        ? math.min(size.width / 2, size.height - 2)
        : math.min(size.width, size.height) / 2;
    final center = semi
        ? Offset(size.width / 2, size.height - 1)
        : size.center(Offset.zero);
    final full = semi ? math.pi : 2 * math.pi;
    final start0 = semi ? math.pi : -math.pi / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final gapWidth = values.length > 1 ? 2.0 : 0.0;

    if (donut) {
      final thickness = radius * 0.34;
      final arcRect = rect.deflate(thickness / 2);
      // The angle of a 2 px gap on the middle of the ring.
      final gap = gapWidth / (radius - thickness / 2);
      var start = start0;
      for (var i = 0; i < values.length; i++) {
        final sweep = values[i] / total * full;
        final drawn = math.max(0.0, sweep - gap);
        if (drawn > 0) {
          canvas.drawArc(
            arcRect,
            start + (sweep - drawn) / 2,
            drawn,
            false,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = thickness
              ..color = colors[i],
          );
        }
        start += sweep;
      }
      return;
    }

    var start = start0;
    final sep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = gapWidth
      ..color = gapColor;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * full;
      canvas.drawArc(rect, start, sweep, true, Paint()..color = colors[i]);
      start += sweep;
    }
    if (gapWidth > 0) {
      start = start0;
      for (var i = 0; i < values.length; i++) {
        canvas.drawLine(
          center,
          center + Offset(math.cos(start), math.sin(start)) * radius,
          sep,
        );
        start += values[i] / total * full;
      }
      if (semi) {
        canvas.drawLine(
          center,
          center + Offset(math.cos(start), math.sin(start)) * radius,
          sep,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.donut != donut ||
      old.semi != semi ||
      old.gapColor != gapColor ||
      !_sameList(old.values, values) ||
      !_sameList(old.colors, colors);
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ----------------------------------------------------------- RadialChart

/// Builds `RadialChart(labels, values)`: one ring per category, the
/// arc length is the value against the largest value.
Widget buildRadialChart(BuildContext context, OpenUiProps p) {
  final all = readChart1D(p);
  final slices = [
    for (final s in all)
      if (s.value >= 0) s,
  ];
  if (slices.isEmpty || slices.every((s) => s.value == 0)) {
    return chartPlaceholder(context, p, 180);
  }
  final colors = OpenUiChartColors.of(context);
  return ChartFrame(
    child: _roundLayout(
      figure: (size) => CustomPaint(
        painter: _RadialPainter(
          values: [for (final s in slices) s.value],
          colors: [for (var i = 0; i < slices.length; i++) colors.at(i)],
          track: colors.palette.grid,
        ),
      ),
      legend: SliceLegend(slices: slices, colors: colors, showShare: false),
    ),
  );
}

class _RadialPainter extends CustomPainter {
  _RadialPainter({
    required this.values,
    required this.colors,
    required this.track,
  });

  final List<double> values;
  final List<Color> colors;
  final Color track;

  /// The sweep of the largest value: three quarters of a circle.
  static const double _maxSweep = 1.5 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.isEmpty) return;
    final max = values.reduce(math.max);
    if (max <= 0) return;
    final center = size.center(Offset.zero);
    final outer = math.min(size.width, size.height) / 2;
    final inner = outer * 0.22;
    final band = (outer - inner) / values.length;
    final thickness = (band * 0.68).clamp(3.0, 18.0);
    for (var i = 0; i < values.length; i++) {
      final r = outer - band * i - thickness / 2;
      if (r <= thickness / 2) break;
      final rect = Rect.fromCircle(center: center, radius: r);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        rect,
        -math.pi / 2,
        _maxSweep,
        false,
        stroke..color = track,
      );
      final sweep = values[i] / max * _maxSweep;
      if (sweep > 0.001) {
        canvas.drawArc(
          rect,
          -math.pi / 2,
          sweep,
          false,
          stroke..color = colors[i],
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RadialPainter old) =>
      old.track != track ||
      !_sameList(old.values, values) ||
      !_sameList(old.colors, colors);
}

// ------------------------------------------------- SingleStackedBarChart

/// Builds `SingleStackedBarChart(labels, values)`: one bar split into
/// its parts, then a legend with the values and shares.
Widget buildSingleStackedBarChart(BuildContext context, OpenUiProps p) {
  final slices = _drawable(readChart1D(p));
  if (slices.isEmpty) return chartPlaceholder(context, p, 60);
  final colors = OpenUiChartColors.of(context);
  final total = slices.fold<double>(0, (a, s) => a + s.value);
  return ChartFrame(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 16,
          child: LayoutBuilder(
            builder: (context, c) {
              const gap = 2.0;
              final w = c.maxWidth.isFinite ? c.maxWidth : 0.0;
              final usable = math.max(0.0, w - gap * (slices.length - 1));
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var i = 0; i < slices.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: gap),
                    SizedBox(
                      width: usable * slices[i].value / total,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.at(i),
                          borderRadius: BorderRadius.horizontal(
                            left: Radius.circular(i == 0 ? 8 : 3),
                            right: Radius.circular(
                              i == slices.length - 1 ? 8 : 3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        SliceLegend(slices: slices, colors: colors),
      ],
    ),
  );
}

// ------------------------------------------------------------ RadarChart

/// Builds `RadarChart(labels, series)`. With fewer than three labels a
/// radar has no area, so the data is drawn as grouped bars.
Widget buildRadarChart(BuildContext context, OpenUiProps p) {
  final data = readChart2D(p);
  if (!data.hasData) return chartPlaceholder(context, p, 220);
  if (data.length < 3) return buildBarChart(context, p);
  final colors = OpenUiChartColors.of(context);
  final n = data.length;
  final series = [
    for (final s in data.series)
      if (s.values.any((v) => v != null)) s,
  ];
  var hi = 0.0;
  for (final v in data.allValues) {
    hi = math.max(hi, v);
  }
  if (hi <= 0) return chartPlaceholder(context, p, 220);
  final dark = colors.palette.isDark;
  final sets = <RadarDataSet>[
    for (var s = 0; s < series.length; s++)
      RadarDataSet(
        dataEntries: <RadarEntry>[
          for (var i = 0; i < n; i++)
            RadarEntry(value: math.max(0, series[s].at(i) ?? 0)),
        ],
        fillColor: colors
            .at(s)
            .withValues(alpha: series.length > 1 ? 0.14 : (dark ? 0.26 : 0.2)),
        borderColor: colors.at(s),
        borderWidth: 2,
        entryRadius: n <= 12 ? 2.5 : 0,
      ),
    // A clear ring at 0 and one at the round top of the scale, so the
    // centre is 0 and the grid steps are round.
    RadarDataSet(
      dataEntries: <RadarEntry>[
        for (var i = 0; i < n; i++) RadarEntry(value: 0),
      ],
      fillColor: Colors.transparent,
      borderColor: Colors.transparent,
      borderWidth: 0,
      entryRadius: 0,
    ),
    RadarDataSet(
      dataEntries: <RadarEntry>[
        for (var i = 0; i < n; i++) RadarEntry(value: AxisScale.fit(0, hi).max),
      ],
      fillColor: Colors.transparent,
      borderColor: Colors.transparent,
      borderWidth: 0,
      entryRadius: 0,
    ),
  ];
  final grid = BorderSide(color: colors.palette.grid, width: 1);
  final names = [
    for (var s = 0; s < series.length; s++)
      series[s].name.trim().isEmpty
          ? openUiStrings(context).openUiSeriesN('${s + 1}')
          : series[s].name,
  ];
  return ChartFrame(
    legend: series.length > 1
        ? ChartLegend(names: names, colors: colors)
        : null,
    child: LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 320.0;
        final h = chartHeight(p, fallback: math.min(w * 0.85, 300));
        return SizedBox(
          height: h,
          child: RadarChart(
            RadarChartData(
              dataSets: sets,
              radarShape: RadarShape.polygon,
              radarBackgroundColor: Colors.transparent,
              borderData: FlBorderData(show: false),
              radarBorderData: BorderSide(
                color: colors.palette.baseline,
                width: 1,
              ),
              gridBorderData: grid,
              tickBorderData: grid,
              tickCount: 4,
              // The tick values sit on the data; the grid alone shows
              // the steps.
              ticksTextStyle: const TextStyle(
                fontSize: 1,
                color: Colors.transparent,
              ),
              titleTextStyle: chartAxisStyle(context)
                  .copyWith(fontSize: 10.5, fontWeight: FontWeight.w600),
              titlePositionPercentageOffset: 0.14,
              getTitle: (index, angle) => RadarChartTitle(
                text: index < n ? _short(data.labels[index]) : '',
              ),
              radarTouchData: RadarTouchData(enabled: false),
            ),
            duration: const Duration(milliseconds: 180),
          ),
        );
      },
    ),
  );
}

String _short(String s) => s.length <= 16 ? s : '${s.substring(0, 15)}…';
