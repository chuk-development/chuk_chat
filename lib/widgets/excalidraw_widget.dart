// lib/widgets/excalidraw_widget.dart
//
// Native Flutter renderer for Excalidraw scene JSON
// (the `.excalidraw` file format shared by excalidraw.com and
// @excalidraw/excalidraw). Rendered inside ArtifactPanel when artifact
// type is `excalidraw`. Supports: rectangle, ellipse, diamond, line,
// arrow, text, freedraw. Rotations, fills, dashed/dotted strokes, text
// binding to a container shape (label), and roundness are honoured.
//
// Rendering is clean — it does NOT reproduce the rough.js sketchy stroke
// jitter exactly. For perfect visual fidelity users can download the
// `.excalidraw` file and open it at https://excalidraw.com.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class ExcalidrawWidget extends StatelessWidget {
  const ExcalidrawWidget({super.key, required this.jsonString});

  final String jsonString;

  @override
  Widget build(BuildContext context) {
    final ExcalidrawScene? scene;
    try {
      scene = ExcalidrawScene.fromJson(jsonString);
    } catch (e) {
      return _ErrorCard(message: 'Excalidraw parse error: $e');
    }
    if (scene == null || scene.elements.isEmpty) {
      return const _ErrorCard(message: 'Empty Excalidraw scene.');
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.maxWidth;
        final availH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : availW * (scene!.sceneHeight / scene.sceneWidth);

        final scaleX = availW / scene!.sceneWidth;
        final scaleY = availH / scene.sceneHeight;
        final scale = math.min(scaleX, scaleY);
        final paintW = scene.sceneWidth * scale;
        final paintH = scene.sceneHeight * scale;

        return Center(
          child: CustomPaint(
            size: Size(paintW, paintH),
            painter: ExcalidrawPainter(scene: scene, scale: scale),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Scene + element model
// ---------------------------------------------------------------------------

class ExcalidrawScene {
  ExcalidrawScene({
    required this.elements,
    required this.appState,
    required this.minX,
    required this.minY,
    required this.sceneWidth,
    required this.sceneHeight,
  });

  final List<Map<String, dynamic>> elements;
  final Map<String, dynamic> appState;

  /// Top-left of the raw content bounding box (in scene space).
  final double minX;
  final double minY;

  /// Padded content bounds used for fit-to-view calculations.
  final double sceneWidth;
  final double sceneHeight;

  /// Padding added around the raw content bounds so strokes, text overflow
  /// and arrow heads do not clip against the viewport edge.
  static const double padding = 16.0;

  static ExcalidrawScene? fromJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = jsonDecode(trimmed);
    if (parsed is! Map<String, dynamic>) return null;

    final rawElements = parsed['elements'];
    final appState = parsed['appState'];

    final elements = <Map<String, dynamic>>[];
    if (rawElements is List) {
      for (final e in rawElements) {
        if (e is Map<String, dynamic>) {
          if (e['isDeleted'] == true) continue;
          elements.add(e);
        } else if (e is Map) {
          if (e['isDeleted'] == true) continue;
          elements.add(Map<String, dynamic>.from(e));
        }
      }
    }

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (final e in elements) {
      final bounds = _elementBounds(e);
      if (bounds == null) continue;
      if (bounds.left < minX) minX = bounds.left;
      if (bounds.top < minY) minY = bounds.top;
      if (bounds.right > maxX) maxX = bounds.right;
      if (bounds.bottom > maxY) maxY = bounds.bottom;
    }

    if (!minX.isFinite) {
      // Scene without positionable elements.
      minX = 0;
      minY = 0;
      maxX = 400;
      maxY = 300;
    }

    final w = (maxX - minX).abs() + padding * 2;
    final h = (maxY - minY).abs() + padding * 2;
    return ExcalidrawScene(
      elements: elements,
      appState: appState is Map<String, dynamic>
          ? appState
          : appState is Map
          ? Map<String, dynamic>.from(appState)
          : const <String, dynamic>{},
      minX: minX,
      minY: minY,
      sceneWidth: w < 40 ? 40 : w,
      sceneHeight: h < 40 ? 40 : h,
    );
  }

  /// Returns the axis-aligned bounding box of [e] in scene space, accounting
  /// for rotation. `null` when the element carries no usable geometry.
  static Rect? _elementBounds(Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['width']);
    final h = _d(e['height']);
    final type = e['type']?.toString();
    final angle = _d(e['angle']);

    // line / arrow / freedraw: walk the points array so zig-zag waypoints
    // outside the start→end rectangle are included.
    if (type == 'line' || type == 'arrow' || type == 'freedraw') {
      final rawPoints = e['points'];
      if (rawPoints is List && rawPoints.isNotEmpty) {
        double minX = double.infinity;
        double minY = double.infinity;
        double maxX = double.negativeInfinity;
        double maxY = double.negativeInfinity;
        for (final p in rawPoints) {
          if (p is List && p.length >= 2) {
            final px = x + _d(p[0]);
            final py = y + _d(p[1]);
            final r = _rotatePoint(px, py, x + w / 2, y + h / 2, angle);
            if (r.dx < minX) minX = r.dx;
            if (r.dy < minY) minY = r.dy;
            if (r.dx > maxX) maxX = r.dx;
            if (r.dy > maxY) maxY = r.dy;
          }
        }
        if (minX.isFinite) return Rect.fromLTRB(minX, minY, maxX, maxY);
      }
    }

    if (w == 0 && h == 0 && type != 'text') return null;
    if (angle == 0) {
      return Rect.fromLTWH(x, y, w, h);
    }
    final cx = x + w / 2;
    final cy = y + h / 2;
    final corners = <Offset>[
      Offset(x, y),
      Offset(x + w, y),
      Offset(x + w, y + h),
      Offset(x, y + h),
    ];
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (final p in corners) {
      final r = _rotatePoint(p.dx, p.dy, cx, cy, angle);
      if (r.dx < minX) minX = r.dx;
      if (r.dy < minY) minY = r.dy;
      if (r.dx > maxX) maxX = r.dx;
      if (r.dy > maxY) maxY = r.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static Offset _rotatePoint(
    double x,
    double y,
    double cx,
    double cy,
    double angle,
  ) {
    if (angle == 0) return Offset(x, y);
    final dx = x - cx;
    final dy = y - cy;
    return Offset(
      dx * math.cos(angle) - dy * math.sin(angle) + cx,
      dx * math.sin(angle) + dy * math.cos(angle) + cy,
    );
  }
}

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class ExcalidrawPainter extends CustomPainter {
  ExcalidrawPainter({required this.scene, required this.scale});

  final ExcalidrawScene scene;
  final double scale;

  /// Map a scene-space point into canvas pixels.
  Offset _pt(double x, double y) => Offset(
    (x - scene.minX + ExcalidrawScene.padding) * scale,
    (y - scene.minY + ExcalidrawScene.padding) * scale,
  );

  double _sx(double v) => v * scale;

  @override
  void paint(Canvas canvas, Size size) {
    _canvasSize = size;
    // Background: honour appState.viewBackgroundColor, default white.
    final bgColor = _parseColor(
      scene.appState['viewBackgroundColor']?.toString(),
      fallback: Colors.white,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = bgColor,
    );

    for (final e in scene.elements) {
      _drawElement(canvas, e);
    }
  }

  void _drawElement(Canvas canvas, Map<String, dynamic> e) {
    final type = e['type']?.toString() ?? '';
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['width']);
    final h = _d(e['height']);
    final angle = _d(e['angle']);
    final opacity = (_d(e['opacity']) / 100.0).clamp(0.0, 1.0);
    // Excalidraw default opacity is 100 — treat missing as 1.0.
    final effectiveOpacity = e.containsKey('opacity') ? opacity : 1.0;

    final center = _pt(x + w / 2, y + h / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    if (angle != 0) canvas.rotate(angle);
    canvas.translate(-center.dx, -center.dy);
    if (effectiveOpacity < 1.0) {
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, _canvasSize.width, _canvasSize.height),
        Paint()..color = Color.fromRGBO(0, 0, 0, effectiveOpacity),
      );
    }

    switch (type) {
      case 'rectangle':
        _drawRectangle(canvas, e);
      case 'ellipse':
        _drawEllipse(canvas, e);
      case 'diamond':
        _drawDiamond(canvas, e);
      case 'line':
        _drawLineOrArrow(canvas, e, arrow: false);
      case 'arrow':
        _drawLineOrArrow(canvas, e, arrow: true);
      case 'text':
        _drawText(canvas, e);
      case 'freedraw':
        _drawFreedraw(canvas, e);
      case 'frame':
      case 'magicframe':
        _drawFrame(canvas, e);
      // Unknown types are silently skipped — AI may emit newer shapes.
    }

    if (effectiveOpacity < 1.0) {
      canvas.restore();
    }
    canvas.restore();
  }

  /// Captured inside [paint] so nested `saveLayer` calls can use the full
  /// canvas rectangle as bounds.
  Size _canvasSize = Size.zero;

  // ── Shapes ─────────────────────────────────────────────────

  void _drawRectangle(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['width']);
    final h = _d(e['height']);
    final roundness = e['roundness'];
    final radius = roundness is Map
        ? _computeRoundnessRadius(w, h)
        : 0.0;

    final rect = Rect.fromPoints(_pt(x, y), _pt(x + w, y + h));
    RRect rr = RRect.fromRectAndRadius(rect, Radius.circular(_sx(radius)));

    // Fill first so stroke sits on top.
    final fillPaint = _fillPaint(e);
    if (fillPaint != null) {
      _drawFillShape(canvas, rect, fillPaint, isEllipse: false, rrect: rr);
    }

    final strokePaint = _strokePaint(e);
    if (strokePaint != null) {
      if (_strokeStyle(e) == 'solid') {
        canvas.drawRRect(rr, strokePaint);
      } else {
        _drawStyledRect(canvas, rect, radius, strokePaint, _strokeStyle(e));
      }
    }
  }

  void _drawEllipse(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['width']);
    final h = _d(e['height']);
    final rect = Rect.fromPoints(_pt(x, y), _pt(x + w, y + h));

    final fillPaint = _fillPaint(e);
    if (fillPaint != null) {
      _drawFillShape(canvas, rect, fillPaint, isEllipse: true);
    }

    final strokePaint = _strokePaint(e);
    if (strokePaint != null) {
      if (_strokeStyle(e) == 'solid') {
        canvas.drawOval(rect, strokePaint);
      } else {
        _drawStyledOval(canvas, rect, strokePaint, _strokeStyle(e));
      }
    }
  }

  void _drawDiamond(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['width']);
    final h = _d(e['height']);
    final top = _pt(x + w / 2, y);
    final right = _pt(x + w, y + h / 2);
    final bottom = _pt(x + w / 2, y + h);
    final left = _pt(x, y + h / 2);
    final path = ui.Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(left.dx, left.dy)
      ..close();

    final fillPaint = _fillPaint(e);
    if (fillPaint != null) {
      canvas.drawPath(path, fillPaint);
    }
    final strokePaint = _strokePaint(e);
    if (strokePaint != null) {
      if (_strokeStyle(e) == 'solid') {
        canvas.drawPath(path, strokePaint);
      } else {
        _drawStyledPolyline(
          canvas,
          [top, right, bottom, left, top],
          strokePaint,
          _strokeStyle(e),
        );
      }
    }
  }

  void _drawLineOrArrow(
    Canvas canvas,
    Map<String, dynamic> e, {
    required bool arrow,
  }) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final rawPoints = e['points'];
    final pts = <Offset>[];
    if (rawPoints is List) {
      for (final p in rawPoints) {
        if (p is List && p.length >= 2) {
          pts.add(_pt(x + _d(p[0]), y + _d(p[1])));
        }
      }
    }
    if (pts.length < 2) {
      // Fallback to element bounds.
      final w = _d(e['width']);
      final h = _d(e['height']);
      pts.add(_pt(x, y));
      pts.add(_pt(x + w, y + h));
    }

    final strokePaint = _strokePaint(e);
    if (strokePaint == null) return;

    if (_strokeStyle(e) == 'solid') {
      final path = ui.Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, strokePaint);
    } else {
      _drawStyledPolyline(canvas, pts, strokePaint, _strokeStyle(e));
    }

    if (arrow) {
      final startHead = e['startArrowhead']?.toString();
      final endHead = e['endArrowhead']?.toString() ?? 'arrow';
      if (endHead.isNotEmpty && endHead != 'null') {
        _drawArrowhead(canvas, pts[pts.length - 2], pts.last, strokePaint,
            endHead);
      }
      if (startHead != null && startHead != 'null' && startHead.isNotEmpty) {
        _drawArrowhead(canvas, pts[1], pts.first, strokePaint, startHead);
      }
    }
  }

  void _drawArrowhead(
    Canvas canvas,
    Offset from,
    Offset tip,
    Paint paint,
    String shape,
  ) {
    final dx = tip.dx - from.dx;
    final dy = tip.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.5) return;
    final ux = dx / len;
    final uy = dy / len;
    final headLen = math.max(_sx(14), paint.strokeWidth * 3.5);
    final halfW = headLen * 0.4;
    final bx = tip.dx - ux * headLen;
    final by = tip.dy - uy * headLen;
    final px = -uy * halfW;
    final py = ux * halfW;

    switch (shape) {
      case 'triangle':
        final path = ui.Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(bx + px, by + py)
          ..lineTo(bx - px, by - py)
          ..close();
        canvas.drawPath(
          path,
          Paint()
            ..color = paint.color
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
      case 'dot':
        canvas.drawCircle(
          tip,
          headLen * 0.4,
          Paint()
            ..color = paint.color
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
      case 'bar':
        final p1 = Offset(tip.dx + px, tip.dy + py);
        final p2 = Offset(tip.dx - px, tip.dy - py);
        canvas.drawLine(p1, p2, paint);
      case 'arrow':
      default:
        // Two line segments forming an open arrow.
        canvas.drawLine(tip, Offset(bx + px, by + py), paint);
        canvas.drawLine(tip, Offset(bx - px, by - py), paint);
    }
  }

  void _drawFreedraw(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final rawPoints = e['points'];
    if (rawPoints is! List || rawPoints.isEmpty) return;

    final strokePaint = _strokePaint(e);
    if (strokePaint == null) return;

    strokePaint.strokeCap = StrokeCap.round;
    strokePaint.strokeJoin = StrokeJoin.round;

    final path = ui.Path();
    bool started = false;
    for (final p in rawPoints) {
      if (p is! List || p.length < 2) continue;
      final pt = _pt(x + _d(p[0]), y + _d(p[1]));
      if (!started) {
        path.moveTo(pt.dx, pt.dy);
        started = true;
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(path, strokePaint);
  }

  void _drawText(Canvas canvas, Map<String, dynamic> e) {
    final text = e['text']?.toString() ?? '';
    if (text.isEmpty) return;
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['width']);
    final h = _d(e['height']);
    final fontSize = _d(e['fontSize']);
    final fontFamily = _mapFontFamily(e['fontFamily']);
    final align = _textAlign(e['textAlign']?.toString());
    final color = _parseColor(
      e['strokeColor']?.toString(),
      fallback: Colors.black,
    );

    final style = ui.TextStyle(
      color: color,
      fontSize: _sx(fontSize <= 0 ? 20 : fontSize),
      fontFamily: fontFamily,
      height: 1.25,
    );
    final paragraphStyle = ui.ParagraphStyle(textAlign: align);
    final builder = ui.ParagraphBuilder(paragraphStyle)
      ..pushStyle(style)
      ..addText(text);
    final widthPx = _sx(w <= 0 ? 400 : w);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: widthPx <= 0 ? 400 : widthPx));

    // Vertical alignment inside the bound box (default: top).
    final verticalAlign = e['verticalAlign']?.toString();
    final boxH = _sx(h);
    final dy = switch (verticalAlign) {
      'middle' => (boxH - paragraph.height) / 2,
      'bottom' => boxH - paragraph.height,
      _ => 0.0,
    };

    final origin = _pt(x, y);
    canvas.drawParagraph(paragraph, Offset(origin.dx, origin.dy + dy));
  }

  void _drawFrame(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['width']);
    final h = _d(e['height']);
    final rect = Rect.fromPoints(_pt(x, y), _pt(x + w, y + h));
    final paint = Paint()
      ..color = const Color(0xFFCCCCCC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _sx(1.0)
      ..isAntiAlias = true;
    canvas.drawRect(rect, paint);
    final name = e['name']?.toString();
    if (name != null && name.isNotEmpty) {
      final style = ui.TextStyle(
        color: Colors.grey,
        fontSize: _sx(12),
        fontFamily: 'sans-serif',
      );
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(textAlign: TextAlign.left),
      )
        ..pushStyle(style)
        ..addText(name);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: rect.width));
      canvas.drawParagraph(
        paragraph,
        Offset(rect.left, rect.top - paragraph.height - _sx(2)),
      );
    }
  }

  // ── Styled stroke helpers ──────────────────────────────────

  void _drawStyledRect(
    Canvas canvas,
    Rect rect,
    double radiusMm,
    Paint paint,
    String style,
  ) {
    final tl = rect.topLeft;
    final tr = rect.topRight;
    final br = rect.bottomRight;
    final bl = rect.bottomLeft;
    _drawStyledSegment(canvas, tl, tr, paint, style);
    _drawStyledSegment(canvas, tr, br, paint, style);
    _drawStyledSegment(canvas, br, bl, paint, style);
    _drawStyledSegment(canvas, bl, tl, paint, style);
  }

  void _drawStyledOval(Canvas canvas, Rect rect, Paint paint, String style) {
    // Approximate dashed oval with many short arcs.
    const steps = 96;
    final pattern = _patternForStyle(style, paint.strokeWidth);
    final dashOn = pattern[0];
    final dashOff = pattern[1];
    final period = dashOn + dashOff;
    final rx = rect.width / 2;
    final ry = rect.height / 2;
    final cx = rect.center.dx;
    final cy = rect.center.dy;

    // Approximate circumference.
    final circumference =
        math.pi * (3 * (rx + ry) - math.sqrt((3 * rx + ry) * (rx + 3 * ry)));
    final segmentsDistance = circumference / steps;
    double drawnDistance = 0;
    Offset? prev;
    for (int i = 0; i <= steps; i++) {
      final t = (i / steps) * 2 * math.pi;
      final p = Offset(cx + rx * math.cos(t), cy + ry * math.sin(t));
      if (prev != null) {
        // Within this tiny arc, draw only if we are in the "on" phase.
        final phase = drawnDistance % period;
        if (phase < dashOn) {
          canvas.drawLine(prev, p, paint);
        }
      }
      prev = p;
      drawnDistance += segmentsDistance;
    }
  }

  void _drawStyledPolyline(
    Canvas canvas,
    List<Offset> pts,
    Paint paint,
    String style,
  ) {
    for (int i = 0; i < pts.length - 1; i++) {
      _drawStyledSegment(canvas, pts[i], pts[i + 1], paint, style);
    }
  }

  void _drawStyledSegment(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint,
    String style,
  ) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.5) return;
    final ux = dx / len;
    final uy = dy / len;
    final pattern = _patternForStyle(style, paint.strokeWidth);
    final dashOn = pattern[0];
    final dashOff = pattern[1];
    double drawn = 0;
    bool on = true;
    while (drawn < len) {
      final seg = math.min(on ? dashOn : dashOff, len - drawn);
      if (on && seg > 0) {
        final sx = a.dx + ux * drawn;
        final sy = a.dy + uy * drawn;
        final ex = a.dx + ux * (drawn + seg);
        final ey = a.dy + uy * (drawn + seg);
        canvas.drawLine(Offset(sx, sy), Offset(ex, ey), paint);
      }
      drawn += seg;
      on = !on;
    }
  }

  List<double> _patternForStyle(String style, double strokeWidth) {
    switch (style) {
      case 'dotted':
        final s = math.max(_sx(1.5), strokeWidth);
        return [s * 0.5, s * 2.0];
      case 'dashed':
        final s = math.max(_sx(6), strokeWidth * 3);
        return [s, s * 0.75];
      default:
        return [double.infinity, 0];
    }
  }

  // ── Fills (solid / hachure / cross-hatch) ──────────────────

  void _drawFillShape(
    Canvas canvas,
    Rect rect,
    Paint fillPaint, {
    required bool isEllipse,
    RRect? rrect,
  }) {
    final style = fillPaint.style;
    if (style == PaintingStyle.fill) {
      if (isEllipse) {
        canvas.drawOval(rect, fillPaint);
      } else if (rrect != null) {
        canvas.drawRRect(rrect, fillPaint);
      } else {
        canvas.drawRect(rect, fillPaint);
      }
    } else {
      // Hachure / cross-hatch: clip to shape then draw diagonal lines.
      canvas.save();
      final clipPath = ui.Path();
      if (isEllipse) {
        clipPath.addOval(rect);
      } else if (rrect != null) {
        clipPath.addRRect(rrect);
      } else {
        clipPath.addRect(rect);
      }
      canvas.clipPath(clipPath);
      final spacing = math.max(_sx(6), fillPaint.strokeWidth * 3);
      _drawHachureLines(canvas, rect, fillPaint, spacing, math.pi / 4);
      // cross-hatch adds a second pass at the perpendicular angle.
      if (fillPaint.strokeMiterLimit == 42) {
        _drawHachureLines(canvas, rect, fillPaint, spacing, -math.pi / 4);
      }
      canvas.restore();
    }
  }

  void _drawHachureLines(
    Canvas canvas,
    Rect rect,
    Paint paint,
    double spacing,
    double angle,
  ) {
    final diag = math.sqrt(rect.width * rect.width + rect.height * rect.height);
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final nx = -dy;
    final ny = dx;
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final steps = (diag / spacing).ceil() + 1;
    for (int i = -steps; i <= steps; i++) {
      final ox = cx + nx * i * spacing;
      final oy = cy + ny * i * spacing;
      final p1 = Offset(ox - dx * diag, oy - dy * diag);
      final p2 = Offset(ox + dx * diag, oy + dy * diag);
      canvas.drawLine(p1, p2, paint);
    }
  }

  // ── Paint construction ────────────────────────────────────

  Paint? _strokePaint(Map<String, dynamic> e) {
    final colorStr = e['strokeColor']?.toString();
    if (colorStr == null || colorStr.trim().isEmpty || colorStr == 'transparent') {
      return null;
    }
    final color = _parseColor(colorStr, fallback: const Color(0xFF1E1E1E));
    if (color.a == 0) return null;
    final widthRaw = _d(e['strokeWidth']);
    final width = widthRaw > 0 ? widthRaw : 2.0;
    return Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _sx(width)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
  }

  Paint? _fillPaint(Map<String, dynamic> e) {
    final bgStr = e['backgroundColor']?.toString();
    if (bgStr == null ||
        bgStr.trim().isEmpty ||
        bgStr == 'transparent') {
      return null;
    }
    final color = _parseColor(bgStr, fallback: Colors.transparent);
    if (color.a == 0) return null;
    final fillStyle = e['fillStyle']?.toString() ?? 'hachure';
    if (fillStyle == 'solid') {
      return Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
    }
    // Hachure / cross-hatch: stroke-based.
    final widthRaw = _d(e['strokeWidth']);
    final width = widthRaw > 0 ? widthRaw : 1.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _sx(width * 0.8)
      ..isAntiAlias = true;
    // Flag cross-hatch via strokeMiterLimit sentinel (re-used internally).
    if (fillStyle == 'cross-hatch') {
      paint.strokeMiterLimit = 42;
    }
    return paint;
  }

  String _strokeStyle(Map<String, dynamic> e) {
    final s = e['strokeStyle']?.toString() ?? 'solid';
    return (s == 'dashed' || s == 'dotted') ? s : 'solid';
  }

  double _computeRoundnessRadius(double w, double h) {
    // Match Excalidraw default: min(width, height) / 4, capped at 32.
    final base = math.min(w.abs(), h.abs()) / 4;
    return math.min(base, 32.0);
  }

  String _mapFontFamily(dynamic raw) {
    // Excalidraw numeric font ids:
    //   1 = Virgil (hand-drawn)
    //   2 = Helvetica
    //   3 = Cascadia (monospace)
    //   4 = Assistant
    if (raw is num) {
      switch (raw.toInt()) {
        case 1:
          // Virgil isn't available on most devices — fall back to cursive.
          return 'sans-serif';
        case 3:
          return 'monospace';
        default:
          return 'sans-serif';
      }
    }
    if (raw is String && raw.trim().isNotEmpty) return raw;
    return 'sans-serif';
  }

  TextAlign _textAlign(String? raw) {
    switch (raw) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      default:
        return TextAlign.left;
    }
  }

  @override
  bool shouldRepaint(covariant ExcalidrawPainter oldDelegate) =>
      oldDelegate.scene != scene || oldDelegate.scale != scale;
}

// ---------------------------------------------------------------------------
// Colour parsing (supports #RGB, #RRGGBB, #RRGGBBAA, rgb(), rgba(), named).
// ---------------------------------------------------------------------------

Color _parseColor(String? raw, {required Color fallback}) {
  if (raw == null) return fallback;
  var s = raw.trim();
  if (s.isEmpty) return fallback;
  if (s == 'transparent') return const Color(0x00000000);
  if (s.startsWith('#')) {
    final hex = s.substring(1);
    final expanded = switch (hex.length) {
      3 => hex.split('').map((c) => '$c$c').join(),
      4 => hex.split('').map((c) => '$c$c').join(),
      6 || 8 => hex,
      _ => null,
    };
    if (expanded == null) return fallback;
    final value = int.tryParse(expanded, radix: 16);
    if (value == null) return fallback;
    if (expanded.length == 6) {
      return Color(0xFF000000 | value);
    }
    // 8 chars: #RRGGBBAA → Flutter expects AARRGGBB.
    final r = (value >> 24) & 0xFF;
    final g = (value >> 16) & 0xFF;
    final b = (value >> 8) & 0xFF;
    final a = value & 0xFF;
    return Color.fromARGB(a, r, g, b);
  }
  if (s.startsWith('rgb')) {
    final open = s.indexOf('(');
    final close = s.indexOf(')');
    if (open < 0 || close <= open) return fallback;
    final inside = s.substring(open + 1, close);
    final parts = inside.split(',').map((e) => e.trim()).toList();
    if (parts.length < 3) return fallback;
    final r = int.tryParse(parts[0]) ?? 0;
    final g = int.tryParse(parts[1]) ?? 0;
    final b = int.tryParse(parts[2]) ?? 0;
    double a = 1.0;
    if (parts.length >= 4) {
      a = double.tryParse(parts[3]) ?? 1.0;
    }
    return Color.fromARGB(
      (a.clamp(0.0, 1.0) * 255).round(),
      r.clamp(0, 255),
      g.clamp(0, 255),
      b.clamp(0, 255),
    );
  }
  // Named colour lookup (small set).
  const named = <String, Color>{
    'black': Color(0xFF000000),
    'white': Color(0xFFFFFFFF),
    'red': Color(0xFFE03131),
    'green': Color(0xFF2F9E44),
    'blue': Color(0xFF1971C2),
    'yellow': Color(0xFFF08C00),
    'orange': Color(0xFFFD7E14),
    'purple': Color(0xFF9C36B5),
    'pink': Color(0xFFC2255C),
    'gray': Color(0xFF868E96),
    'grey': Color(0xFF868E96),
  };
  final lookup = named[s.toLowerCase()];
  if (lookup != null) return lookup;
  return fallback;
}

// ---------------------------------------------------------------------------
// Error card
// ---------------------------------------------------------------------------

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}
