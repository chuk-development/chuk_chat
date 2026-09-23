// lib/widgets/charts/chuk_chart.dart
//
// The card a [ChartSpec] is drawn in: the title, the plot, the legend, the
// source line — the same card family as [ChukTable], so a chart and a table in
// the same answer look like they came from the same app.
//
// One call gets a caller from the JSON an agent emitted to a widget:
//
//     chukChartFromJson(decodedJson)
//
// Nothing here throws on bad input. A spec that could not be read draws a
// quiet fallback: the note, and the values as a small table when there are
// any. A chart is never the reason a message fails to render.

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/charts/chart_painter.dart';
import 'package:chuk_chat/widgets/charts/chart_palette.dart';
import 'package:chuk_chat/widgets/charts/chart_spec.dart';

export 'package:chuk_chat/widgets/charts/chart_spec.dart';

/// The card radius. The same 12 [ChukTable] uses, so a chart next to a table
/// is the same object.
const double kChukChartRadius = 12;

/// The entrance. Long enough to be seen, short enough not to be waited for —
/// and it happens ONCE, on the first paint, not on every rebuild.
const Duration kChukChartEntrance = Duration(milliseconds: 620);

/// Builds a chart from whatever the agent emitted: a decoded map, a JSON
/// string, a list of points. Never throws, always returns a widget.
Widget chukChartFromJson(
  Object? json, {
  Key? key,
  Color? accentColor,
  String? fontFamily,
  bool animate = true,
}) => ChukChart(
  key: key,
  spec: ChartSpec.parse(json),
  accentColor: accentColor,
  fontFamily: fontFamily,
  animate: animate,
);

/// Draws a [ChartSpec]: a card with a title, a plot and a source line.
class ChukChart extends StatefulWidget {
  const ChukChart({
    super.key,
    required this.spec,
    this.accentColor,
    this.fontFamily,
    this.animate = true,
  });

  final ChartSpec spec;

  /// Overrides the scheme's primary — an open thread passes the coworker's
  /// colour so a chart carries the same identity the bubbles do.
  final Color? accentColor;

  final String? fontFamily;

  /// False draws the finished chart at once. Tests and goldens use it.
  final bool animate;

  @override
  State<ChukChart> createState() => _ChukChartState();
}

class _ChukChartState extends State<ChukChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kChukChartEntrance,
  );
  late final Animation<double> _entrance = CurvedAnimation(
    parent: _controller,
    curve: kExpressiveDecelerate,
  );

  @override
  void initState() {
    super.initState();
    // Once. The controller lives with the State, so a rebuild — a theme
    // change, a scroll, a new sibling message — does not replay it.
    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ChartSpec spec = widget.spec;
    final ChartPalette palette = ChartPalette.of(
      context,
      accent: widget.accentColor,
    );

    if (spec.unusable) {
      return ChukChartFallback(
        spec: spec,
        palette: palette,
        fontFamily: widget.fontFamily,
      );
    }

    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final List<Widget> notes = _notes(spec, palette);
    // The painter draws its own text, so it has to be told what the app's font
    // is; a TextStyle built inside a CustomPainter inherits nothing.
    final String? family = _family(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kChukChartRadius),
        border: Border.all(color: palette.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Heading(
            spec: spec,
            palette: palette,
            fontFamily: widget.fontFamily,
          ),
          if (_legendEntries(spec, palette).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: _legendEntries(spec, palette),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : 320;
                final ChartGeometry geometry = ChukChartPainter.measure(
                  spec,
                  width: width,
                  textScaler: scaler,
                  fontFamily: family,
                );
                return Semantics(
                  label: _semanticLabel(spec),
                  child: SizedBox(
                    width: width,
                    height: geometry.totalHeight,
                    child: AnimatedBuilder(
                      animation: _entrance,
                      builder: (BuildContext context, Widget? _) => CustomPaint(
                        size: Size(width, geometry.totalHeight),
                        isComplex: true,
                        painter: ChukChartPainter(
                          spec: spec,
                          palette: palette,
                          geometry: geometry,
                          textScaler: scaler,
                          progress: _entrance.value,
                          fontFamily: family,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          ...notes,
          ..._footer(spec, palette),
        ],
      ),
    );
  }

  /// The font the card draws in: what the caller asked for, else the app's.
  String? _family(BuildContext context) =>
      widget.fontFamily ??
      DefaultTextStyle.of(context).style.fontFamily ??
      Theme.of(context).textTheme.bodyMedium?.fontFamily;

  List<Widget> _legendEntries(ChartSpec spec, ChartPalette palette) {
    if (spec.series.length < 2) return const <Widget>[];
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < spec.series.length; i++) {
      final ChartSeries s = spec.series[i];
      final String? name = s.name;
      if (name == null) continue;
      Color c = s.color ?? palette.seriesColor(i);
      if (s.color == null && spec.kind == ChartKind.line) {
        c = switch (s.resolvedDirection) {
          ChartDirection.up => palette.up,
          ChartDirection.down => palette.down,
          _ => palette.seriesColor(i),
        };
      }
      out.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: palette.legible(c),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              name,
              style: TextStyle(
                color: palette.muted,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                fontFamily: widget.fontFamily,
              ),
            ),
          ],
        ),
      );
    }
    return out;
  }

  List<Widget> _notes(ChartSpec spec, ChartPalette palette) {
    final List<String> lines = <String>[];
    for (final ChartSeries s in spec.series) {
      for (final ChartPoint p in s.points) {
        final String? note = p.note;
        if (note != null) lines.add('${p.label}: $note');
        if (lines.length == 3) break;
      }
      if (lines.length == 3) break;
    }
    if (lines.isEmpty) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String l in lines)
              Text(
                l,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 11.5,
                  height: 1.35,
                  fontFamily: widget.fontFamily,
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _footer(ChartSpec spec, ChartPalette palette) {
    final String line = chartSourceLine(spec);
    if (line.isEmpty) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          line,
          style: TextStyle(
            color: palette.faint,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
            fontFamily: widget.fontFamily,
          ),
        ),
      ),
    ];
  }
}

/// "Source · 2026-09-12 20:15", or an empty string when neither is known.
String chartSourceLine(ChartSpec spec) {
  final List<String> parts = <String>[];
  final String? source = spec.source;
  if (source != null) parts.add(source);
  final DateTime? at = spec.retrievedAt;
  if (at != null) parts.add(_stamp(at));
  return parts.join('  ·  ');
}

String _stamp(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final String date = '${d.year}-${two(d.month)}-${two(d.day)}';
  if (d.hour == 0 && d.minute == 0) return date;
  return '$date ${two(d.hour)}:${two(d.minute)}';
}

/// A one-sentence description for a screen reader.
String _semanticLabel(ChartSpec spec) {
  final StringBuffer b = StringBuffer();
  final String? title = spec.title;
  if (title != null) b.write('$title. ');
  final ChartSeries first = spec.series.first;
  final int shown = first.points.length > 12 ? 12 : first.points.length;
  for (int i = 0; i < shown; i++) {
    final ChartPoint p = first.points[i];
    b.write('${p.label} ${spec.format(p.value)}. ');
  }
  if (first.points.length > shown) {
    b.write('and ${first.points.length - shown} more. ');
  }
  return b.toString().trim();
}

/// The heading of a chart card: title, then subtitle.
class _Heading extends StatelessWidget {
  const _Heading({
    required this.spec,
    required this.palette,
    this.fontFamily,
  });

  final ChartSpec spec;
  final ChartPalette palette;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final String? title = spec.title;
    final String? subtitle = spec.subtitle;
    if (title == null && subtitle == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (title != null)
          Text(
            title,
            style: TextStyle(
              color: palette.text,
              fontSize: 14.5,
              height: 1.25,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
              fontFamily: fontFamily,
            ),
          ),
        if (subtitle != null)
          Padding(
            padding: EdgeInsets.only(top: title == null ? 0 : 2),
            child: Text(
              subtitle,
              style: TextStyle(
                color: palette.muted,
                fontSize: 11.5,
                height: 1.3,
                fontWeight: FontWeight.w500,
                fontFamily: fontFamily,
              ),
            ),
          ),
      ],
    );
  }
}

/// What a chart that could not be drawn shows instead.
///
/// Quiet, on-brand, and still useful: the title if there was one, one line
/// saying what was wrong, and the numbers as a small two-column list when any
/// survived the parse. Never red, never an exception, never a stack trace.
class ChukChartFallback extends StatelessWidget {
  const ChukChartFallback({
    super.key,
    required this.spec,
    required this.palette,
    this.fontFamily,
  });

  final ChartSpec spec;
  final ChartPalette palette;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final List<ChartPoint> points = <ChartPoint>[
      for (final ChartSeries s in spec.series) ...s.points,
    ];
    final String problem = spec.problems.isEmpty
        ? 'This chart could not be drawn.'
        : _sentence(
            spec.problems.length == 1
                ? spec.problems.first
                : '${spec.problems.first} '
                      '(and ${spec.problems.length - 1} more)',
          );
    final String? raw = spec.rawFallbackText;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kChukChartRadius),
        border: Border.all(color: palette.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (spec.title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                spec.title!,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 14.5,
                  height: 1.25,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  fontFamily: fontFamily,
                ),
              ),
            ),
          Text(
            problem,
            style: TextStyle(
              color: palette.muted,
              fontSize: 12,
              height: 1.35,
              fontWeight: FontWeight.w600,
              fontFamily: fontFamily,
            ),
          ),
          if (points.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final ChartPoint p in points.take(12))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              p.label,
                              style: TextStyle(
                                color: palette.text,
                                fontSize: 12.5,
                                height: 1.3,
                                fontFamily: fontFamily,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            spec.format(p.value),
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 12.5,
                              height: 1.3,
                              fontWeight: FontWeight.w800,
                              fontFamily: fontFamily,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          else if (raw != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: palette.text.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  raw.length > 400 ? '${raw.substring(0, 400)}…' : raw,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 11.5,
                    height: 1.35,
                    fontFamily: fontFamily,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _sentence(String problem) {
    final String p = problem.trim();
    if (p.isEmpty) return 'This chart could not be drawn.';
    final String capitalised = p[0].toUpperCase() + p.substring(1);
    return capitalised.endsWith('.') ? capitalised : '$capitalised.';
  }
}
