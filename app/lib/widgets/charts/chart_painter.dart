// lib/widgets/charts/chart_painter.dart
//
// The plot itself: axis, gridlines, bars, lines, the value at each bar, the
// category under it, and the reference rule across the middle.
//
// It is one painter rather than a tree of widgets for one reason: every label
// is MEASURED before it is placed. A painter can ask a [TextPainter] how wide
// "Tierschutzpartei" is at the reader's text scale and then decide to lay it
// flat, tilt it, or thin the row out. A Row of Texts can only overflow.
//
// Rules the painter keeps, at any width and any text scale:
//   * no two category labels overlap,
//   * no glyph is painted outside the plot box,
//   * the value at a bar is never painted over another bar,
//   * nothing is clipped without an ellipsis to say so.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/charts/chart_palette.dart';
import 'package:chuk_chat/widgets/charts/chart_spec.dart';

/// How the category labels under the plot are laid out, once measured.
enum ChartLabelLayout {
  /// One flat line under each bar. The wide case, and the phone case when the
  /// labels are short.
  flat,

  /// Two flat lines, the label wrapped on a space.
  wrapped,

  /// Tilted 45°, reading up to the right. What a newspaper does when ten
  /// parties have to share a phone screen.
  tilted,
}

/// Everything the painter worked out from the spec and the box it was given.
/// Public so the widget can size itself and so the tests can assert on the
/// decisions rather than only on pixels.
class ChartGeometry {
  ChartGeometry._({
    required this.axisWidth,
    required this.valueBand,
    required this.plotHeight,
    required this.labelBand,
    required this.min,
    required this.max,
    required this.step,
    required this.labelLayout,
    required this.labelStride,
    required this.categoryCount,
  });

  /// Width of the tick-label column on the left.
  final double axisWidth;

  /// Height reserved above the plot for the value printed at a bar.
  final double valueBand;

  /// Height of the plot box itself.
  final double plotHeight;

  /// Height reserved under the plot for the category labels.
  final double labelBand;

  final double min;
  final double max;
  final double step;

  final ChartLabelLayout labelLayout;

  /// Draw every n-th category label. 1 means all of them.
  final int labelStride;

  final int categoryCount;

  /// The height the whole plot widget needs.
  double get totalHeight => valueBand + plotHeight + labelBand;

  /// The width one category owns.
  double slotWidth(double boxWidth) {
    final double plotWidth = math.max(1, boxWidth - axisWidth);
    return categoryCount == 0 ? plotWidth : plotWidth / categoryCount;
  }

  @override
  bool operator ==(Object other) =>
      other is ChartGeometry &&
      other.axisWidth == axisWidth &&
      other.valueBand == valueBand &&
      other.plotHeight == plotHeight &&
      other.labelBand == labelBand &&
      other.min == min &&
      other.max == max &&
      other.step == step &&
      other.labelLayout == labelLayout &&
      other.labelStride == labelStride &&
      other.categoryCount == categoryCount;

  @override
  int get hashCode => Object.hash(
    axisWidth,
    valueBand,
    plotHeight,
    labelBand,
    min,
    max,
    step,
    labelLayout,
    labelStride,
    categoryCount,
  );
}

/// What a measured box belongs to. The reference label dodges all of them;
/// naming them lets a test say WHAT it would have covered.
enum ChartBoxKind {
  /// A bar, a column or a stack segment.
  bar,

  /// The number printed at a bar or at the end of a line.
  value,

  /// A category label under the plot.
  category,

  /// A tick label in the axis column.
  tick,
}

/// One box the painter put down, kept so the reference label can step around
/// it instead of being painted on top of it.
@immutable
class ChartBox {
  const ChartBox(this.kind, this.rect);

  final ChartBoxKind kind;
  final Rect rect;

  @override
  String toString() => '$kind $rect';
}

/// The smallest font a label is allowed to shrink to before it is ellipsised
/// instead. Below this nothing is readable, so shrinking further is a lie.
const double _kMinLabelFontSize = 8.5;

/// Base sizes, before the reader's text scale.
const double _kAxisFontSize = 10.5;
const double _kLabelFontSize = 11.5;
const double _kValueFontSize = 11.5;

class ChukChartPainter extends CustomPainter {
  ChukChartPainter({
    required this.spec,
    required this.palette,
    required this.geometry,
    required this.textScaler,
    required this.progress,
    this.fontFamily,
  });

  final ChartSpec spec;
  final ChartPalette palette;
  final ChartGeometry geometry;
  final TextScaler textScaler;

  /// 0 → 1 entrance. Bars grow from the baseline, lines draw left to right.
  final double progress;

  final String? fontFamily;

  /// Where the reference line's label goes, decided before anything is drawn.
  _RefLabel? _refLabel;

  /// The boxes the plot occupies: bars, the numbers at them, the category
  /// labels and the axis ticks. Measured in a dry run before the real paint,
  /// and only when there is a reference label that has to dodge them.
  List<ChartBox> _boxes = const <ChartBox>[];

  /// Non-null while the dry run is on; every paint step drops its box in.
  List<ChartBox>? _collect;

  /// The plot box [_boxes] was measured against, so a resize throws it away.
  Rect? _measuredFor;

  /// 1 during the dry run, so the reference label is placed against the
  /// FINISHED plot and does not walk across the chart while it grows in.
  double get _t => _collect == null ? progress : 1.0;

  /// The box the reference label took, for the tests. Null when the chart has
  /// no reference label, or the label sits outside the axis.
  Rect? get debugReferenceLabelBox => _refLabel?.box;

  /// False when the label had to give up its plate and sit on the rule — the
  /// last resort, when nothing anywhere was free.
  bool get debugReferenceLabelPlated => _refLabel?.plate ?? false;

  /// What the label says. Shortened to the bare number on a plot too narrow
  /// to hold the words anywhere free.
  String? get debugReferenceLabelText => _refLabel?.text;

  /// Everything the reference label had to dodge in the last paint.
  List<ChartBox> get debugBoxes => List<ChartBox>.unmodifiable(_boxes);

  // ---------------------------------------------------------------------
  // Measurement
  // ---------------------------------------------------------------------

  /// Works out the plot's bands for [width]. Call before laying the widget
  /// out; the painter is then given the same object.
  static ChartGeometry measure(
    ChartSpec spec, {
    required double width,
    required TextScaler textScaler,
    String? fontFamily,
  }) {
    final List<String> categories = spec.categories;
    final int n = categories.length;

    final _Range range = _rangeFor(spec);

    // --- the axis column ---------------------------------------------------
    final int tickDecimals = _decimalsFor(range.step);
    double axisWidth = 0;
    for (double v = range.min; v <= range.max + range.step * 0.001;
        v += range.step) {
      final TextPainter tp = _paint(
        _tickText(v, spec, tickDecimals),
        _axisStyle(),
        textScaler,
        fontFamily,
      );
      axisWidth = math.max(axisWidth, tp.width);
    }
    axisWidth = math.min(axisWidth + 8, width * 0.32);

    final double plotWidth = math.max(24, width - axisWidth);
    final double slot = n == 0 ? plotWidth : plotWidth / n;

    // --- the value band ----------------------------------------------------
    double valueBand = 0;
    if (spec.drawsValueLabels) {
      final TextPainter tp = _paint('0', _valueStyle(), textScaler, fontFamily);
      valueBand = tp.height + 5;
    } else {
      valueBand = 6;
    }

    // --- the category band -------------------------------------------------
    final TextStyle labelStyle = _labelStyle();
    double widest = 0;
    double lineHeight = 0;
    for (final String c in categories) {
      final TextPainter tp = _paint(c, labelStyle, textScaler, fontFamily);
      widest = math.max(widest, tp.width);
      lineHeight = math.max(lineHeight, tp.height);
    }
    if (lineHeight == 0) {
      lineHeight = _paint('X', labelStyle, textScaler, fontFamily).height;
    }

    ChartLabelLayout layout = ChartLabelLayout.flat;
    int stride = 1;
    double labelBand = lineHeight + 6;

    if (n > 0 && widest > slot - 3) {
      // Flat does not fit. Two lines rescue "Freie Wähler"; a single long word
      // ("Tierschutz") only gets shorter by tilting.
      final bool wrappable = categories.any((String c) => c.contains(' '));
      double widestWrapped = 0;
      if (wrappable) {
        for (final String c in categories) {
          final TextPainter tp = _paint(
            c,
            labelStyle,
            textScaler,
            fontFamily,
            maxWidth: slot - 3,
            maxLines: 2,
          );
          widestWrapped = math.max(widestWrapped, tp.maxIntrinsicWidth);
        }
      }
      if (wrappable && widestWrapped <= (slot - 3) * 2.0) {
        layout = ChartLabelLayout.wrapped;
        labelBand = lineHeight * 2 + 6;
      } else {
        layout = ChartLabelLayout.tilted;
        // A 45° label needs `lineHeight / sin45` of horizontal room before it
        // touches its neighbour. Below that, only every n-th is drawn.
        final double need = lineHeight * math.sqrt2 * 0.92;
        stride = slot >= need ? 1 : (need / math.max(slot, 1)).ceil();
        final double cap = lineHeight * 5.2;
        final double tiltedWidth = math.min(widest, cap);
        labelBand =
            tiltedWidth * math.sin(math.pi / 4) +
            lineHeight * math.cos(math.pi / 4) +
            6;
      }
    }

    // --- the plot box ------------------------------------------------------
    final double asked = spec.height ?? width * 0.50;
    final double plotHeight = asked.clamp(120.0, 280.0);

    return ChartGeometry._(
      axisWidth: axisWidth,
      valueBand: valueBand,
      plotHeight: plotHeight,
      labelBand: labelBand,
      min: range.min,
      max: range.max,
      step: range.step,
      labelLayout: layout,
      labelStride: stride,
      categoryCount: n,
    );
  }

  // ---------------------------------------------------------------------
  // Painting
  // ---------------------------------------------------------------------

  @override
  void paint(Canvas canvas, Size size) {
    final Rect plot = Rect.fromLTWH(
      geometry.axisWidth,
      geometry.valueBand,
      math.max(1, size.width - geometry.axisWidth),
      geometry.plotHeight,
    );
    if (!_hasReferenceLabel) {
      _boxes = const <ChartBox>[];
      _refLabel = null;
      _measuredFor = null;
    } else if (_measuredFor != plot) {
      _boxes = _measureBoxes(plot, size.width);
      _refLabel = _placeReferenceLabel(plot, _boxes);
      _measuredFor = plot;
    }
    _paintUnitCaption(canvas, plot);
    _paintGrid(canvas, plot, size.width);
    _paintSeries(canvas, plot);
    _paintReference(canvas, plot);
    _paintCategories(canvas, plot);
  }

  void _paintSeries(Canvas canvas, Rect plot) {
    if (spec.kind == ChartKind.line) {
      _paintLines(canvas, plot);
    } else if (spec.kind == ChartKind.stacked) {
      _paintStacked(canvas, plot);
    } else {
      _paintBars(canvas, plot);
    }
  }

  bool get _hasReferenceLabel {
    final ChartReferenceLine? ref = spec.referenceLine;
    return ref != null &&
        ref.label != null &&
        ref.label!.isNotEmpty &&
        ref.value >= geometry.min &&
        ref.value <= geometry.max;
  }

  /// Lays the plot out once into a throwaway canvas to learn where everything
  /// lands. The same code paints the picture and measures it, so the boxes
  /// the reference label dodges are the boxes the reader sees.
  List<ChartBox> _measureBoxes(Rect plot, double width) {
    final List<ChartBox> out = <ChartBox>[];
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas scratch = Canvas(recorder);
    _collect = out;
    try {
      _paintGrid(scratch, plot, width);
      _paintSeries(scratch, plot);
      _paintCategories(scratch, plot);
    } finally {
      _collect = null;
      recorder.endRecording().dispose();
    }
    return out;
  }

  /// The unit, once, at the head of the axis column — "%" over the numbers,
  /// the way a results table prints it.
  void _paintUnitCaption(Canvas canvas, Rect plot) {
    if (!spec.unitOverAxis) return;
    final TextPainter tp = _paint(
      spec.unit,
      _axisStyle().copyWith(color: palette.faint),
      textScaler,
      fontFamily,
      maxWidth: geometry.axisWidth,
      maxLines: 1,
      ellipsis: true,
    );
    tp.paint(
      canvas,
      Offset(
        math.max(0, geometry.axisWidth - 6 - tp.width),
        math.max(0, plot.top - tp.height - 2),
      ),
    );
  }

  double _y(Rect plot, double value) {
    final double span = geometry.max - geometry.min;
    if (span <= 0) return plot.bottom;
    final double t = (value - geometry.min) / span;
    return plot.bottom - t * plot.height;
  }

  void _paintGrid(Canvas canvas, Rect plot, double width) {
    final Paint grid = Paint()
      ..color = palette.grid
      ..strokeWidth = 1;
    final int decimals = _decimalsFor(geometry.step);
    for (
      double v = geometry.min;
      v <= geometry.max + geometry.step * 0.001;
      v += geometry.step
    ) {
      final double y = _y(plot, v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final TextPainter tp = _paint(
        _tickText(v, spec, decimals),
        _axisStyle().copyWith(color: palette.faint),
        textScaler,
        fontFamily,
      );
      final Offset at = Offset(
        geometry.axisWidth - 6 - tp.width,
        y - tp.height / 2,
      );
      _collect?.add(
        ChartBox(
          ChartBoxKind.tick,
          Rect.fromLTWH(at.dx, at.dy, tp.width, tp.height),
        ),
      );
      tp.paint(canvas, at);
    }
    // The zero line is the one the eye needs: darker than the grid.
    if (geometry.min < 0 && geometry.max > 0) {
      final double y = _y(plot, 0);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = palette.baseline
          ..strokeWidth = 1.4,
      );
    } else {
      canvas.drawLine(
        Offset(plot.left, plot.bottom),
        Offset(plot.right, plot.bottom),
        Paint()
          ..color = palette.baseline
          ..strokeWidth = 1.4,
      );
    }
  }

  void _paintBars(Canvas canvas, Rect plot) {
    final List<ChartSeries> series = spec.series;
    if (series.isEmpty) return;
    final int n = geometry.categoryCount;
    if (n == 0) return;
    final double slot = plot.width / n;
    final bool grouped = spec.kind == ChartKind.grouped && series.length > 1;
    final int lanes = grouped ? series.length : 1;
    final bool bySign = spec.kind == ChartKind.columnDelta;
    final double zeroY = _y(plot, geometry.min < 0 ? 0 : geometry.min);

    final double groupWidth = math.min(slot * 0.78, 68.0 * lanes);
    final double laneWidth = groupWidth / lanes;
    final double barWidth = math.max(2.0, laneWidth * (grouped ? 0.84 : 1.0));

    for (int i = 0; i < n; i++) {
      final double centre = plot.left + slot * (i + 0.5);
      for (int s = 0; s < lanes; s++) {
        final ChartSeries ser = series[grouped ? s : 0];
        if (i >= ser.points.length) continue;
        final ChartPoint p = ser.points[i];
        final Color fill = palette.barColor(
          asked: p.color ?? (grouped ? ser.color : null),
          index: grouped ? s : i,
          value: p.value,
          bySign: bySign,
        );
        final double laneCentre = grouped
            ? centre - groupWidth / 2 + laneWidth * (s + 0.5)
            : centre;
        final double target = _y(plot, p.value);
        final double top = math.min(zeroY, zeroY + (target - zeroY) * _t);
        final double bottom = math.max(zeroY, zeroY + (target - zeroY) * _t);
        final Rect bar = Rect.fromLTRB(
          laneCentre - barWidth / 2,
          top,
          laneCentre + barWidth / 2,
          bottom,
        );
        _collect?.add(ChartBox(ChartBoxKind.bar, bar));
        final double r = math.min(barWidth * 0.22, 7);
        final Radius radius = Radius.circular(r);
        final bool negative = p.value < 0;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            bar,
            topLeft: negative ? Radius.zero : radius,
            topRight: negative ? Radius.zero : radius,
            bottomLeft: negative ? radius : Radius.zero,
            bottomRight: negative ? radius : Radius.zero,
          ),
          Paint()..color = fill,
        );

        if (spec.drawsValueLabels && _t > 0.35) {
          _paintValue(
            canvas,
            text: spec.format(
              p.value,
              signed: bySign,
              withUnit: !spec.unitOverAxis,
            ),
            centre: laneCentre,
            slot: grouped ? laneWidth : slot,
            anchorY: negative ? bottom : top,
            above: !negative,
            color: fill,
            plot: plot,
            fade: ((_t - 0.35) / 0.35).clamp(0.0, 1.0),
            altAnchorY: zeroY,
          );
        }
      }
    }
  }

  void _paintStacked(Canvas canvas, Rect plot) {
    final int n = geometry.categoryCount;
    if (n == 0) return;
    final double slot = plot.width / n;
    final double barWidth = math.min(slot * 0.72, 64);
    final double zeroY = _y(plot, geometry.min < 0 ? 0 : geometry.min);

    for (int i = 0; i < n; i++) {
      final double centre = plot.left + slot * (i + 0.5);
      double running = 0;
      for (int s = 0; s < spec.series.length; s++) {
        final ChartSeries ser = spec.series[s];
        if (i >= ser.points.length) continue;
        final ChartPoint p = ser.points[i];
        final double from = _y(plot, running);
        final double to = _y(plot, running + p.value);
        running += p.value;
        final Color fill = palette.barColor(
          asked: p.color ?? ser.color,
          index: s,
          value: p.value,
          bySign: false,
        );
        final double topEnd = zeroY + (to - zeroY) * _t;
        final double bottomEnd = zeroY + (from - zeroY) * _t;
        final Rect segment = Rect.fromLTRB(
          centre - barWidth / 2,
          math.min(topEnd, bottomEnd),
          centre + barWidth / 2,
          math.max(topEnd, bottomEnd),
        );
        _collect?.add(ChartBox(ChartBoxKind.bar, segment));
        canvas.drawRect(segment, Paint()..color = fill);
      }
      if (spec.drawsValueLabels && _t > 0.35) {
        final double top = zeroY + (_y(plot, running) - zeroY) * _t;
        _paintValue(
          canvas,
          text: spec.format(running, withUnit: !spec.unitOverAxis),
          centre: centre,
          slot: slot,
          anchorY: top,
          above: true,
          color: palette.text,
          plot: plot,
          fade: ((_t - 0.35) / 0.35).clamp(0.0, 1.0),
          onText: true,
        );
      }
    }
  }

  void _paintLines(Canvas canvas, Rect plot) {
    final int n = geometry.categoryCount;
    if (n == 0) return;
    final double slot = n == 1 ? plot.width : plot.width / (n - 1);
    double x(int i) =>
        n == 1 ? plot.center.dx : plot.left + slot * i;

    for (int s = 0; s < spec.series.length; s++) {
      final ChartSeries ser = spec.series[s];
      if (ser.points.isEmpty) continue;
      final Color stroke = _lineColor(ser, s);

      final Path path = Path();
      for (int i = 0; i < ser.points.length; i++) {
        final Offset o = Offset(x(i), _y(plot, ser.points[i].value));
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }

      // The entrance draws the line on, left to right.
      final Path drawn = _trim(path, _t);

      // Only a single line gets a soft area under it; two tinted areas
      // overlapping turn the whole plot into a wash.
      if (spec.series.length == 1 && ser.points.length > 1) {
        final Path fill = Path.from(drawn)
          ..lineTo(_lastX(drawn, x(ser.points.length - 1)), plot.bottom)
          ..lineTo(x(0), plot.bottom)
          ..close();
        canvas.save();
        canvas.clipRect(plot);
        canvas.drawPath(
          fill,
          Paint()..color = stroke.withValues(alpha: 0.08),
        );
        canvas.restore();
      }

      canvas.drawPath(
        drawn,
        Paint()
          ..color = stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );

      // A dot per point, but only where a dot has room — a 60-point line is a
      // line, not a bead necklace.
      final bool dots = slot >= 14;
      final int drawnCount = (ser.points.length * _t).ceil();
      for (int i = 0; i < math.min(drawnCount, ser.points.length); i++) {
        final bool last = i == ser.points.length - 1;
        if (!dots && !last) continue;
        final Offset o = Offset(x(i), _y(plot, ser.points[i].value));
        canvas.drawCircle(o, last ? 4.0 : 2.6, Paint()..color = stroke);
        if (last) {
          canvas.drawCircle(
            o,
            4.0,
            Paint()
              ..color = palette.surface
              ..strokeWidth = 1.6
              ..style = PaintingStyle.stroke,
          );
        }
      }

      // The last value is the one the reader came for; it is always called out.
      if (_t > 0.7) {
        final ChartPoint lastPoint = ser.points.last;
        _paintValue(
          canvas,
          text: spec.format(lastPoint.value),
          centre: x(ser.points.length - 1),
          slot: math.max(slot * 2, 56),
          anchorY: _y(plot, lastPoint.value) - 6,
          above: true,
          color: stroke,
          plot: plot,
          fade: ((_t - 0.7) / 0.3).clamp(0.0, 1.0),
          chip: true,
        );
      }
    }
  }

  double _lastX(Path p, double fallback) {
    for (final ui.PathMetric m in p.computeMetrics()) {
      final ui.Tangent? t = m.getTangentForOffset(m.length);
      if (t != null) return t.position.dx;
    }
    return fallback;
  }

  Path _trim(Path path, double t) {
    if (t >= 1) return path;
    final Path out = Path();
    for (final ui.PathMetric m in path.computeMetrics()) {
      out.addPath(m.extractPath(0, m.length * t.clamp(0.0, 1.0)), Offset.zero);
    }
    return out;
  }

  Color _lineColor(ChartSeries ser, int index) {
    final Color? asked = ser.color;
    if (asked != null) return palette.legible(asked);
    return switch (ser.resolvedDirection) {
      ChartDirection.up => palette.up,
      ChartDirection.down => palette.down,
      _ => palette.seriesColor(index),
    };
  }

  /// The number printed at a bar or at the end of a line. Shrinks to fit its
  /// slot, and is nudged back inside the plot rather than painted over the
  /// edge.
  void _paintValue(
    Canvas canvas, {
    required String text,
    required double centre,
    required double slot,
    required double anchorY,
    required bool above,
    required Color color,
    required Rect plot,
    required double fade,
    double? altAnchorY,
    bool chip = false,
    bool onText = false,
  }) {
    final Color ink = onText ? palette.text : palette.ink(color);
    TextPainter tp = _paint(
      text,
      _valueStyle().copyWith(color: ink.withValues(alpha: fade)),
      textScaler,
      fontFamily,
    );
    final double room = slot - 2;
    if (tp.width > room && room > 8) {
      final double factor = math.max(room / tp.width, 0.62);
      final double size = math.max(
        _kMinLabelFontSize,
        _kValueFontSize * factor,
      );
      tp = _paint(
        text,
        _valueStyle().copyWith(
          fontSize: size,
          color: ink.withValues(alpha: fade),
        ),
        textScaler,
        fontFamily,
        maxWidth: room,
        maxLines: 1,
      );
    }

    double x = centre - tp.width / 2;
    // Keep it inside the plot: the last point of a line sits on the right edge.
    x = x.clamp(plot.left, math.max(plot.left, plot.right - tp.width));
    double y = above ? anchorY - tp.height - 3 : anchorY + 3;

    // Step over the reference label rather than under it. The label picks a
    // free spot first, so this is a net, not the usual path.
    final Rect? blocked = _refLabel?.box;
    if (blocked != null) {
      Rect box() => Rect.fromLTWH(x, y, tp.width, tp.height);
      for (int tries = 0; tries < 3 && box().overlaps(blocked); tries++) {
        y = blocked.top - tp.height - 3;
      }
    }

    // A bar that reaches the floor of the plot has no room under it for its
    // number. The number then crosses to the other side of the baseline — the
    // half of the plot a single-signed bar leaves empty — instead of falling
    // into the category labels or being written across a bar too narrow to
    // hold it. Only if that is impossible too does it sit inside the bar, in
    // the colour that reads on the fill.
    bool inside = false;
    if (y + tp.height > plot.bottom) {
      final double? alt = altAnchorY;
      if (alt != null && alt - tp.height - 3 >= plot.top) {
        y = alt - tp.height - 3;
      } else {
        y = plot.bottom - tp.height - 3;
        inside = true;
      }
    } else if (y < 0) {
      y = 2;
    }
    if (inside) {
      tp = _paint(
        text,
        tp.text!.style!.copyWith(
          color: palette.onFill(color).withValues(alpha: fade),
        ),
        textScaler,
        fontFamily,
        maxWidth: math.max(room, 8),
        maxLines: 1,
      );
      x = (centre - tp.width / 2).clamp(
        plot.left,
        math.max(plot.left, plot.right - tp.width),
      );
    }

    if (chip) {
      final Rect box = Rect.fromLTWH(
        x - 5,
        y - 2,
        tp.width + 10,
        tp.height + 4,
      );
      _collect?.add(ChartBox(ChartBoxKind.value, box));
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(6)),
        Paint()..color = color.withValues(alpha: 0.14 * fade),
      );
    } else {
      _collect?.add(
        ChartBox(
          ChartBoxKind.value,
          Rect.fromLTWH(x, y, tp.width, tp.height),
        ),
      );
    }
    tp.paint(canvas, Offset(x, y));
  }

  Color get _referenceColor {
    final Color? asked = spec.referenceLine?.color;
    return asked == null
        ? palette.text.withValues(alpha: 0.55)
        : palette.legible(asked);
  }

  /// Where the rule's label goes.
  ///
  /// The chip names the rule, so it stays with the rule: it sits in the strip
  /// just above it or just below it. WHICH strip, and which end of it, is
  /// decided by what is free — the bars and the numbers at them were measured
  /// first, and the chip takes the emptiest end of the emptier strip. When
  /// both strips are full across the plot it steps out into the axis gutter;
  /// then it shortens itself to the bare number and tries both again; only
  /// when even that has nowhere to go does it sit on the rule without its
  /// plate, which is the one case where it is allowed to touch anything.
  _RefLabel? _placeReferenceLabel(Rect plot, List<ChartBox> boxes) {
    final ChartReferenceLine? ref = spec.referenceLine;
    if (!_hasReferenceLabel || ref == null) return null;
    final double y = _y(plot, ref.value);

    final List<String> texts = <String>[ref.label!];
    final String short = _shortReferenceText(ref);
    if (short.isNotEmpty && short != texts.first) texts.add(short);

    for (final String text in texts) {
      final TextPainter tp = _referencePainter(text, plot);
      // An ellipsised label says nothing the number would not say better.
      if (tp.didExceedMaxLines && text != texts.last) continue;
      for (final bool gutter in <bool>[false, true]) {
        // Two passes: one that keeps its distance from the neighbours, one
        // that accepts standing right next to them.
        for (final double air in <double>[2, 0]) {
          final _RefLabel? placed = _fitReferenceLabel(
            plot,
            y,
            text,
            tp,
            boxes,
            gutter: gutter,
            air: air,
          );
          if (placed != null) return placed;
        }
      }
    }

    // Ten bars on a phone leave no free pixel beside the rule. The label then
    // takes the spot that hides the least: the axis gutter over a tick if it
    // can, where its plate keeps it readable, and otherwise the thinnest part
    // of the plot — there with no plate, because a plate over a bar hides
    // data the reader came for.
    return _leastBadReferenceLabel(plot, y, texts.last, boxes);
  }

  _RefLabel _leastBadReferenceLabel(
    Rect plot,
    double y,
    String text,
    List<ChartBox> boxes,
  ) {
    // One more try before anything is covered: the axis column is the label's
    // own territory, so it may cover a TICK there, and it may shrink to the
    // same floor every other label in this painter shrinks to. What it may
    // not do is cover a bar or a number.
    final List<ChartBox> dataBoxes = boxes
        .where((ChartBox b) => b.kind != ChartBoxKind.tick)
        .toList();
    final TextPainter full = _referencePainter(text, plot);
    double widest = 0;
    for (final Rect band in _referenceBands(plot, y, full.height + 2, 0)) {
      for (final _Span s in _freeSpans(band, dataBoxes, 0)) {
        widest = math.max(widest, s.width);
      }
    }
    // Glyph widths do not scale exactly with the font size, so close in on a
    // size that fits instead of trusting one division.
    double size = _kAxisFontSize;
    TextPainter fitted = full;
    for (int tries = 0; tries < 3 && fitted.width + 6 > widest; tries++) {
      if (fitted.width <= 0) break;
      size = size * (widest - 6.5) / fitted.width;
      if (size < _kMinLabelFontSize) break;
      fitted = _referencePainter(text, plot, fontSize: size);
    }
    if (size >= _kMinLabelFontSize && fitted.width + 6 <= widest) {
      final _RefLabel? placed = _fitReferenceLabel(
        plot,
        y,
        text,
        fitted,
        dataBoxes,
        gutter: true,
        air: 0,
      );
      if (placed != null) {
        return _RefLabel(
          text: text,
          painter: placed.painter,
          box: placed.box,
          plate: true,
          // Opaque: a tick read through a translucent plate is a smudge.
          plateAlpha: 1,
        );
      }
    }

    // Even that failed. Now something gets covered, so cover as little of it
    // as possible, and go bare: a plate over a bar hides data, a plain word
    // on a bar only shares it.
    final double w = full.width + 6;
    final double h = full.height + 2;
    final double right = math.max(plot.right, w + 1);
    final List<Rect> bands = _referenceBands(plot, y, h, 0);
    final bool toLeft = _emptierEndIsLeft(bands, boxes, 0);

    const int steps = 64;
    Rect best = bands.first.topLeft & Size(w, h);
    double bestCovered = double.infinity;
    double bestInk = double.infinity;
    for (final Rect band in bands) {
      final double span = math.max(0, right - w);
      for (int i = 0; i <= steps; i++) {
        final double x = toLeft
            ? span * i / steps
            : span * (steps - i) / steps;
        final Rect r = Rect.fromLTWH(x, band.top, w, h);
        double covered = 0;
        double ink = 0;
        for (final ChartBox b in boxes) {
          final Rect hit = b.rect.intersect(r);
          if (hit.isEmpty) continue;
          final double area = hit.width * hit.height;
          if (b.kind == ChartBoxKind.tick) {
            ink += area;
          } else {
            covered += area;
          }
        }
        if (covered < bestCovered ||
            (covered == bestCovered && ink < bestInk)) {
          bestCovered = covered;
          bestInk = ink;
          best = r;
        }
      }
    }
    return _RefLabel(text: text, painter: full, box: best, plate: false);
  }

  /// The label with the words stripped off: "5 %-Hürde" → "5 %". Used only
  /// when the words have nowhere free to sit.
  String _shortReferenceText(ChartReferenceLine ref) {
    final String label = ref.label ?? '';
    final RegExpMatch? m = RegExp(
      r'^[^0-9+\-]*([+\-−]?\d+(?:[.,]\d+)?\s*%?)',
    ).firstMatch(label);
    final String head = m == null ? '' : m.group(1)!.trim();
    return head.isEmpty ? spec.format(ref.value) : head;
  }

  /// The strips the label may sit in: above the rule, below it, and astride
  /// it. The astride strip comes last — it hides a piece of the rule.
  List<Rect> _referenceBands(Rect plot, double y, double h, double left) =>
      <Rect>[
        if (y - 2 - h >= plot.top)
          Rect.fromLTRB(left, y - 2 - h, plot.right, y - 2),
        if (y + 2 + h <= plot.bottom)
          Rect.fromLTRB(left, y + 2, plot.right, y + 2 + h),
        if (y - h / 2 >= plot.top && y + h / 2 <= plot.bottom)
          Rect.fromLTRB(left, y - h / 2, plot.right, y + h / 2),
        if (y - 2 - h < plot.top && y + 2 + h > plot.bottom && plot.height >= h)
          Rect.fromLTRB(
            left,
            (y - h / 2).clamp(plot.top, plot.bottom - h),
            plot.right,
            (y - h / 2).clamp(plot.top, plot.bottom - h) + h,
          ),
      ];

  TextPainter _referencePainter(String text, Rect plot, {double? fontSize}) =>
      _paint(
    text,
    _axisStyle().copyWith(
      color: _referenceColor,
      fontWeight: FontWeight.w700,
      fontSize: fontSize,
    ),
    textScaler,
    fontFamily,
    maxWidth: math.max(plot.width, 1),
    maxLines: 1,
    ellipsis: true,
  );

  /// Tries to seat [tp] in the strip above or below the rule, or astride it.
  /// [gutter] lets it reach left out of the plot into the axis column; [air]
  /// is the clearance it keeps from whatever it stands next to.
  _RefLabel? _fitReferenceLabel(
    Rect plot,
    double y,
    String text,
    TextPainter tp,
    List<ChartBox> boxes, {
    required bool gutter,
    required double air,
  }) {
    final double w = tp.width + 6;
    final double h = tp.height + 2;
    final double left = gutter ? 0 : plot.left;
    if (w > plot.right - left) return null;

    // Above the rule, below it, and — last of all — astride it: the plate
    // was invented for exactly that, and in the axis gutter astride the rule
    // is where a threshold label belongs anyway.
    final List<Rect> bands = _referenceBands(plot, y, h, left);
    if (bands.isEmpty) return null;
    final List<List<_Span>> free = <List<_Span>>[
      for (final Rect band in bands) _freeSpans(band, boxes, air),
    ];
    final bool toLeft = _emptierEndIsLeft(bands, boxes, left);

    // The strip with more room wins; a tie keeps the label above the rule,
    // where a threshold label is normally read. The strip astride the rule is
    // always tried last.
    final List<int> order = <int>[
      for (int i = 0; i < bands.length; i++) i,
    ];
    if (bands.length > 2 && _totalWidth(free[1]) > _totalWidth(free[0])) {
      order.setAll(0, <int>[1, 0]);
    }

    for (final int i in order) {
      final double need = w + air;
      final List<_Span> fitting = free[i]
          .where((_Span s) => s.width >= need)
          .toList();
      if (fitting.isEmpty) continue;
      final _Span s = toLeft ? fitting.first : fitting.last;
      final double inset = math.min(air, s.width - w);
      final double x = toLeft ? s.start + inset : s.end - inset - w;
      return _RefLabel(
        text: text,
        painter: tp,
        box: Rect.fromLTWH(x, bands[i].top, w, h),
        plate: true,
      );
    }
    return null;
  }

  /// Which end of the rule has more free room in [bands].
  bool _emptierEndIsLeft(List<Rect> bands, List<ChartBox> boxes, double left) {
    double atLeft = 0;
    double atRight = 0;
    for (final Rect band in bands) {
      final double middle = (left + band.right) / 2;
      for (final _Span s in _freeSpans(band, boxes, 2)) {
        atLeft += math.max(0, math.min(s.end, middle) - s.start);
        atRight += math.max(0, s.end - math.max(s.start, middle));
      }
    }
    // A tie goes left: that is the end a reader's eye starts from.
    return atLeft >= atRight;
  }

  double _totalWidth(List<_Span> spans) =>
      spans.fold(0, (double a, _Span s) => a + s.width);

  /// The stretches of [band] that no measured box covers, with [air] left
  /// around each box so the chip does not stand flush against a bar.
  List<_Span> _freeSpans(Rect band, List<ChartBox> boxes, double air) {
    final List<_Span> blocked = <_Span>[];
    for (final ChartBox b in boxes) {
      final Rect r = b.rect;
      if (r.isEmpty) continue;
      if (r.bottom <= band.top || r.top >= band.bottom) continue;
      if (r.right + air <= band.left || r.left - air >= band.right) continue;
      blocked.add(
        _Span(
          math.max(r.left - air, band.left),
          math.min(r.right + air, band.right),
        ),
      );
    }
    blocked.sort((_Span a, _Span b) => a.start.compareTo(b.start));

    final List<_Span> out = <_Span>[];
    double cursor = band.left;
    for (final _Span s in blocked) {
      if (s.start > cursor) out.add(_Span(cursor, s.start));
      cursor = math.max(cursor, s.end);
      if (cursor >= band.right) break;
    }
    if (cursor < band.right) out.add(_Span(cursor, band.right));
    return out;
  }

  void _paintReference(Canvas canvas, Rect plot) {
    final ChartReferenceLine? ref = spec.referenceLine;
    if (ref == null) return;
    if (ref.value < geometry.min || ref.value > geometry.max) return;
    final double y = _y(plot, ref.value);
    final Color c = _referenceColor;

    // Dashed, so it never reads as another series.
    final Paint p = Paint()
      ..color = c
      ..strokeWidth = 1.2;
    const double dash = 5;
    const double gap = 4;
    for (double x = plot.left; x < plot.right; x += dash + gap) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dash, plot.right), y),
        p,
      );
    }

    final _RefLabel? placed = _refLabel;
    if (placed == null) return;
    if (placed.plate) {
      // A small plate so the rule does not strike through the words.
      canvas.drawRRect(
        RRect.fromRectAndRadius(placed.box, const Radius.circular(4)),
        Paint()..color = palette.surface.withValues(alpha: placed.plateAlpha),
      );
    }
    placed.painter.paint(
      canvas,
      Offset(placed.box.left + 3, placed.box.top + 1),
    );
  }

  void _paintCategories(Canvas canvas, Rect plot) {
    final List<String> categories = spec.categories;
    if (categories.isEmpty) return;
    final int n = categories.length;
    final bool line = spec.kind == ChartKind.line;
    final double slot = line
        ? (n == 1 ? plot.width : plot.width / (n - 1))
        : plot.width / n;
    final double top = plot.bottom + 6;
    final TextStyle style = _labelStyle().copyWith(color: palette.muted);

    for (int i = 0; i < n; i++) {
      if (geometry.labelStride > 1 &&
          i % geometry.labelStride != 0 &&
          i != n - 1) {
        continue;
      }
      final double centre = line
          ? (n == 1 ? plot.center.dx : plot.left + slot * i)
          : plot.left + slot * (i + 0.5);
      final String text = categories[i];

      switch (geometry.labelLayout) {
        case ChartLabelLayout.flat:
        case ChartLabelLayout.wrapped:
          final int maxLines =
              geometry.labelLayout == ChartLabelLayout.wrapped ? 2 : 1;
          final double room = line
              ? math.max(slot, 40)
              : math.max(slot - 3, 18);
          final TextPainter tp = _paint(
            text,
            style,
            textScaler,
            fontFamily,
            maxWidth: room,
            maxLines: maxLines,
            ellipsis: true,
            align: TextAlign.center,
          );
          double x = centre - tp.width / 2;
          x = x.clamp(0.0, math.max(0.0, plot.right - tp.width));
          _collect?.add(
            ChartBox(
              ChartBoxKind.category,
              Rect.fromLTWH(x, top, tp.width, tp.height),
            ),
          );
          tp.paint(canvas, Offset(x, top));
        case ChartLabelLayout.tilted:
          final double cap = geometry.labelBand * math.sqrt2;
          final TextPainter tp = _paint(
            text,
            style,
            textScaler,
            fontFamily,
            maxWidth: cap,
            maxLines: 1,
            ellipsis: true,
          );
          // The box a 45° label sweeps, for anything that has to dodge it.
          final double run = tp.width * math.sqrt1_2;
          final double rise = tp.height * math.sqrt1_2;
          _collect?.add(
            ChartBox(
              ChartBoxKind.category,
              Rect.fromLTWH(
                centre + tp.height * 0.30 - run,
                top,
                run + rise,
                run + rise,
              ),
            ),
          );
          canvas.save();
          // Anchor the label's right-hand end under the bar's centre and rotate
          // it up to the right, so the end of the word points at its bar.
          canvas.translate(centre + tp.height * 0.30, top);
          canvas.rotate(-math.pi / 4);
          tp.paint(canvas, Offset(-tp.width, 0));
          canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(ChukChartPainter old) {
    // The reference label is measured against the FINISHED plot, so it does
    // not move while the entrance plays. Carry the measurement over instead
    // of laying every label out again on every frame of it.
    if (old.spec == spec &&
        old.geometry == geometry &&
        old.textScaler == textScaler &&
        old.palette.text == palette.text &&
        old.palette.surface == palette.surface) {
      _boxes = old._boxes;
      _refLabel = old._refLabel;
      _measuredFor = old._measuredFor;
    }
    return old.progress != progress ||
        old.spec != spec ||
        old.palette.text != palette.text ||
        old.geometry != geometry ||
        old.textScaler != textScaler;
  }
}

// -------------------------------------------------------------------------
// Shared helpers
// -------------------------------------------------------------------------

TextStyle _axisStyle() => const TextStyle(
  fontSize: _kAxisFontSize,
  height: 1.2,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.1,
);

TextStyle _labelStyle() => const TextStyle(
  fontSize: _kLabelFontSize,
  height: 1.15,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.0,
);

TextStyle _valueStyle() => const TextStyle(
  fontSize: _kValueFontSize,
  height: 1.1,
  fontWeight: FontWeight.w800,
  letterSpacing: -0.1,
);

TextPainter _paint(
  String text,
  TextStyle style,
  TextScaler scaler,
  String? fontFamily, {
  double maxWidth = double.infinity,
  int? maxLines,
  bool ellipsis = false,
  TextAlign align = TextAlign.left,
}) {
  final TextPainter tp = TextPainter(
    text: TextSpan(
      text: text,
      style: fontFamily == null ? style : style.copyWith(fontFamily: fontFamily),
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
    textScaler: scaler,
    maxLines: maxLines,
    ellipsis: ellipsis ? '…' : null,
  )..layout(maxWidth: maxWidth);
  return tp;
}

/// The reference line's label once it has found a spot: what it says, laid
/// out, and the box it took.
class _RefLabel {
  const _RefLabel({
    required this.text,
    required this.painter,
    required this.box,
    required this.plate,
    this.plateAlpha = 0.86,
  });

  final String text;
  final TextPainter painter;

  /// The plate, three pixels of air around the glyphs on each side.
  final Rect box;

  /// False only in the last resort, where the label sits on the rule itself.
  final bool plate;

  /// How solid the plate is. Translucent where it covers only background,
  /// opaque where it has to cover a tick to stay readable.
  final double plateAlpha;
}

/// A stretch of a strip, in x.
class _Span {
  const _Span(this.start, this.end);
  final double start;
  final double end;
  double get width => end - start;
}

class _Range {
  const _Range(this.min, this.max, this.step);
  final double min;
  final double max;
  final double step;
}

/// The value range and the gridline step.
///
/// A bar chart always includes zero — a bar that starts at 40 lies about how
/// big it is. A line chart does not: a price line between 61 000 and 63 000
/// would be a flat scratch at the top of a zero-based plot.
_Range _rangeFor(ChartSpec spec) {
  final List<double> values = spec.values.toList();
  final ChartReferenceLine? ref = spec.referenceLine;
  if (values.isEmpty) return const _Range(0, 1, 1);

  double lo = values.reduce(math.min);
  double hi = values.reduce(math.max);

  if (spec.kind == ChartKind.stacked) {
    // A stack is as tall as its total.
    final int n = spec.categories.length;
    for (int i = 0; i < n; i++) {
      double sum = 0;
      for (final ChartSeries s in spec.series) {
        if (i < s.points.length) sum += s.points[i].value;
      }
      hi = math.max(hi, sum);
      lo = math.min(lo, math.min(0, sum));
    }
  }

  if (ref != null) {
    lo = math.min(lo, ref.value);
    hi = math.max(hi, ref.value);
  }

  final bool zeroBased = spec.kind != ChartKind.line;
  if (zeroBased) {
    lo = math.min(lo, 0);
    hi = math.max(hi, 0);
  } else {
    final double pad = (hi - lo) * 0.12;
    lo -= pad == 0 ? (hi.abs() * 0.05 + 1) : pad;
    hi += pad == 0 ? (hi.abs() * 0.05 + 1) : pad;
  }

  lo = spec.axis.min ?? lo;
  hi = spec.axis.max ?? hi;
  if (hi <= lo) hi = lo + 1;

  final double step = _niceStep(hi - lo, 5);
  // Snap outward so the top gridline is a round number the label can own.
  final double snappedLo = spec.axis.min ?? (lo / step).floor() * step;
  final double snappedHi = spec.axis.max ?? (hi / step).ceil() * step;
  return _Range(snappedLo, math.max(snappedHi, snappedLo + step), step);
}

double _niceStep(double range, int target) {
  if (!range.isFinite || range <= 0) return 1;
  final double raw = range / math.max(target, 1);
  final double mag = math.pow(10, (math.log(raw) / math.ln10).floor())
      .toDouble();
  final double norm = raw / mag;
  final double mult = norm <= 1
      ? 1
      : norm <= 2
      ? 2
      : norm <= 2.5
      ? 2.5
      : norm <= 5
      ? 5
      : 10;
  return mult * mag;
}

int _decimalsFor(double step) {
  if (step >= 1) return 0;
  if (step >= 0.1) return 1;
  if (step >= 0.01) return 2;
  return 3;
}

/// An axis tick. Big numbers are abbreviated (62k, 1.2M) so the axis column
/// does not eat a third of a phone screen.
String _tickText(double v, ChartSpec spec, int decimals) {
  final double a = v.abs();
  String body;
  if (a >= 1000000) {
    body = '${_trimZeros((v / 1000000).toStringAsFixed(1))}M';
  } else if (a >= 10000) {
    body = '${_trimZeros((v / 1000).toStringAsFixed(1))}k';
  } else {
    body = v.toStringAsFixed(decimals);
  }
  if (spec.decimalSeparator != '.') body = body.replaceFirst('.', ',');
  return body;
}

String _trimZeros(String s) =>
    s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
