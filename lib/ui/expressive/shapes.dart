/// The Material 3 Expressive shape family: the scalloped "cookie / clover /
/// flower" blobs a coworker's face is cut out of.
///
/// The shape is a [ShapeBorder], so it clips, it morphs with
/// [ShapeBorder.lerp] and it takes an ink splash like any Material shape. The
/// radius is modulated with a cosine: `r(t) = base - amp + amp * cos(lobes *
/// t)`, which gives [CookieShape.lobes] soft bumps around the circle.
///
/// The silhouette is picked from an identity key (the agent id), never from a
/// list position, so one coworker keeps one silhouette on every screen: the
/// inbox row, the chat header, the profile page and the desktop roster.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A scalloped blob. [softness] 0 is a circle; about 0.2 is a deep scallop.
class CookieShape extends ShapeBorder {
  const CookieShape({this.lobes = 8, this.softness = 0.12, this.rotation = 0});

  final int lobes;
  final double softness;

  /// Orientation in radians, so two blobs with the same lobe count still look
  /// different.
  final double rotation;

  Path _build(Rect rect) {
    final Offset centre = rect.center;
    final double base = rect.shortestSide / 2;
    final double amp = base * softness;
    final Path path = Path();
    const int steps = 220;
    for (int i = 0; i <= steps; i++) {
      final double t = (i / steps) * 2 * math.pi + rotation;
      final double r = (base - amp) + amp * math.cos(lobes * (t - rotation));
      final double x = centre.dx + r * math.cos(t);
      final double y = centre.dy + r * math.sin(t);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _build(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _build(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) =>
      CookieShape(lobes: lobes, softness: softness * t, rotation: rotation);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
}

/// A stable shape index from an identity [key] (an agent id). Same key, same
/// silhouette, on every screen and after every restart.
int shapeIndexFor(String key) {
  int hash = 0;
  for (final int unit in key.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash % 6;
}

/// [expressiveShape] keyed by identity instead of list position.
ShapeBorder expressiveShapeFor(String key) =>
    expressiveShape(shapeIndexFor(key));

/// One curated silhouette per index. The variety is part of the language: two
/// neighbouring faces in a list do not share a shape.
ShapeBorder expressiveShape(int i) {
  switch (i % 6) {
    case 0:
      return const CookieShape(lobes: 7, softness: 0.11); // cookie
    case 1:
      return const CookieShape(lobes: 4, softness: 0.16, rotation: 0.4); // clover
    case 2:
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
      ); // squircle
    case 3:
      return const CookieShape(lobes: 6, softness: 0.13); // flower
    case 4:
      return const StadiumBorder(); // pill
    default:
      return const CookieShape(lobes: 8, softness: 0.10, rotation: 0.2);
  }
}
