// lib/widgets/technical_drawing_svg_export.dart
//
// Converts technical_drawing JSON artifacts into standalone SVG strings
// so users can download their drawings in a universally supported format.

import 'dart:convert';
import 'dart:math' as math;

/// Converts a technical_drawing JSON string into an SVG document string.
///
/// Returns null if the JSON cannot be parsed.
String? technicalDrawingToSvg(String jsonString) {
  final Map<String, dynamic> data;
  try {
    final parsed = jsonDecode(jsonString.trim());
    if (parsed is! Map<String, dynamic>) return null;
    data = parsed;
  } catch (_) {
    return null;
  }

  final meta = (data['meta'] as Map<String, dynamic>?) ?? {};
  final rawElems = data['elements'] as List? ?? [];
  final elements = rawElems.whereType<Map<String, dynamic>>().toList();

  // Derive sheet size (same rules as renderer).
  double maxX = 297.0, maxY = 210.0;
  for (final e in elements) {
    final t = e['type'] as String? ?? '';
    switch (t) {
      case 'rect':
        maxX = math.max(maxX, _d(e['x']) + _d(e['w']));
        maxY = math.max(maxY, _d(e['y']) + _d(e['h']));
      case 'circle':
        maxX = math.max(maxX, _d(e['cx']) + _d(e['r']));
        maxY = math.max(maxY, _d(e['cy']) + _d(e['r']));
      case 'line':
        maxX = math.max(maxX, math.max(_d(e['x1']), _d(e['x2'])));
        maxY = math.max(maxY, math.max(_d(e['y1']), _d(e['y2'])));
      case 'dimension':
        final sub = e['subtype'] as String? ?? '';
        if (sub == 'linear_h') {
          maxX = math.max(maxX, math.max(_d(e['x1']), _d(e['x2'])));
          maxY = math.max(maxY, _d(e['y']) + _d(e['offset']).abs() + 10);
        } else if (sub == 'linear_v') {
          maxX = math.max(maxX, _d(e['x']) + _d(e['offset']).abs() + 10);
          maxY = math.max(maxY, math.max(_d(e['y1']), _d(e['y2'])));
        }
      case 'note':
        maxX = math.max(maxX, _d(e['x']) + 30);
        maxY = math.max(maxY, _d(e['y']));
    }
  }

  const titleBlockH = 40.0;
  const margin = 25.0;
  final sheetW = maxX + margin + 10;
  final sheetH = maxY + margin + titleBlockH;

  final sb = StringBuffer()
    ..writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'viewBox="0 0 ${_f(sheetW)} ${_f(sheetH)}" '
      'width="${_f(sheetW)}mm" height="${_f(sheetH)}mm">',
    )
    ..writeln('<rect width="${_f(sheetW)}" height="${_f(sheetH)}" fill="white"/>')
    // Border frame (5mm margin).
    ..writeln(
      '<rect x="5" y="5" width="${_f(sheetW - 10)}" height="${_f(sheetH - 10)}" '
      'fill="none" stroke="black" stroke-width="0.5"/>',
    );

  // Draw priority (match widget renderer): construction → thin → thick →
  // dimensions → notes last so overlays read correctly.
  final ordered = [...elements]..sort(
      (a, b) => _priority(a).compareTo(_priority(b)),
    );
  for (final e in ordered) {
    _writeElement(sb, e);
  }

  // Title block (DIN — bottom right).
  _writeTitleBlock(sb, meta, sheetW, sheetH);

  sb.writeln('</svg>');
  return sb.toString();
}

void _writeElement(StringBuffer sb, Map<String, dynamic> e) {
  final type = e['type'] as String? ?? '';
  switch (type) {
    case 'rect':
      _writeRect(sb, e);
    case 'circle':
      _writeCircle(sb, e);
    case 'line':
      _writeLine(sb, e);
    case 'dimension':
      _writeDimension(sb, e);
    case 'note':
      _writeNote(sb, e);
  }
}

String _strokeWidth(String weight) =>
    weight == 'thick' ? '0.7' : '0.25';

String? _dashArray(String lineStyle) {
  if (lineStyle == 'dashed') return '6 3';
  if (lineStyle == 'centerline') return '12 3 3 3';
  return null;
}

String _strokeAttrs(Map<String, dynamic> e) {
  final weight = e['weight'] as String? ?? 'thin';
  final lineStyle = e['lineStyle'] as String? ?? 'solid';
  final dash = _dashArray(lineStyle);
  final sw = _strokeWidth(weight);
  final base = 'stroke="black" stroke-width="$sw" fill="none"';
  return dash == null ? base : '$base stroke-dasharray="$dash"';
}

void _writeRect(StringBuffer sb, Map<String, dynamic> e) {
  sb.writeln(
    '<rect x="${_f(_d(e['x']))}" y="${_f(_d(e['y']))}" '
    'width="${_f(_d(e['w']))}" height="${_f(_d(e['h']))}" '
    '${_strokeAttrs(e)}/>',
  );
}

void _writeCircle(StringBuffer sb, Map<String, dynamic> e) {
  sb.writeln(
    '<circle cx="${_f(_d(e['cx']))}" cy="${_f(_d(e['cy']))}" '
    'r="${_f(_d(e['r']))}" ${_strokeAttrs(e)}/>',
  );
}

void _writeLine(StringBuffer sb, Map<String, dynamic> e) {
  sb.writeln(
    '<line x1="${_f(_d(e['x1']))}" y1="${_f(_d(e['y1']))}" '
    'x2="${_f(_d(e['x2']))}" y2="${_f(_d(e['y2']))}" '
    '${_strokeAttrs(e)}/>',
  );
}

void _writeDimension(StringBuffer sb, Map<String, dynamic> e) {
  final subtype = e['subtype'] as String? ?? '';
  final value = e['value'] as String? ?? '';
  const thinStroke = 'stroke="black" stroke-width="0.25" fill="none"';

  switch (subtype) {
    case 'linear_h':
      {
        final x1 = _d(e['x1']);
        final x2 = _d(e['x2']);
        final y = _d(e['y']);
        final offset = _d(e['offset']);
        final dimY = y + offset;
        final sign = offset >= 0 ? 1.0 : -1.0;
        final extStart = y + 1.0 * sign; // DIN gap from part edge
        final extEnd = dimY + 2.0 * sign;
        sb
          ..writeln(
            '<line x1="${_f(x1)}" y1="${_f(extStart)}" x2="${_f(x1)}" y2="${_f(extEnd)}" $thinStroke/>',
          )
          ..writeln(
            '<line x1="${_f(x2)}" y1="${_f(extStart)}" x2="${_f(x2)}" y2="${_f(extEnd)}" $thinStroke/>',
          )
          ..writeln(
            '<line x1="${_f(x1)}" y1="${_f(dimY)}" x2="${_f(x2)}" y2="${_f(dimY)}" $thinStroke/>',
          );
        _writeArrow(sb, x1, dimY, x2, dimY);
        _writeArrow(sb, x2, dimY, x1, dimY);
        final midX = (x1 + x2) / 2;
        _writeDimTextAbove(sb, value, midX, dimY - 1.8, rotate: false);
      }
    case 'linear_v':
      {
        final y1 = _d(e['y1']);
        final y2 = _d(e['y2']);
        final x = _d(e['x']);
        final offset = _d(e['offset']);
        final dimX = x + offset;
        final sign = offset >= 0 ? 1.0 : -1.0;
        final extStart = x + 1.0 * sign;
        final extEnd = dimX + 2.0 * sign;
        sb
          ..writeln(
            '<line x1="${_f(extStart)}" y1="${_f(y1)}" x2="${_f(extEnd)}" y2="${_f(y1)}" $thinStroke/>',
          )
          ..writeln(
            '<line x1="${_f(extStart)}" y1="${_f(y2)}" x2="${_f(extEnd)}" y2="${_f(y2)}" $thinStroke/>',
          )
          ..writeln(
            '<line x1="${_f(dimX)}" y1="${_f(y1)}" x2="${_f(dimX)}" y2="${_f(y2)}" $thinStroke/>',
          );
        _writeArrow(sb, dimX, y1, dimX, y2);
        _writeArrow(sb, dimX, y2, dimX, y1);
        final midY = (y1 + y2) / 2;
        _writeDimTextAbove(sb, value, dimX - 1.8, midY, rotate: true);
      }
    case 'diameter':
      {
        final cx = _d(e['cx']);
        final cy = _d(e['cy']);
        final r = _d(e['r']);
        final angle = _d(e['angle']) * math.pi / 180;
        final dx = r * math.cos(angle);
        final dy = r * math.sin(angle);
        final p1x = cx - dx;
        final p1y = cy - dy;
        final p2x = cx + dx;
        final p2y = cy + dy;
        sb.writeln(
          '<line x1="${_f(p1x)}" y1="${_f(p1y)}" x2="${_f(p2x)}" y2="${_f(p2y)}" $thinStroke/>',
        );
        _writeArrow(sb, p1x, p1y, p2x, p2y);
        _writeArrow(sb, p2x, p2y, p1x, p1y);
        // Offset text perpendicular to leader.
        final tx = cx + -math.sin(angle) * 3.0;
        final ty = cy + math.cos(angle) * 3.0;
        _writeDimText(sb, value, tx, ty, rotate: false);
      }
  }
}

void _writeArrow(
  StringBuffer sb,
  double tipX,
  double tipY,
  double fromX,
  double fromY,
) {
  const arrowLen = 3.2;
  const arrowHalfW = 0.6;
  final dx = tipX - fromX;
  final dy = tipY - fromY;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1) return;
  final ux = dx / len;
  final uy = dy / len;
  final bx = tipX - ux * arrowLen;
  final by = tipY - uy * arrowLen;
  final px = -uy * arrowHalfW;
  final py = ux * arrowHalfW;
  sb.writeln(
    '<polygon points="${_f(tipX)},${_f(tipY)} '
    '${_f(bx + px)},${_f(by + py)} '
    '${_f(bx - px)},${_f(by - py)}" fill="black"/>',
  );
}

/// Text with opaque white background — used when text must break through
/// geometry (e.g. diameter leader).
void _writeDimText(
  StringBuffer sb,
  String value,
  double cx,
  double cy, {
  required bool rotate,
}) {
  final escaped = _escapeXml(value);
  final estW = value.length * 2.0;
  const h = 4.0;
  if (rotate) {
    sb
      ..writeln(
        '<rect x="${_f(cx - h / 2)}" y="${_f(cy - estW / 2)}" '
        'width="${_f(h)}" height="${_f(estW)}" fill="white"/>',
      )
      ..writeln(
        '<text x="${_f(cx)}" y="${_f(cy)}" font-family="sans-serif" '
        'font-size="3.2" text-anchor="middle" dominant-baseline="middle" '
        'transform="rotate(-90 ${_f(cx)} ${_f(cy)})">$escaped</text>',
      );
  } else {
    sb
      ..writeln(
        '<rect x="${_f(cx - estW / 2)}" y="${_f(cy - h / 2)}" '
        'width="${_f(estW)}" height="${_f(h)}" fill="white"/>',
      )
      ..writeln(
        '<text x="${_f(cx)}" y="${_f(cy)}" font-family="sans-serif" '
        'font-size="3.2" text-anchor="middle" dominant-baseline="middle">'
        '$escaped</text>',
      );
  }
}

/// DIN-style dim text: placed ABOVE the dim line, no background needed since
/// line does not cross text.
void _writeDimTextAbove(
  StringBuffer sb,
  String value,
  double anchorX,
  double anchorY, {
  required bool rotate,
}) {
  final escaped = _escapeXml(value);
  if (rotate) {
    sb.writeln(
      '<text x="${_f(anchorX)}" y="${_f(anchorY)}" font-family="sans-serif" '
      'font-size="3.2" text-anchor="middle" dominant-baseline="alphabetic" '
      'transform="rotate(-90 ${_f(anchorX)} ${_f(anchorY)})">$escaped</text>',
    );
  } else {
    sb.writeln(
      '<text x="${_f(anchorX)}" y="${_f(anchorY)}" font-family="sans-serif" '
      'font-size="3.2" text-anchor="middle" dominant-baseline="alphabetic">'
      '$escaped</text>',
    );
  }
}

void _writeNote(StringBuffer sb, Map<String, dynamic> e) {
  final x = _d(e['x']);
  final y = _d(e['y']);
  final text = _escapeXml(e['text'] as String? ?? '');
  // Rough width estimate (3.2mm font ≈ 1.9mm/char).
  final estW = text.length * 1.9;
  const h = 4.0;
  sb
    ..writeln(
      '<rect x="${_f(x - 0.8)}" y="${_f(y - h + 0.6)}" '
      'width="${_f(estW + 1.6)}" height="${_f(h)}" fill="white"/>',
    )
    ..writeln(
      '<text x="${_f(x)}" y="${_f(y)}" font-family="sans-serif" '
      'font-size="3.2" fill="black">$text</text>',
    );
}

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

void _writeTitleBlock(
  StringBuffer sb,
  Map<String, dynamic> meta,
  double sheetW,
  double sheetH,
) {
  const margin = 5.0;
  const blockW = 120.0;
  const blockH = 36.0;
  final bx = sheetW - margin - blockW;
  final by = sheetH - margin - blockH;
  const rowH = 9.0;
  const labelW = 40.0;
  const border = 'stroke="black" stroke-width="0.35" fill="none"';

  // Outer rect + grid.
  sb.writeln(
    '<rect x="${_f(bx)}" y="${_f(by)}" width="${_f(blockW)}" height="${_f(blockH)}" $border/>',
  );
  for (int i = 1; i < 4; i++) {
    final ly = by + rowH * i;
    sb.writeln(
      '<line x1="${_f(bx)}" y1="${_f(ly)}" x2="${_f(bx + blockW)}" y2="${_f(ly)}" $border/>',
    );
  }
  sb.writeln(
    '<line x1="${_f(bx + labelW)}" y1="${_f(by)}" x2="${_f(bx + labelW)}" y2="${_f(by + blockH)}" $border/>',
  );

  final fields = [
    ['Benennung', meta['title']?.toString() ?? ''],
    ['Sachnr. / Werkstoff', '${meta['partNo'] ?? ''} / ${meta['material'] ?? ''}'],
    ['Maßstab / Toleranz', '${meta['scale'] ?? ''} / ${meta['tolerance'] ?? ''}'],
    [
      'Ersteller / Datum',
      '${meta['author'] ?? ''} / ${meta['date'] ?? ''}  Bl. ${meta['sheet'] ?? ''}',
    ],
  ];

  for (int i = 0; i < fields.length; i++) {
    final ly = by + rowH * i + rowH / 2;
    sb.writeln(
      '<text x="${_f(bx + 1)}" y="${_f(ly)}" font-family="sans-serif" '
      'font-size="2.5" dominant-baseline="middle">${_escapeXml(fields[i][0])}</text>',
    );
    sb.writeln(
      '<text x="${_f(bx + labelW + 1)}" y="${_f(ly)}" font-family="sans-serif" '
      'font-size="3.2" dominant-baseline="middle">'
      '${_escapeXml(fields[i][1])}</text>',
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}

String _f(double v) {
  if (v == v.truncateToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
