// lib/widgets/excalidraw_svg_export.dart
//
// Converts an Excalidraw scene JSON string into a stand-alone SVG document.
// Mirrors the element subset supported by [ExcalidrawWidget]:
//   rectangle, ellipse, diamond, line, arrow, text, freedraw, frame.
//
// The output is intentionally plain (no rough.js hand-drawn jitter) — the
// `.excalidraw` file itself is downloadable separately for perfect fidelity.

import 'dart:convert';
import 'dart:math' as math;

String? excalidrawToSvg(String jsonString) {
  final trimmed = jsonString.trim();
  if (trimmed.isEmpty) return null;
  Map<String, dynamic> parsed;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;
    parsed = decoded;
  } catch (_) {
    return null;
  }

  final rawElements = parsed['elements'];
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
  if (elements.isEmpty) return null;

  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = double.negativeInfinity;
  double maxY = double.negativeInfinity;

  for (final e in elements) {
    final b = _bounds(e);
    if (b == null) continue;
    if (b[0] < minX) minX = b[0];
    if (b[1] < minY) minY = b[1];
    if (b[2] > maxX) maxX = b[2];
    if (b[3] > maxY) maxY = b[3];
  }
  if (!minX.isFinite) {
    minX = 0;
    minY = 0;
    maxX = 400;
    maxY = 300;
  }

  const pad = 16.0;
  final viewX = minX - pad;
  final viewY = minY - pad;
  final viewW = (maxX - minX) + pad * 2;
  final viewH = (maxY - minY) + pad * 2;

  final appState = parsed['appState'];
  final bg = appState is Map
      ? appState['viewBackgroundColor']?.toString() ?? '#ffffff'
      : '#ffffff';

  final buf = StringBuffer();
  buf.writeln(
    '<?xml version="1.0" encoding="UTF-8" standalone="no"?>',
  );
  buf.writeln(
    '<svg xmlns="http://www.w3.org/2000/svg" '
    'viewBox="${_fmt(viewX)} ${_fmt(viewY)} ${_fmt(viewW)} ${_fmt(viewH)}" '
    'width="${_fmt(viewW)}" height="${_fmt(viewH)}">',
  );
  buf.writeln(
    '<rect x="${_fmt(viewX)}" y="${_fmt(viewY)}" '
    'width="${_fmt(viewW)}" height="${_fmt(viewH)}" '
    'fill="${_escapeAttr(bg)}"/>',
  );

  for (final e in elements) {
    _emitElement(buf, e);
  }

  buf.writeln('</svg>');
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Bounds
// ---------------------------------------------------------------------------

List<double>? _bounds(Map<String, dynamic> e) {
  final x = _d(e['x']);
  final y = _d(e['y']);
  final w = _d(e['width']);
  final h = _d(e['height']);
  final type = e['type']?.toString();
  final angle = _d(e['angle']);

  // line / arrow / freedraw: walk the points array for a tight AABB since
  // width/height only span the start/end extent and miss zig-zag waypoints.
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
          final rotated = _rotate(px, py, x + w / 2, y + h / 2, angle);
          if (rotated[0] < minX) minX = rotated[0];
          if (rotated[1] < minY) minY = rotated[1];
          if (rotated[0] > maxX) maxX = rotated[0];
          if (rotated[1] > maxY) maxY = rotated[1];
        }
      }
      if (minX.isFinite) return [minX, minY, maxX, maxY];
    }
  }

  if (w == 0 && h == 0 && type != 'text') return null;
  if (angle == 0) {
    return [x, y, x + w, y + h];
  }
  final cx = x + w / 2;
  final cy = y + h / 2;
  final corners = [
    [x, y],
    [x + w, y],
    [x + w, y + h],
    [x, y + h],
  ];
  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = double.negativeInfinity;
  double maxY = double.negativeInfinity;
  for (final c in corners) {
    final r = _rotate(c[0], c[1], cx, cy, angle);
    if (r[0] < minX) minX = r[0];
    if (r[1] < minY) minY = r[1];
    if (r[0] > maxX) maxX = r[0];
    if (r[1] > maxY) maxY = r[1];
  }
  return [minX, minY, maxX, maxY];
}

List<double> _rotate(double x, double y, double cx, double cy, double angle) {
  if (angle == 0) return [x, y];
  final dx = x - cx;
  final dy = y - cy;
  return [
    dx * math.cos(angle) - dy * math.sin(angle) + cx,
    dx * math.sin(angle) + dy * math.cos(angle) + cy,
  ];
}

// ---------------------------------------------------------------------------
// Per-element emitters
// ---------------------------------------------------------------------------

void _emitElement(StringBuffer buf, Map<String, dynamic> e) {
  final type = e['type']?.toString() ?? '';
  final angle = _d(e['angle']);
  final x = _d(e['x']);
  final y = _d(e['y']);
  final w = _d(e['width']);
  final h = _d(e['height']);
  final opacity = e.containsKey('opacity')
      ? (_d(e['opacity']) / 100.0).clamp(0.0, 1.0)
      : 1.0;

  final transforms = <String>[];
  if (angle != 0) {
    final cx = x + w / 2;
    final cy = y + h / 2;
    final deg = angle * 180.0 / math.pi;
    transforms.add('rotate(${_fmt(deg)} ${_fmt(cx)} ${_fmt(cy)})');
  }
  final groupAttrs = <String>[];
  if (transforms.isNotEmpty) {
    groupAttrs.add('transform="${transforms.join(' ')}"');
  }
  if (opacity < 1.0) {
    groupAttrs.add('opacity="${_fmt(opacity)}"');
  }
  if (groupAttrs.isNotEmpty) {
    buf.writeln('<g ${groupAttrs.join(' ')}>');
  }

  switch (type) {
    case 'rectangle':
      _emitRectangle(buf, e, x, y, w, h);
    case 'ellipse':
      _emitEllipse(buf, e, x, y, w, h);
    case 'diamond':
      _emitDiamond(buf, e, x, y, w, h);
    case 'line':
      _emitLine(buf, e, x, y, arrow: false);
    case 'arrow':
      _emitLine(buf, e, x, y, arrow: true);
    case 'text':
      _emitText(buf, e, x, y, w, h);
    case 'freedraw':
      _emitFreedraw(buf, e, x, y);
    case 'frame':
    case 'magicframe':
      _emitFrame(buf, e, x, y, w, h);
  }

  if (groupAttrs.isNotEmpty) {
    buf.writeln('</g>');
  }
}

void _emitRectangle(
  StringBuffer buf,
  Map<String, dynamic> e,
  double x,
  double y,
  double w,
  double h,
) {
  final stroke = _resolveStroke(e);
  final fill = _resolveFill(e);
  final rx = e['roundness'] is Map
      ? math.min(math.min(w.abs(), h.abs()) / 4, 32.0)
      : 0.0;
  final parts = <String>[
    'x="${_fmt(x)}"',
    'y="${_fmt(y)}"',
    'width="${_fmt(w)}"',
    'height="${_fmt(h)}"',
    if (rx > 0) 'rx="${_fmt(rx)}" ry="${_fmt(rx)}"',
    'fill="${fill ?? 'none'}"',
    'stroke="${stroke.color}"',
    'stroke-width="${_fmt(stroke.width)}"',
    if (stroke.dash != null) 'stroke-dasharray="${stroke.dash}"',
    'stroke-linecap="round"',
    'stroke-linejoin="round"',
  ];
  buf.writeln('<rect ${parts.join(' ')}/>');
}

void _emitEllipse(
  StringBuffer buf,
  Map<String, dynamic> e,
  double x,
  double y,
  double w,
  double h,
) {
  final stroke = _resolveStroke(e);
  final fill = _resolveFill(e);
  final cx = x + w / 2;
  final cy = y + h / 2;
  final rx = (w / 2).abs();
  final ry = (h / 2).abs();
  final parts = <String>[
    'cx="${_fmt(cx)}"',
    'cy="${_fmt(cy)}"',
    'rx="${_fmt(rx)}"',
    'ry="${_fmt(ry)}"',
    'fill="${fill ?? 'none'}"',
    'stroke="${stroke.color}"',
    'stroke-width="${_fmt(stroke.width)}"',
    if (stroke.dash != null) 'stroke-dasharray="${stroke.dash}"',
  ];
  buf.writeln('<ellipse ${parts.join(' ')}/>');
}

void _emitDiamond(
  StringBuffer buf,
  Map<String, dynamic> e,
  double x,
  double y,
  double w,
  double h,
) {
  final stroke = _resolveStroke(e);
  final fill = _resolveFill(e);
  final points =
      '${_fmt(x + w / 2)},${_fmt(y)} '
      '${_fmt(x + w)},${_fmt(y + h / 2)} '
      '${_fmt(x + w / 2)},${_fmt(y + h)} '
      '${_fmt(x)},${_fmt(y + h / 2)}';
  final parts = <String>[
    'points="$points"',
    'fill="${fill ?? 'none'}"',
    'stroke="${stroke.color}"',
    'stroke-width="${_fmt(stroke.width)}"',
    if (stroke.dash != null) 'stroke-dasharray="${stroke.dash}"',
    'stroke-linecap="round"',
    'stroke-linejoin="round"',
  ];
  buf.writeln('<polygon ${parts.join(' ')}/>');
}

void _emitLine(
  StringBuffer buf,
  Map<String, dynamic> e,
  double x,
  double y, {
  required bool arrow,
}) {
  final stroke = _resolveStroke(e);
  final rawPoints = e['points'];
  final pts = <List<double>>[];
  if (rawPoints is List) {
    for (final p in rawPoints) {
      if (p is List && p.length >= 2) {
        pts.add([x + _d(p[0]), y + _d(p[1])]);
      }
    }
  }
  if (pts.length < 2) {
    pts.add([x, y]);
    pts.add([x + _d(e['width']), y + _d(e['height'])]);
  }
  final coords = pts.map((p) => '${_fmt(p[0])},${_fmt(p[1])}').join(' ');
  final parts = <String>[
    'points="$coords"',
    'fill="none"',
    'stroke="${stroke.color}"',
    'stroke-width="${_fmt(stroke.width)}"',
    if (stroke.dash != null) 'stroke-dasharray="${stroke.dash}"',
    'stroke-linecap="round"',
    'stroke-linejoin="round"',
  ];
  buf.writeln('<polyline ${parts.join(' ')}/>');

  if (arrow) {
    final endHead = e['endArrowhead']?.toString() ?? 'arrow';
    final startHead = e['startArrowhead']?.toString();
    if (endHead.isNotEmpty && endHead != 'null') {
      _emitArrowhead(buf, pts[pts.length - 2], pts.last, stroke, endHead);
    }
    if (startHead != null && startHead != 'null' && startHead.isNotEmpty) {
      _emitArrowhead(buf, pts[1], pts.first, stroke, startHead);
    }
  }
}

void _emitArrowhead(
  StringBuffer buf,
  List<double> from,
  List<double> tip,
  _Stroke stroke,
  String shape,
) {
  final dx = tip[0] - from[0];
  final dy = tip[1] - from[1];
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 0.5) return;
  final ux = dx / len;
  final uy = dy / len;
  final headLen = math.max(14.0, stroke.width * 3.5);
  final halfW = headLen * 0.4;
  final bx = tip[0] - ux * headLen;
  final by = tip[1] - uy * headLen;
  final px = -uy * halfW;
  final py = ux * halfW;

  switch (shape) {
    case 'triangle':
      buf.writeln(
        '<polygon points="${_fmt(tip[0])},${_fmt(tip[1])} '
        '${_fmt(bx + px)},${_fmt(by + py)} '
        '${_fmt(bx - px)},${_fmt(by - py)}" fill="${stroke.color}"/>',
      );
    case 'dot':
      buf.writeln(
        '<circle cx="${_fmt(tip[0])}" cy="${_fmt(tip[1])}" '
        'r="${_fmt(headLen * 0.4)}" fill="${stroke.color}"/>',
      );
    case 'bar':
      buf.writeln(
        '<line x1="${_fmt(tip[0] + px)}" y1="${_fmt(tip[1] + py)}" '
        'x2="${_fmt(tip[0] - px)}" y2="${_fmt(tip[1] - py)}" '
        'stroke="${stroke.color}" stroke-width="${_fmt(stroke.width)}" '
        'stroke-linecap="round"/>',
      );
    case 'arrow':
    default:
      buf.writeln(
        '<line x1="${_fmt(tip[0])}" y1="${_fmt(tip[1])}" '
        'x2="${_fmt(bx + px)}" y2="${_fmt(by + py)}" '
        'stroke="${stroke.color}" stroke-width="${_fmt(stroke.width)}" '
        'stroke-linecap="round"/>',
      );
      buf.writeln(
        '<line x1="${_fmt(tip[0])}" y1="${_fmt(tip[1])}" '
        'x2="${_fmt(bx - px)}" y2="${_fmt(by - py)}" '
        'stroke="${stroke.color}" stroke-width="${_fmt(stroke.width)}" '
        'stroke-linecap="round"/>',
      );
  }
}

void _emitText(
  StringBuffer buf,
  Map<String, dynamic> e,
  double x,
  double y,
  double w,
  double h,
) {
  final text = e['text']?.toString() ?? '';
  if (text.isEmpty) return;
  final fontSizeRaw = _d(e['fontSize']);
  final fontSize = fontSizeRaw > 0 ? fontSizeRaw : 20.0;
  final color = _resolveStroke(e).color;
  final align = switch (e['textAlign']?.toString()) {
    'center' => 'middle',
    'right' => 'end',
    _ => 'start',
  };
  final anchorX = switch (align) {
    'middle' => x + w / 2,
    'end' => x + w,
    _ => x,
  };
  final family = _svgFontFamily(e['fontFamily']);

  final lines = const LineSplitter().convert(text);
  final lineHeight = fontSize * 1.25;
  final totalHeight = lineHeight * lines.length;
  // Align vertically within the box, default top.
  final verticalAlign = e['verticalAlign']?.toString();
  final double firstBaselineY = switch (verticalAlign) {
    'middle' =>
      y + (h - totalHeight) / 2 + fontSize,
    'bottom' => y + h - totalHeight + fontSize,
    _ => y + fontSize,
  };

  final startTag =
      '<text x="${_fmt(anchorX)}" y="${_fmt(firstBaselineY)}" '
      'fill="$color" font-size="${_fmt(fontSize)}" '
      'font-family="$family" text-anchor="$align">';
  buf.write(startTag);
  for (int i = 0; i < lines.length; i++) {
    if (i == 0) {
      buf.write(_escapeXml(lines[i]));
    } else {
      buf.write(
        '<tspan x="${_fmt(anchorX)}" dy="${_fmt(lineHeight)}">'
        '${_escapeXml(lines[i])}</tspan>',
      );
    }
  }
  buf.writeln('</text>');
}

void _emitFreedraw(
  StringBuffer buf,
  Map<String, dynamic> e,
  double x,
  double y,
) {
  final rawPoints = e['points'];
  if (rawPoints is! List || rawPoints.isEmpty) return;
  final stroke = _resolveStroke(e);
  final pts = <String>[];
  for (final p in rawPoints) {
    if (p is List && p.length >= 2) {
      pts.add('${_fmt(x + _d(p[0]))},${_fmt(y + _d(p[1]))}');
    }
  }
  if (pts.isEmpty) return;
  buf.writeln(
    '<polyline points="${pts.join(' ')}" fill="none" '
    'stroke="${stroke.color}" stroke-width="${_fmt(stroke.width)}" '
    'stroke-linecap="round" stroke-linejoin="round"/>',
  );
}

void _emitFrame(
  StringBuffer buf,
  Map<String, dynamic> e,
  double x,
  double y,
  double w,
  double h,
) {
  buf.writeln(
    '<rect x="${_fmt(x)}" y="${_fmt(y)}" '
    'width="${_fmt(w)}" height="${_fmt(h)}" '
    'fill="none" stroke="#cccccc" stroke-width="1"/>',
  );
  final name = e['name']?.toString();
  if (name != null && name.isNotEmpty) {
    buf.writeln(
      '<text x="${_fmt(x)}" y="${_fmt(y - 4)}" '
      'fill="#888888" font-size="12" font-family="sans-serif">'
      '${_escapeXml(name)}</text>',
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _Stroke {
  const _Stroke(this.color, this.width, this.dash);
  final String color;
  final double width;
  final String? dash;
}

_Stroke _resolveStroke(Map<String, dynamic> e) {
  var color = e['strokeColor']?.toString().trim();
  if (color == null || color.isEmpty) color = '#1e1e1e';
  if (color == 'transparent') color = 'none';
  final widthRaw = _d(e['strokeWidth']);
  final width = widthRaw > 0 ? widthRaw : 2.0;
  final style = e['strokeStyle']?.toString() ?? 'solid';
  String? dash;
  if (style == 'dashed') {
    final base = math.max(width * 3, 6);
    dash = '${_fmt(base)} ${_fmt(base * 0.75)}';
  } else if (style == 'dotted') {
    final base = math.max(width * 0.5, 1);
    dash = '${_fmt(base)} ${_fmt(base * 2.0)}';
  }
  return _Stroke(_escapeAttr(color), width, dash);
}

String? _resolveFill(Map<String, dynamic> e) {
  final bg = e['backgroundColor']?.toString().trim();
  if (bg == null || bg.isEmpty || bg == 'transparent') return null;
  return _escapeAttr(bg);
}

String _svgFontFamily(dynamic raw) {
  if (raw is num) {
    switch (raw.toInt()) {
      case 1:
        return 'Virgil, Comic Sans MS, sans-serif';
      case 3:
        return 'Cascadia, Consolas, monospace';
      default:
        return 'Helvetica, Arial, sans-serif';
    }
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return _escapeAttr(raw);
  }
  return 'Helvetica, Arial, sans-serif';
}

String _escapeXml(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

String _escapeAttr(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

String _fmt(num v) {
  if (v == v.toInt()) return v.toInt().toString();
  return v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(
    RegExp(r'\.$'),
    '',
  );
}

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}
