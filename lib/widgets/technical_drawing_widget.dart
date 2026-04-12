// lib/widgets/technical_drawing_widget.dart
//
// Renders DIN ISO 128 technical drawings from JSON produced by the AI.
// Used inside ArtifactPanel when artifact type is technicalDrawing.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Public widget
// ---------------------------------------------------------------------------

class TechnicalDrawingWidget extends StatelessWidget {
  const TechnicalDrawingWidget({super.key, required this.jsonString});

  final String jsonString;

  @override
  Widget build(BuildContext context) {
    final TechDrawData? data;
    try {
      data = TechDrawData.fromJson(jsonString);
    } catch (e) {
      return _ErrorCard(message: 'Drawing parse error: $e');
    }
    if (data == null) {
      return const _ErrorCard(message: 'Empty drawing data');
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.maxWidth;
        final availH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : availW * (data!.sheetH / data.sheetW);

        // Fit sheet into available space preserving aspect ratio.
        final scaleX = availW / data!.sheetW;
        final scaleY = availH / data.sheetH;
        final scale = math.min(scaleX, scaleY);

        final paintW = data.sheetW * scale;
        final paintH = data.sheetH * scale;

        return Center(
          child: CustomPaint(
            size: Size(paintW, paintH),
            painter: TechDrawPainter(data: data, scale: scale),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

class TechDrawData {
  TechDrawData({
    required this.meta,
    required this.elements,
    required this.sheetW,
    required this.sheetH,
  });

  final Map<String, dynamic> meta;
  final List<Map<String, dynamic>> elements;
  final double sheetW; // mm
  final double sheetH; // mm

  static TechDrawData? fromJson(String raw) {
    final parsed = jsonDecode(raw.trim());
    if (parsed is! Map<String, dynamic>) return null;

    final meta = (parsed['meta'] as Map<String, dynamic>?) ?? {};
    final rawElems = parsed['elements'] as List? ?? [];
    final elems = rawElems.whereType<Map<String, dynamic>>().toList();

    // Derive sheet size from element bounds + padding, or default A4 landscape.
    double maxX = 297.0, maxY = 210.0; // A4 landscape minimum (297x210 mm)
    for (final e in elems) {
      final t = e['type'] as String? ?? '';
      switch (t) {
        case 'rect':
          final x = _d(e['x']) + _d(e['w']);
          final y = _d(e['y']) + _d(e['h']);
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        case 'circle':
          final x = _d(e['cx']) + _d(e['r']);
          final y = _d(e['cy']) + _d(e['r']);
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        case 'line':
          final x = math.max(_d(e['x1']), _d(e['x2']));
          final y = math.max(_d(e['y1']), _d(e['y2']));
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        case 'dimension':
          final sub = e['subtype'] as String? ?? '';
          if (sub == 'linear_h') {
            final x = math.max(_d(e['x1']), _d(e['x2']));
            final y = _d(e['y']) + _d(e['offset']).abs() + 10;
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
          } else if (sub == 'linear_v') {
            final x = _d(e['x']) + _d(e['offset']).abs() + 10;
            final y = math.max(_d(e['y1']), _d(e['y2']));
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
          }
        case 'note':
          final x = _d(e['x']) + 30; // rough text width
          final y = _d(e['y']);
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
      }
    }

    // Add margins: 20mm top/left drawing area + 10mm padding + title block
    const titleBlockH = 40.0;
    const margin = 25.0;
    final sheetW = maxX + margin + 10;
    final sheetH = maxY + margin + titleBlockH;

    return TechDrawData(
      meta: meta,
      elements: elems,
      sheetW: sheetW,
      sheetH: sheetH,
    );
  }

  static double _d(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }
}

// ---------------------------------------------------------------------------
// CustomPainter
// ---------------------------------------------------------------------------

class TechDrawPainter extends CustomPainter {
  TechDrawPainter({required this.data, required this.scale});

  final TechDrawData data;
  final double scale;

  // Convert mm to canvas pixels.
  double _mm(double mm) => mm * scale;

  Offset _pt(double xMm, double yMm) => Offset(_mm(xMm), _mm(yMm));

  @override
  void paint(Canvas canvas, Size size) {
    _drawSheet(canvas, size);
    _drawElements(canvas);
    _drawTitleBlock(canvas, size);
  }

  /// Draw priority so overlays read correctly:
  ///  0 = construction lines (centerline / dashed / hidden)
  ///  1 = thin solid geometry (extension, hatch, auxiliary)
  ///  2 = thick solid geometry (main contours)
  ///  3 = dimensions
  ///  4 = notes (always on top, opaque background)
  int _priority(Map<String, dynamic> e) {
    final type = e['type'] as String? ?? '';
    if (type == 'note') return 4;
    if (type == 'dimension') return 3;
    final style = e['lineStyle'] as String? ?? 'solid';
    if (style == 'centerline' || style == 'dashed' || style == 'hidden') {
      return 0;
    }
    final weight = e['weight'] as String? ?? 'thin';
    return weight == 'thick' ? 2 : 1;
  }

  // ── Sheet ──────────────────────────────────────────────────

  void _drawSheet(Canvas canvas, Size size) {
    // White background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.white,
    );

    // Border frame (5mm margin)
    const m = 5.0;
    final borderPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = _mm(0.5)
      ..isAntiAlias = true;
    canvas.drawRect(
      Rect.fromLTRB(_mm(m), _mm(m), size.width - _mm(m), size.height - _mm(m)),
      borderPaint,
    );
  }

  // ── Elements ───────────────────────────────────────────────

  void _drawElements(Canvas canvas) {
    final ordered = [...data.elements]
      ..sort((a, b) => _priority(a).compareTo(_priority(b)));

    for (final e in ordered) {
      final type = e['type'] as String? ?? '';
      switch (type) {
        case 'rect':
          _drawRect(canvas, e);
        case 'circle':
          _drawCircle(canvas, e);
        case 'line':
          _drawLine(canvas, e);
        case 'dimension':
          _drawDimension(canvas, e);
        case 'note':
          _drawNote(canvas, e);
      }
    }
  }

  Paint _elementPaint(Map<String, dynamic> e) {
    final weight = e['weight'] as String? ?? 'thin';
    final strokeW = weight == 'thick' ? _mm(0.7) : _mm(0.25);

    return Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
  }

  Paint _thinPaint() => Paint()
    ..color = Colors.black
    ..strokeWidth = _mm(0.25)
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;

  void _drawRect(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final w = _d(e['w']);
    final h = _d(e['h']);
    final lineStyle = e['lineStyle'] as String? ?? 'solid';
    final paint = _elementPaint(e);

    if (lineStyle == 'solid') {
      canvas.drawRect(Rect.fromLTWH(_mm(x), _mm(y), _mm(w), _mm(h)), paint);
    } else {
      // Draw each edge as a styled line.
      _drawStyledLine(canvas, x, y, x + w, y, paint, lineStyle);
      _drawStyledLine(canvas, x + w, y, x + w, y + h, paint, lineStyle);
      _drawStyledLine(canvas, x + w, y + h, x, y + h, paint, lineStyle);
      _drawStyledLine(canvas, x, y + h, x, y, paint, lineStyle);
    }
  }

  void _drawCircle(Canvas canvas, Map<String, dynamic> e) {
    final cx = _d(e['cx']);
    final cy = _d(e['cy']);
    final r = _d(e['r']);
    final lineStyle = e['lineStyle'] as String? ?? 'solid';
    final paint = _elementPaint(e);

    if (lineStyle == 'solid') {
      canvas.drawCircle(_pt(cx, cy), _mm(r), paint);
    } else {
      _drawStyledCircle(canvas, cx, cy, r, paint, lineStyle);
    }
  }

  void _drawLine(Canvas canvas, Map<String, dynamic> e) {
    final x1 = _d(e['x1']);
    final y1 = _d(e['y1']);
    final x2 = _d(e['x2']);
    final y2 = _d(e['y2']);
    final lineStyle = e['lineStyle'] as String? ?? 'solid';
    final paint = _elementPaint(e);

    _drawStyledLine(canvas, x1, y1, x2, y2, paint, lineStyle);
  }

  // ── Styled line/circle helpers ─────────────────────────────

  /// Draw a line with dash/centerline pattern (coordinates in mm).
  void _drawStyledLine(
    Canvas canvas,
    double x1mm,
    double y1mm,
    double x2mm,
    double y2mm,
    Paint paint,
    String style,
  ) {
    final p1 = _pt(x1mm, y1mm);
    final p2 = _pt(x2mm, y2mm);

    if (style == 'solid') {
      canvas.drawLine(p1, p2, paint);
      return;
    }

    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final totalLen = math.sqrt(dx * dx + dy * dy);
    if (totalLen < 1) return;
    final ux = dx / totalLen;
    final uy = dy / totalLen;

    // Pattern lengths in pixels.
    final List<double> pattern;
    if (style == 'centerline') {
      // long-gap-short-gap
      pattern = [_mm(12), _mm(3), _mm(3), _mm(3)];
    } else {
      // dashed
      pattern = [_mm(6), _mm(3)];
    }

    double drawn = 0;
    int idx = 0;
    while (drawn < totalLen) {
      final seg = math.min(pattern[idx % pattern.length], totalLen - drawn);
      final isStroke = idx % 2 == 0;
      if (isStroke) {
        final sx = p1.dx + ux * drawn;
        final sy = p1.dy + uy * drawn;
        final ex = p1.dx + ux * (drawn + seg);
        final ey = p1.dy + uy * (drawn + seg);
        canvas.drawLine(Offset(sx, sy), Offset(ex, ey), paint);
      }
      drawn += seg;
      idx++;
    }
  }

  /// Approximate a styled circle by drawing short arcs.
  void _drawStyledCircle(
    Canvas canvas,
    double cxMm,
    double cyMm,
    double rMm,
    Paint paint,
    String style,
  ) {
    final circumference = 2 * math.pi * rMm; // mm
    final List<double> patternMm;
    if (style == 'centerline') {
      patternMm = [12, 3, 3, 3];
    } else {
      patternMm = [6, 3];
    }

    final cx = _mm(cxMm);
    final cy = _mm(cyMm);
    final r = _mm(rMm);
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    double drawnMm = 0;
    int idx = 0;
    while (drawnMm < circumference) {
      final segMm =
          math.min(patternMm[idx % patternMm.length], circumference - drawnMm);
      final isStroke = idx % 2 == 0;
      if (isStroke) {
        final startAngle = (drawnMm / circumference) * 2 * math.pi;
        final sweepAngle = (segMm / circumference) * 2 * math.pi;
        canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
      }
      drawnMm += segMm;
      idx++;
    }
  }

  // ── Dimensions ─────────────────────────────────────────────

  void _drawDimension(Canvas canvas, Map<String, dynamic> e) {
    final subtype = e['subtype'] as String? ?? '';
    switch (subtype) {
      case 'linear_h':
        _drawDimLinearH(canvas, e);
      case 'linear_v':
        _drawDimLinearV(canvas, e);
      case 'diameter':
        _drawDimDiameter(canvas, e);
    }
  }

  /// Horizontal dimension line.
  void _drawDimLinearH(Canvas canvas, Map<String, dynamic> e) {
    final x1 = _d(e['x1']);
    final x2 = _d(e['x2']);
    final y = _d(e['y']);
    final offset = _d(e['offset']);
    final value = e['value'] as String? ?? '';

    final dimY = y + offset;
    const gap = 1.0; // DIN gap from part edge
    const overshoot = 2.0;
    final sign = offset >= 0 ? 1.0 : -1.0;

    final thin = _thinPaint();

    // Extension lines: start at part edge + gap, end past dim line.
    canvas.drawLine(_pt(x1, y + gap * sign), _pt(x1, dimY + overshoot * sign), thin);
    canvas.drawLine(_pt(x2, y + gap * sign), _pt(x2, dimY + overshoot * sign), thin);

    canvas.drawLine(_pt(x1, dimY), _pt(x2, dimY), thin);
    _drawArrow(canvas, _pt(x1, dimY), _pt(x2, dimY), thin);
    _drawArrow(canvas, _pt(x2, dimY), _pt(x1, dimY), thin);

    // DIN: text above the dim line (reading bottom-up). Place 1.5mm above.
    final midX = (x1 + x2) / 2;
    _drawDimText(
      canvas,
      value,
      _pt(midX, dimY - 1.8),
      horizontal: true,
      opaque: false,
    );
  }

  /// Vertical dimension line.
  void _drawDimLinearV(Canvas canvas, Map<String, dynamic> e) {
    final y1 = _d(e['y1']);
    final y2 = _d(e['y2']);
    final x = _d(e['x']);
    final offset = _d(e['offset']);
    final value = e['value'] as String? ?? '';

    final dimX = x + offset;
    const gap = 1.0;
    const overshoot = 2.0;
    final sign = offset >= 0 ? 1.0 : -1.0;

    final thin = _thinPaint();

    canvas.drawLine(_pt(x + gap * sign, y1), _pt(dimX + overshoot * sign, y1), thin);
    canvas.drawLine(_pt(x + gap * sign, y2), _pt(dimX + overshoot * sign, y2), thin);

    canvas.drawLine(_pt(dimX, y1), _pt(dimX, y2), thin);
    _drawArrow(canvas, _pt(dimX, y1), _pt(dimX, y2), thin);
    _drawArrow(canvas, _pt(dimX, y2), _pt(dimX, y1), thin);

    // DIN vertical dim: text rotated, placed to LEFT of dim line.
    final midY = (y1 + y2) / 2;
    _drawDimText(
      canvas,
      value,
      _pt(dimX - 1.8, midY),
      horizontal: false,
      opaque: false,
    );
  }

  /// Diameter dimension.
  void _drawDimDiameter(Canvas canvas, Map<String, dynamic> e) {
    final cx = _d(e['cx']);
    final cy = _d(e['cy']);
    final r = _d(e['r']);
    final angle = _d(e['angle']) * math.pi / 180;
    final value = e['value'] as String? ?? '';

    final thin = _thinPaint();

    final dx = r * math.cos(angle);
    final dy = r * math.sin(angle);
    final p1 = _pt(cx - dx, cy - dy);
    final p2 = _pt(cx + dx, cy + dy);
    canvas.drawLine(p1, p2, thin);
    _drawArrow(canvas, p1, p2, thin);
    _drawArrow(canvas, p2, p1, thin);

    // Place text offset perpendicular to leader so it doesn't break the line
    // visually — small vertical offset looks cleaner than sitting on the line.
    final nx = -math.sin(angle) * 3.0; // 3mm perpendicular offset
    final ny = math.cos(angle) * 3.0;
    _drawDimText(
      canvas,
      value,
      _pt(cx + nx, cy + ny),
      horizontal: true,
      opaque: true,
    );
  }

  /// Draw a filled arrowhead at [tip] pointing toward [tip] from [from].
  /// DIN proportions: length ~3mm, half-width ~0.6mm (slim elongated).
  void _drawArrow(Canvas canvas, Offset tip, Offset from, Paint paint) {
    final arrowLen = _mm(3.2);
    final arrowHalfW = _mm(0.6);

    final dx = tip.dx - from.dx;
    final dy = tip.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;

    final bx = tip.dx - ux * arrowLen;
    final by = tip.dy - uy * arrowLen;
    final px = -uy * arrowHalfW;
    final py = ux * arrowHalfW;

    final path = ui.Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(bx + px, by + py)
      ..lineTo(bx - px, by - py)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  /// Draw dimension text.
  /// [opaque] = paint white rectangle behind text (used when text must break
  /// through geometry, e.g. diameter leader). When false, text is placed above
  /// the dim line so no background is needed.
  void _drawDimText(
    Canvas canvas,
    String text,
    Offset anchor, {
    required bool horizontal,
    bool opaque = false,
  }) {
    final fontSize = _mm(3.2);
    final textStyle = ui.TextStyle(
      color: Colors.black,
      fontSize: fontSize,
      fontFamily: 'sans-serif',
    );
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textAlign: TextAlign.center),
    )
      ..pushStyle(textStyle)
      ..addText(text);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 200));

    final tw = paragraph.longestLine;
    final th = paragraph.height;

    canvas.save();
    canvas.translate(anchor.dx, anchor.dy);

    if (!horizontal) {
      canvas.rotate(-math.pi / 2);
    }

    if (opaque) {
      final pad = _mm(0.8);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: tw + pad * 2,
          height: th + pad * 2,
        ),
        Paint()..color = Colors.white,
      );
    }

    // Text baseline sits at anchor; shift up by full height so text reads
    // ABOVE the anchor point (DIN: dim text above dim line).
    final dy = opaque ? -th / 2 : -th;
    canvas.drawParagraph(paragraph, Offset(-tw / 2, dy));
    canvas.restore();
  }

  // ── Notes ──────────────────────────────────────────────────

  void _drawNote(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final text = e['text'] as String? ?? '';

    final fontSize = _mm(3.2);
    final textStyle = ui.TextStyle(
      color: Colors.black,
      fontSize: fontSize,
      fontFamily: 'sans-serif',
    );
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textAlign: TextAlign.left),
    )
      ..pushStyle(textStyle)
      ..addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: _mm(100)));

    final origin = _pt(x, y - 3.2);

    // White background to prevent collision with dim lines / geometry.
    final pad = _mm(0.8);
    canvas.drawRect(
      Rect.fromLTWH(
        origin.dx - pad,
        origin.dy - pad * 0.3,
        paragraph.longestLine + pad * 2,
        paragraph.height + pad * 0.6,
      ),
      Paint()..color = Colors.white,
    );

    canvas.drawParagraph(paragraph, origin);
  }

  // ── Title block ────────────────────────────────────────────

  void _drawTitleBlock(Canvas canvas, Size size) {
    // DIN title block — bottom-right, inside the 5mm border margin.
    const margin = 5.0;
    const blockW = 120.0; // mm
    const blockH = 36.0; // mm
    final bx = data.sheetW - margin - blockW;
    final by = data.sheetH - margin - blockH;

    final outerPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = _mm(0.5)
      ..isAntiAlias = true;
    final borderPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = _mm(0.25)
      ..isAntiAlias = true;

    canvas.drawRect(
      Rect.fromLTWH(_mm(bx), _mm(by), _mm(blockW), _mm(blockH)),
      outerPaint,
    );

    // Row heights (mm): 4 rows of 9mm each = 36mm.
    const rowH = 9.0;
    // Column split: labels 40mm, values 80mm.
    const labelW = 40.0;

    // Horizontal dividers.
    for (int i = 1; i < 4; i++) {
      final ly = by + rowH * i;
      canvas.drawLine(_pt(bx, ly), _pt(bx + blockW, ly), borderPaint);
    }

    // Vertical divider.
    canvas.drawLine(
      _pt(bx + labelW, by),
      _pt(bx + labelW, by + blockH),
      borderPaint,
    );

    // Field data.
    final meta = data.meta;
    final fields = [
      ['Benennung', meta['title'] as String? ?? ''],
      ['Sachnr. / Werkstoff', '${meta['partNo'] ?? ''} / ${meta['material'] ?? ''}'],
      ['Maßstab / Toleranz', '${meta['scale'] ?? ''} / ${meta['tolerance'] ?? ''}'],
      ['Ersteller / Datum', '${meta['author'] ?? ''} / ${meta['date'] ?? ''}  Bl. ${meta['sheet'] ?? ''}'],
    ];

    for (int i = 0; i < fields.length; i++) {
      final ly = by + rowH * i;
      _drawCellText(
        canvas,
        fields[i][0],
        Rect.fromLTWH(_mm(bx + 1), _mm(ly + 1), _mm(labelW - 2), _mm(rowH - 2)),
        fontSize: _mm(2.5),
        bold: false,
      );
      _drawCellText(
        canvas,
        fields[i][1],
        Rect.fromLTWH(
          _mm(bx + labelW + 1),
          _mm(ly + 1),
          _mm(blockW - labelW - 2),
          _mm(rowH - 2),
        ),
        fontSize: _mm(3.2),
        bold: false,
      );
    }
  }

  void _drawCellText(
    Canvas canvas,
    String text,
    Rect cellRect, {
    required double fontSize,
    required bool bold,
  }) {
    final textStyle = ui.TextStyle(
      color: Colors.black,
      fontSize: fontSize,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontFamily: 'sans-serif',
    );
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.left,
        maxLines: 1,
        ellipsis: '...',
      ),
    )
      ..pushStyle(textStyle)
      ..addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: cellRect.width));

    // Vertically center in cell.
    final dy = (cellRect.height - paragraph.height) / 2;
    canvas.drawParagraph(
      paragraph,
      Offset(cellRect.left, cellRect.top + dy),
    );
  }

  @override
  bool shouldRepaint(covariant TechDrawPainter oldDelegate) =>
      data != oldDelegate.data || scale != oldDelegate.scale;

  // Shorthand matching TechDrawData._d
  static double _d(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }
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
