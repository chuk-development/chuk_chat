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
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            boundaryMargin: const EdgeInsets.all(80),
            child: CustomPaint(
              size: Size(paintW, paintH),
              painter: TechDrawPainter(data: data, scale: scale),
            ),
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
      ..strokeWidth = _mm(0.5);
    canvas.drawRect(
      Rect.fromLTRB(_mm(m), _mm(m), size.width - _mm(m), size.height - _mm(m)),
      borderPaint,
    );
  }

  // ── Elements ───────────────────────────────────────────────

  void _drawElements(Canvas canvas) {
    for (final e in data.elements) {
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
    final lineStyle = e['lineStyle'] as String? ?? 'solid';
    final strokeW = weight == 'thick' ? _mm(0.7) : _mm(0.25);

    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW;

    if (lineStyle == 'dashed') {
      // 6mm dash, 3mm gap — approximated via path effect not available in
      // canvas API directly; we draw dashed paths manually where needed.
      // For shapes we fall back to a visual approximation.
    } else if (lineStyle == 'centerline') {
      // 12-3-3-3 pattern — same approach.
    }

    return paint;
  }

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

    final dimY = y + offset; // Y of the dimension line
    final extOvershoot = 2.0; // mm beyond dimension line

    final thinPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = _mm(0.25);

    // Extension lines (from part edge to dimension line + overshoot).
    final extEnd = offset > 0 ? dimY + extOvershoot : dimY - extOvershoot;
    canvas.drawLine(_pt(x1, y), _pt(x1, extEnd), thinPaint);
    canvas.drawLine(_pt(x2, y), _pt(x2, extEnd), thinPaint);

    // Dimension line.
    canvas.drawLine(_pt(x1, dimY), _pt(x2, dimY), thinPaint);

    // Arrows.
    _drawArrow(canvas, _pt(x1, dimY), _pt(x2, dimY), thinPaint);
    _drawArrow(canvas, _pt(x2, dimY), _pt(x1, dimY), thinPaint);

    // Dimension text centered on line.
    final midX = (x1 + x2) / 2;
    _drawDimText(canvas, value, _pt(midX, dimY), horizontal: true);
  }

  /// Vertical dimension line.
  void _drawDimLinearV(Canvas canvas, Map<String, dynamic> e) {
    final y1 = _d(e['y1']);
    final y2 = _d(e['y2']);
    final x = _d(e['x']);
    final offset = _d(e['offset']);
    final value = e['value'] as String? ?? '';

    final dimX = x + offset;
    final extOvershoot = 2.0;

    final thinPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = _mm(0.25);

    // Extension lines.
    final extEnd = offset > 0 ? dimX + extOvershoot : dimX - extOvershoot;
    canvas.drawLine(_pt(x, y1), _pt(extEnd, y1), thinPaint);
    canvas.drawLine(_pt(x, y2), _pt(extEnd, y2), thinPaint);

    // Dimension line.
    canvas.drawLine(_pt(dimX, y1), _pt(dimX, y2), thinPaint);

    // Arrows.
    _drawArrow(canvas, _pt(dimX, y1), _pt(dimX, y2), thinPaint);
    _drawArrow(canvas, _pt(dimX, y2), _pt(dimX, y1), thinPaint);

    // Dimension text centered on line, rotated 90 degrees.
    final midY = (y1 + y2) / 2;
    _drawDimText(canvas, value, _pt(dimX, midY), horizontal: false);
  }

  /// Diameter dimension.
  void _drawDimDiameter(Canvas canvas, Map<String, dynamic> e) {
    final cx = _d(e['cx']);
    final cy = _d(e['cy']);
    final r = _d(e['r']);
    final angle = _d(e['angle']) * math.pi / 180;
    final value = e['value'] as String? ?? '';

    final thinPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = _mm(0.25);

    // Leader line through center at given angle.
    final dx = r * math.cos(angle);
    final dy = r * math.sin(angle);
    final p1 = _pt(cx - dx, cy - dy);
    final p2 = _pt(cx + dx, cy + dy);
    canvas.drawLine(p1, p2, thinPaint);

    // Arrows at both ends.
    _drawArrow(canvas, p1, p2, thinPaint);
    _drawArrow(canvas, p2, p1, thinPaint);

    // Text at the midpoint (center).
    _drawDimText(canvas, value, _pt(cx, cy), horizontal: true);
  }

  /// Draw a filled arrowhead at [tip] pointing toward [tip] from [from].
  void _drawArrow(Canvas canvas, Offset tip, Offset from, Paint paint) {
    final arrowLen = _mm(3.0);
    final arrowHalfW = _mm(0.5);

    final dx = tip.dx - from.dx;
    final dy = tip.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;

    // Base of arrow.
    final bx = tip.dx - ux * arrowLen;
    final by = tip.dy - uy * arrowLen;

    // Perpendicular.
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
        ..style = PaintingStyle.fill,
    );
  }

  /// Draw dimension text with white background clip.
  void _drawDimText(
    Canvas canvas,
    String text,
    Offset center, {
    required bool horizontal,
  }) {
    final fontSize = _mm(3.5);
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
    canvas.translate(center.dx, center.dy);

    if (!horizontal) {
      canvas.rotate(-math.pi / 2);
    }

    // White background behind text.
    final pad = _mm(0.8);
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: tw + pad * 2, height: th + pad * 2),
      Paint()..color = Colors.white,
    );

    canvas.drawParagraph(paragraph, Offset(-tw / 2, -th / 2));
    canvas.restore();
  }

  // ── Notes ──────────────────────────────────────────────────

  void _drawNote(Canvas canvas, Map<String, dynamic> e) {
    final x = _d(e['x']);
    final y = _d(e['y']);
    final text = e['text'] as String? ?? '';

    final fontSize = _mm(3.5);
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
      ..layout(ui.ParagraphConstraints(width: _mm(80)));

    canvas.drawParagraph(paragraph, _pt(x, y - 3.5));
  }

  // ── Title block ────────────────────────────────────────────

  void _drawTitleBlock(Canvas canvas, Size size) {
    // DIN title block — bottom-right, inside the 5mm border margin.
    const margin = 5.0;
    const blockW = 120.0; // mm
    const blockH = 36.0; // mm
    final bx = data.sheetW - margin - blockW;
    final by = data.sheetH - margin - blockH;

    final borderPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = _mm(0.35);

    // Outer rect.
    canvas.drawRect(
      Rect.fromLTWH(_mm(bx), _mm(by), _mm(blockW), _mm(blockH)),
      borderPaint,
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
        fontSize: _mm(3.5),
        bold: true,
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
