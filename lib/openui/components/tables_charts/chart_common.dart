// Shared parts of the B2 charts: data reading, colours, number text,
// axis scale, legend and the card frame.
//
// Rules: every reader accepts bad, empty, partial (streaming) and
// mismatched data and never throws. A value that is not a number is a
// gap (null), so the positions still line up with the labels.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:openui/openui.dart';

import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/widgets/charts/chart_palette.dart';

// ---------------------------------------------------------------- data

/// One named series of a 2D chart. A `null` value is a gap.
@immutable
class ChartSeries {
  /// Creates a series.
  const ChartSeries(this.name, this.values);

  /// The series name (the `category` of upstream `Series`).
  final String name;

  /// The values, position for position with the chart labels.
  final List<double?> values;

  /// The value at [i], or `null` when it is missing.
  double? at(int i) => i >= 0 && i < values.length ? values[i] : null;
}

/// The data of a 2D chart: x labels and the series.
@immutable
class Chart2D {
  /// Creates the data.
  const Chart2D(this.labels, this.series);

  /// The category labels, one per x position.
  final List<String> labels;

  /// The series. Each one has at most [labels.length] values.
  final List<ChartSeries> series;

  /// The number of x positions.
  int get length => labels.length;

  /// Whether there is at least one number to draw.
  bool get hasData =>
      labels.isNotEmpty && series.any((s) => s.values.any((v) => v != null));

  /// Every finite value.
  Iterable<double> get allValues sync* {
    for (final s in series) {
      for (final v in s.values) {
        if (v != null) yield v;
      }
    }
  }
}

/// A label and a value (a pie slice, a radial bar, a stacked part).
@immutable
class ChartSlice {
  /// Creates a slice.
  const ChartSlice(this.label, this.value);

  /// The category.
  final String label;

  /// The value.
  final double value;
}

/// A number from a model value, or `null`. Numeric strings parse
/// ("1,234" and "12%" too). Never throws.
double? chartNumber(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    var s = v.trim().replaceAll(',', '').replaceAll('%', '');
    if (s.startsWith(r'$') || s.startsWith('€')) s = s.substring(1);
    final n = double.tryParse(s);
    return n != null && n.isFinite ? n : null;
  }
  return null;
}

/// The text of a label value. Numbers lose a `.0`.
String chartLabel(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num) return formatChartValue(v.toDouble());
  if (v is bool) return '$v';
  return '';
}

/// Reads `labels` and `series` of a 2D chart.
///
/// Two upstream forms are read:
/// - `labels` are the x labels and `series` holds `Series` items.
/// - The table form: `labels` are column names, `series` is a list of
///   rows; column 0 is the x label and the other columns are series.
///
/// The number of x positions is the label count; while the labels
/// still stream, it is the longest series. Extra values are dropped.
Chart2D readChart2D(OpenUiProps p) {
  final rawLabels = p.list('labels');
  final rawSeries = p.list('series');

  // The table form: rows of [label, v1, v2, ...].
  if (rawSeries.isNotEmpty && rawSeries.first is List) {
    final names = [for (final l in rawLabels.skip(1)) chartLabel(l)];
    final rows = [
      for (final r in rawSeries)
        if (r is List) r,
    ];
    final labels = [for (final r in rows) chartLabel(r.isEmpty ? '' : r[0])];
    var width = names.length;
    for (final r in rows) {
      width = math.max(width, r.length - 1);
    }
    final series = <ChartSeries>[
      for (var c = 0; c < width; c++)
        ChartSeries(c < names.length ? names[c] : 'Series ${c + 1}', [
          for (final r in rows) c + 1 < r.length ? chartNumber(r[c + 1]) : null,
        ]),
    ];
    return Chart2D(labels, series);
  }

  final series = <ChartSeries>[];
  for (final s in p.data('series', type: 'Series')) {
    final values = [for (final v in s.list('values')) chartNumber(v)];
    series.add(ChartSeries(s.string('category'), values));
  }
  var labels = [for (final l in rawLabels) chartLabel(l)];
  if (labels.isEmpty) {
    var longest = 0;
    for (final s in series) {
      longest = math.max(longest, s.values.length);
    }
    labels = List<String>.filled(longest, '');
  }
  final n = labels.length;
  return Chart2D(labels, [
    for (final s in series)
      ChartSeries(
        s.name,
        s.values.length > n ? s.values.sublist(0, n) : s.values,
      ),
  ]);
}

/// Reads `labels` and `values` of a 1D chart (pie, radial, single
/// stacked bar). Also reads the legacy upstream form: `Slice` items in
/// the `labels` slot. A slice without a finite value is skipped.
List<ChartSlice> readChart1D(OpenUiProps p) {
  final labels = p.list('labels');
  final values = p.list('values');
  final out = <ChartSlice>[];
  if (values.isNotEmpty) {
    for (var i = 0; i < labels.length; i++) {
      if (labels[i] is! String && labels[i] is! num) continue;
      final v = i < values.length ? chartNumber(values[i]) : null;
      if (v == null) continue;
      out.add(ChartSlice(chartLabel(labels[i]), v));
    }
    if (out.isNotEmpty) return out;
  }
  for (final s in p.data('labels', type: 'Slice')) {
    final v = chartNumber(s.raw('value'));
    if (v == null) continue;
    out.add(ChartSlice(s.string('category'), v));
  }
  // A bare list of Slice items in the values slot is read too.
  if (out.isEmpty) {
    for (final s in p.data('values', type: 'Slice')) {
      final v = chartNumber(s.raw('value'));
      if (v == null) continue;
      out.add(ChartSlice(s.string('category'), v));
    }
  }
  return out;
}

// --------------------------------------------------------------- numbers

final NumberFormat _grouped = NumberFormat('#,##0.##', 'en_US');

/// A value for a tooltip, a legend or a bar end: grouped thousands, at
/// most two decimals, no trailing zeros.
String formatChartValue(double v) {
  if (!v.isFinite) return '';
  if (v.abs() >= 1e15) return v.toStringAsExponential(2);
  return _grouped.format(v);
}

/// A compact axis value: 1500 is "1.5K", 2000000 is "2M".
String formatAxisValue(double value) {
  if (!value.isFinite) return '';
  if (value == 0) return '0';
  final abs = value.abs();
  String trim(String s) => s.contains('.')
      ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : s;
  if (abs >= 1e12) return '${trim((value / 1e12).toStringAsFixed(1))}T';
  if (abs >= 1e9) return '${trim((value / 1e9).toStringAsFixed(1))}B';
  if (abs >= 1e6) return '${trim((value / 1e6).toStringAsFixed(1))}M';
  if (abs >= 1e4) return '${trim((value / 1e3).toStringAsFixed(1))}K';
  if (value % 1 == 0) return value.toInt().toString();
  if (abs >= 100) return value.toStringAsFixed(0);
  if (abs >= 10) return trim(value.toStringAsFixed(1));
  return trim(value.toStringAsFixed(2));
}

/// A round step for about [targetTicks] axis ticks over [range].
double niceInterval(double range, {int targetTicks = 5}) {
  if (range <= 0 || !range.isFinite) return 1;
  final raw = range / targetTicks;
  final exponent = (math.log(raw) / math.ln10).floor();
  final pow10 = math.pow(10, exponent).toDouble();
  final mantissa = raw / pow10;
  final double nice;
  if (mantissa < 1.5) {
    nice = 1;
  } else if (mantissa < 3) {
    nice = 2;
  } else if (mantissa < 7) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * pow10;
}

/// The value axis of a chart: a round minimum, maximum and step.
@immutable
class AxisScale {
  const AxisScale._(this.min, this.max, this.interval);

  /// Fits [lo]..[hi]. With [fromZero], the axis includes 0.
  factory AxisScale.fit(double lo, double hi, {bool fromZero = true}) {
    if (!lo.isFinite || !hi.isFinite) return const AxisScale._(0, 1, 0.2);
    if (fromZero) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    if (hi == lo) {
      final pad = hi == 0 ? 1.0 : hi.abs() * 0.1;
      hi += pad;
      if (!fromZero || lo != 0) lo -= pad;
    }
    // A range that is not finite, or a step too small to move the
    // largest value, would make the tick loops run forever.
    if (!(hi - lo).isFinite) return const AxisScale._(0, 1, 0.2);
    final step = niceInterval(hi - lo);
    final edge = math.max(lo.abs(), hi.abs());
    if (edge + step == edge) return const AxisScale._(0, 1, 0.2);
    final min = (lo / step).floorToDouble() * step;
    var max = (hi / step).ceilToDouble() * step;
    if (max <= min) max = min + step;
    return AxisScale._(min, max, step);
  }

  /// The axis minimum.
  final double min;

  /// The axis maximum.
  final double max;

  /// The step between two ticks.
  final double interval;
}

// --------------------------------------------------------------- colours

/// The order the palette hues are used in: far apart first, so two
/// neighbouring series never get two blues.
const List<int> _hueOrder = <int>[0, 8, 6, 3, 10, 1, 7, 4, 9, 2, 5, 11, 12];

/// The user's accent, moved to a lightness that reads as a filled
/// mark on the card: a pastel accent is too faint on a light card, a
/// very dark one is too faint on a dark card.
Color _chartAccent(ChartPalette palette) {
  final hsl = HSLColor.fromColor(palette.accent);
  if (hsl.saturation < 0.08) return palette.legible(palette.accent);
  if (!palette.isDark && hsl.lightness > 0.56) {
    return hsl
        .withLightness(0.52)
        .withSaturation(math.max(hsl.saturation, 0.55))
        .toColor();
  }
  if (palette.isDark && hsl.lightness < 0.42) {
    return hsl.withLightness(0.6).toColor();
  }
  return palette.accent;
}

/// The series colours of one chart.
///
/// Series 0 is the user's accent (one accent for the whole app,
/// docs/DESIGN.md section 7). The next ones come from the app's chart
/// palette (`ChartPalette`, the coworker hues), far-apart hues first,
/// and never a hue too near the accent.
@immutable
class OpenUiChartColors {
  const OpenUiChartColors._(this.palette, this._colors);

  /// Reads the palette for the current theme.
  factory OpenUiChartColors.of(BuildContext context) {
    final palette = ChartPalette.of(context);
    final accent = _chartAccent(palette);
    final accentHsl = HSLColor.fromColor(accent);
    final near = <Color>[];
    final far = <Color>[];
    for (final i in _hueOrder) {
      if (i >= palette.series.length) continue;
      final c = palette.series[i];
      final hsl = HSLColor.fromColor(c);
      final d = (hsl.hue - accentHsl.hue).abs();
      final hueGap = math.min(d, 360 - d);
      final grey = hsl.saturation < 0.2 || accentHsl.saturation < 0.2;
      (hueGap < 28 && !grey ? near : far).add(c);
    }
    return OpenUiChartColors._(palette, <Color>[accent, ...far, ...near]);
  }

  /// The app chart palette (grid, text, up/down colours).
  final ChartPalette palette;

  final List<Color> _colors;

  /// The fill colour of series [i].
  Color at(int i) => _colors[i.abs() % _colors.length];

  /// A text colour in the hue of series [i], readable on the card.
  Color inkAt(int i) => palette.ink(at(i));
}

// ------------------------------------------------------------ text styles

/// Axis tick text: 10 px, the quiet colour (as the `<chart>` renderer).
TextStyle chartAxisStyle(BuildContext context) => TextStyle(
  fontSize: 10,
  height: 1.2,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
);

/// Legend and axis title text.
TextStyle chartCaptionStyle(BuildContext context) => TextStyle(
  fontSize: 11.5,
  height: 1.25,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
);

/// The tooltip fill: a raised neutral surface, no glow.
Color chartTooltipColor(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest;

/// The tooltip border.
BorderSide chartTooltipBorder(BuildContext context) =>
    BorderSide(color: OpenUiTheme.of(context).borderColor);

/// The first tooltip line (the x label).
TextStyle chartTooltipTitleStyle(BuildContext context) => TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
);

/// A tooltip value line in the series colour.
TextStyle chartTooltipValueStyle(Color ink) => TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w700,
  color: ink,
  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
);

// ---------------------------------------------------------------- widgets

/// The chart height: the `height` prop clamped, else [fallback].
double chartHeight(OpenUiProps p, {double fallback = 220}) {
  final h = p.numberOrNull('height');
  if (h == null || h <= 0) return fallback;
  return h.clamp(120, 640).toDouble();
}

/// Whether the statement of [p] still streams.
bool chartIsStreaming(BuildContext context, OpenUiProps p) {
  final r = RendererScope.maybeFind(context);
  if (r == null || !r.isStreaming) return false;
  return p.statementId.isEmpty || r.incomplete.contains(p.statementId);
}

/// The card a chart is drawn on: the inner block surface of the OpenUI
/// family, the optional axis titles, the plot and the legend.
class ChartFrame extends StatelessWidget {
  /// Creates the frame.
  const ChartFrame({
    required this.child,
    this.topLabel,
    this.bottomLabel,
    this.legend,
    super.key,
  });

  /// The plot.
  final Widget child;

  /// A caption above the plot (the y axis title).
  final String? topLabel;

  /// A caption under the plot (the x axis title).
  final String? bottomLabel;

  /// The legend under everything, or `null`.
  final Widget? legend;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final caption = chartCaptionStyle(context);
    final top = topLabel?.trim() ?? '';
    final bottom = bottomLabel?.trim() ?? '';
    return Container(
      decoration: t.cardDecoration(),
      padding: const EdgeInsets.fromLTRB(12, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (top.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                top,
                style: caption.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          child,
          if (bottom.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                bottom,
                textAlign: TextAlign.center,
                style: caption.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (legend != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: legend),
        ],
      ),
    );
  }
}

/// A small square swatch for a legend entry.
class ChartSwatch extends StatelessWidget {
  /// Creates a swatch of [color].
  const ChartSwatch(this.color, {this.size = 10, super.key});

  /// The fill.
  final Color color;

  /// The side length.
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
    ),
  );
}

/// The legend of a multi-series chart: one swatch and name per series,
/// wrapped.
class ChartLegend extends StatelessWidget {
  /// Creates the legend for [names] in [colors].
  const ChartLegend({required this.names, required this.colors, super.key});

  /// The series names.
  final List<String> names;

  /// The colours.
  final OpenUiChartColors colors;

  @override
  Widget build(BuildContext context) {
    final style = chartCaptionStyle(context);
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: <Widget>[
        for (var i = 0; i < names.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ChartSwatch(colors.at(i)),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  names[i].isEmpty
                      ? openUiStrings(context).openUiSeriesN('${i + 1}')
                      : names[i],
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// The legend of a 1D chart: one row per slice with its value and its
/// share of the total, the numbers right-aligned with tabular figures.
class SliceLegend extends StatelessWidget {
  /// Creates the legend.
  const SliceLegend({
    required this.slices,
    required this.colors,
    this.showShare = true,
    super.key,
  });

  /// The slices.
  final List<ChartSlice> slices;

  /// The colours.
  final OpenUiChartColors colors;

  /// Whether to print the share of the total.
  final bool showShare;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final total = slices.fold<double>(0, (a, s) => a + math.max(0, s.value));
    final label = TextStyle(fontSize: 12.5, height: 1.3, color: t.textColor);
    final number = label.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final share = chartCaptionStyle(
      context,
    ).copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < slices.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                ChartSwatch(colors.at(i)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    slices[i].label.isEmpty
                        ? openUiStrings(context).openUiItemN('${i + 1}')
                        : slices[i].label,
                    style: label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(formatChartValue(slices[i].value), style: number),
                if (showShare && total > 0) ...<Widget>[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(math.max(0, slices[i].value) / total * 100).toStringAsFixed(slices[i].value / total * 100 < 10 ? 1 : 0)}%',
                      style: share,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// What a chart draws while its data still streams and nothing is
/// valid yet: a quiet box of the chart height, so the answer does not
/// jump when the data lands. Outside a stream, nothing.
Widget chartPlaceholder(BuildContext context, OpenUiProps p, double height) {
  if (!chartIsStreaming(context, p)) return const SizedBox.shrink();
  final t = OpenUiTheme.of(context);
  return Container(
    height: height + 26,
    decoration: t.cardDecoration(variant: 'sunk'),
  );
}
