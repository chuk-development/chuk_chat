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
  return hash % 8;
}

/// [expressiveShape] keyed by identity instead of list position.
ShapeBorder expressiveShapeFor(String key) =>
    expressiveShape(shapeIndexFor(key));

/// One curated silhouette per index.
///
/// Every one of these has to read as a different shape at 32 px in a list, so
/// none of them may be a circle in disguise. Two of the earlier set were: a
/// [StadiumBorder] in a square box IS a circle, and a fixed 22 px corner radius
/// on a 52 px avatar is one too. A scallop below about 0.13 also disappears at
/// list size. The set is now: cookie, clover, squircle, flower, diamond, gem,
/// triangle, burst. Eight, not six: with six silhouettes a roster of three
/// coworkers already showed two of them the same shape.
ShapeBorder expressiveShape(int i) {
  switch (i % 8) {
    case 0:
      return const CookieShape(lobes: 7, softness: 0.15); // cookie
    case 1:
      return const CookieShape(
        lobes: 4,
        softness: 0.22,
        rotation: 0.4,
      ); // clover
    case 2:
      return const PolygonShape(sides: 4, cornerFactor: 0.34); // squircle
    case 3:
      return const CookieShape(lobes: 6, softness: 0.18); // flower
    case 4:
      return const PolygonShape(
        sides: 4,
        cornerFactor: 0.22,
        rotation: math.pi / 4,
      ); // diamond
    case 5:
      return const PolygonShape(
        sides: 6,
        cornerFactor: 0.26,
        rotation: math.pi / 6,
      ); // gem
    case 6:
      return const PolygonShape(sides: 3, cornerFactor: 0.34); // triangle
    default:
      return const CookieShape(lobes: 11, softness: 0.14); // burst
  }
}

/// A regular polygon with rounded corners, inscribed in the box.
///
/// [cornerFactor] is the corner radius as a fraction of the distance from the
/// centre to a corner: 0 is a sharp polygon, and a square at about 0.34 reads
/// as the squircle of the expressive language while still having four sides.
class PolygonShape extends ShapeBorder {
  const PolygonShape({
    required this.sides,
    this.cornerFactor = 0.25,
    this.rotation = 0,
  }) : assert(sides >= 3);

  final int sides;
  final double cornerFactor;

  /// Orientation in radians. A square turns into a diamond at pi / 4.
  final double rotation;

  Path _build(Rect rect) {
    final Offset centre = rect.center;
    final double radius = rect.shortestSide / 2;
    final List<Offset> corners = <Offset>[
      for (int i = 0; i < sides; i++)
        Offset(
          centre.dx +
              radius *
                  math.cos(rotation - math.pi / 2 + i * 2 * math.pi / sides),
          centre.dy +
              radius *
                  math.sin(rotation - math.pi / 2 + i * 2 * math.pi / sides),
        ),
    ];
    final double round = (radius * cornerFactor).clamp(0.0, radius);
    final Path path = Path();
    for (int i = 0; i < sides; i++) {
      final Offset corner = corners[i];
      final Offset previous = corners[(i - 1 + sides) % sides];
      final Offset next = corners[(i + 1) % sides];
      // Walk `round` back along both edges of this corner and bend between the
      // two points, so the corner is a curve and not a spike.
      final Offset toPrevious = _towards(corner, previous, round);
      final Offset toNext = _towards(corner, next, round);
      if (i == 0) {
        path.moveTo(toPrevious.dx, toPrevious.dy);
      } else {
        path.lineTo(toPrevious.dx, toPrevious.dy);
      }
      path.quadraticBezierTo(corner.dx, corner.dy, toNext.dx, toNext.dy);
    }
    return path..close();
  }

  static Offset _towards(Offset from, Offset to, double distance) {
    final double dx = to.dx - from.dx;
    final double dy = to.dy - from.dy;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return from;
    final double t = (distance / length).clamp(0.0, 0.5);
    return Offset(from.dx + dx * t, from.dy + dy * t);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _build(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _build(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => PolygonShape(
    sides: sides,
    cornerFactor: cornerFactor * t,
    rotation: rotation,
  );

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
}
