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

import 'package:cowork/widgets/charts/chart_palette.dart';
import 'package:cowork/widgets/charts/chart_spec.dart';

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

  /// Where the reference line's label will be painted. A value label that
  /// would land on it is moved out of the way instead of being buried: the
  /// threshold label is opaque, and the last bars in a results chart sit
  /// exactly where it wants to be.
  Rect? _refLabelRect;

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
    _refLabelRect = _referenceLabelRect(plot);
    _paintUnitCaption(canvas, plot);
    _paintGrid(canvas, plot, size.width);
    if (spec.kind == ChartKind.line) {
      _paintLines(canvas, plot);
    } else if (spec.kind == ChartKind.stacked) {
      _paintStacked(canvas, plot);
    } else {
      _paintBars(canvas, plot);
    }
    _paintReference(canvas, plot);
    _paintCategories(canvas, plot);
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
      tp.paint(
        canvas,
        Offset(geometry.axisWidth - 6 - tp.width, y - tp.height / 2),
      );
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
        final double top = math.min(zeroY, zeroY + (target - zeroY) * progress);
        final double bottom = math.max(
          zeroY,
          zeroY + (target - zeroY) * progress,
        );
        final Rect bar = Rect.fromLTRB(
          laneCentre - barWidth / 2,
          top,
          laneCentre + barWidth / 2,
          bottom,
        );
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

        if (spec.drawsValueLabels && progress > 0.35) {
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
            fade: ((progress - 0.35) / 0.35).clamp(0.0, 1.0),
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
        final double topEnd = zeroY + (to - zeroY) * progress;
        final double bottomEnd = zeroY + (from - zeroY) * progress;
        canvas.drawRect(
          Rect.fromLTRB(
            centre - barWidth / 2,
            math.min(topEnd, bottomEnd),
            centre + barWidth / 2,
            math.max(topEnd, bottomEnd),
          ),
          Paint()..color = fill,
        );
      }
      if (spec.drawsValueLabels && progress > 0.35) {
        final double top = zeroY + (_y(plot, running) - zeroY) * progress;
        _paintValue(
          canvas,
          text: spec.format(running, withUnit: !spec.unitOverAxis),
          centre: centre,
          slot: slot,
          anchorY: top,
          above: true,
          color: palette.text,
          plot: plot,
          fade: ((progress - 0.35) / 0.35).clamp(0.0, 1.0),
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
      final Path drawn = _trim(path, progress);

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
      final int drawnCount = (ser.points.length * progress).ceil();
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
      if (progress > 0.7) {
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
          fade: ((progress - 0.7) / 0.3).clamp(0.0, 1.0),
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

    // Step over the reference label rather than under it.
    final Rect? blocked = _refLabelRect;
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
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(6)),
        Paint()..color = color.withValues(alpha: 0.14 * fade),
      );
    }
    tp.paint(canvas, Offset(x, y));
  }

  /// The box the reference label will occupy, worked out before anything is
  /// drawn so the value labels can dodge it.
  Rect? _referenceLabelRect(Rect plot) {
    final ChartReferenceLine? ref = spec.referenceLine;
    if (ref == null || ref.label == null) return null;
    if (ref.value < geometry.min || ref.value > geometry.max) return null;
    final double y = _y(plot, ref.value);
    final TextPainter tp = _paint(
      ref.label!,
      _axisStyle().copyWith(fontWeight: FontWeight.w700),
      textScaler,
      fontFamily,
      maxWidth: plot.width,
      maxLines: 1,
      ellipsis: true,
    );
    final bool above = y - tp.height - 3 >= plot.top;
    final double ty = above ? y - tp.height - 2 : y + 2;
    final double tx = math.max(plot.left, plot.right - tp.width - 1);
    return Rect.fromLTWH(tx - 3, ty - 1, tp.width + 6, tp.height + 2);
  }

  void _paintReference(Canvas canvas, Rect plot) {
    final ChartReferenceLine? ref = spec.referenceLine;
    if (ref == null) return;
    if (ref.value < geometry.min || ref.value > geometry.max) return;
    final double y = _y(plot, ref.value);
    final Color c = ref.color == null
        ? palette.text.withValues(alpha: 0.55)
        : palette.legible(ref.color!);

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

    final String? label = ref.label;
    if (label == null) return;
    final TextPainter tp = _paint(
      label,
      _axisStyle().copyWith(
        color: c,
        fontWeight: FontWeight.w700,
      ),
      textScaler,
      fontFamily,
      maxWidth: plot.width,
      maxLines: 1,
    );
    // Above the rule when there is room above it, below it otherwise.
    final bool above = y - tp.height - 3 >= plot.top;
    final double ty = above ? y - tp.height - 2 : y + 2;
    final double tx = math.max(plot.left, plot.right - tp.width - 1);
    // A small plate so the rule does not strike through the words.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(tx - 3, ty - 1, tp.width + 6, tp.height + 2),
        const Radius.circular(4),
      ),
      Paint()..color = palette.surface.withValues(alpha: 0.86),
    );
    tp.paint(canvas, Offset(tx, ty));
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
  bool shouldRepaint(ChukChartPainter old) =>
      old.progress != progress ||
      old.spec != spec ||
      old.palette.text != palette.text ||
      old.geometry != geometry ||
      old.textScaler != textScaler;
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
