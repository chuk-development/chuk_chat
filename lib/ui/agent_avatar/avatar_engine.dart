/// A tiny software 3D renderer for the agent avatar: boxes and prisms under
/// a part hierarchy, a perspective camera, back-face culling, a painter's
/// sort and Lambert light from the top left. A face can carry a decal (the
/// eyes, the grid) drawn in the face's own UV space, so it turns with it.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show HSLColor;

class V3 {
  const V3(this.x, this.y, this.z);
  final double x, y, z;
  static const V3 zero = V3(0, 0, 0);

  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double k) => V3(x * k, y * k, z * k);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  V3 cross(V3 o) => V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);
  V3 get unit {
    final double l = length;
    return l == 0 ? this : this * (1 / l);
  }

  static V3 lerp(V3 a, V3 b, double t) => a + (b - a) * t;
}

/// A 3x3 rotation, row major.
class M3 {
  const M3(
    this.a,
    this.b,
    this.c,
    this.d,
    this.e,
    this.f,
    this.g,
    this.h,
    this.i,
  );
  final double a, b, c, d, e, f, g, h, i;
  static const M3 identity = M3(1, 0, 0, 0, 1, 0, 0, 0, 1);

  factory M3.rotX(double t) {
    final double co = math.cos(t), si = math.sin(t);
    return M3(1, 0, 0, 0, co, -si, 0, si, co);
  }

  factory M3.rotY(double t) {
    final double co = math.cos(t), si = math.sin(t);
    return M3(co, 0, si, 0, 1, 0, -si, 0, co);
  }

  factory M3.rotZ(double t) {
    final double co = math.cos(t), si = math.sin(t);
    return M3(co, -si, 0, si, co, 0, 0, 0, 1);
  }

  M3 operator *(M3 o) => M3(
    a * o.a + b * o.d + c * o.g,
    a * o.b + b * o.e + c * o.h,
    a * o.c + b * o.f + c * o.i,
    d * o.a + e * o.d + f * o.g,
    d * o.b + e * o.e + f * o.h,
    d * o.c + e * o.f + f * o.i,
    g * o.a + h * o.d + i * o.g,
    g * o.b + h * o.e + i * o.h,
    g * o.c + h * o.f + i * o.i,
  );

  V3 apply(V3 v) => V3(
    a * v.x + b * v.y + c * v.z,
    d * v.x + e * v.y + f * v.z,
    g * v.x + h * v.y + i * v.z,
  );
}

/// A rigid transform: rotate, then translate.
class Xf {
  const Xf([this.r = M3.identity, this.t = V3.zero]);
  final M3 r;
  final V3 t;
  static const Xf identity = Xf();

  V3 apply(V3 v) => r.apply(v) + t;

  /// `this ∘ o`: [o] first, then this.
  Xf operator *(Xf o) => Xf(r * o.r, r.apply(o.t) + t);

  factory Xf.move(double x, double y, double z) => Xf(M3.identity, V3(x, y, z));

  /// Rotation [m] about the point [p].
  factory Xf.about(V3 p, M3 m) => Xf(m, p - m.apply(p));
}

/// Maps a face's UV (0..1, u right, v down) to a screen point.
typedef UvMap = Offset Function(double u, double v);
typedef Decal = void Function(Canvas canvas, UvMap uv);

class _Face {
  _Face(this.pts, this.color, this.normal, this.decal, this.depth);
  final List<Offset> pts;
  final Color color;
  final V3 normal;
  final Decal? decal;
  final double depth;
}

class Camera {
  Camera({
    required this.center,
    required this.scale,
    this.elevation = 0.38,
    this.distance = 14,
  }) : _view = M3.rotX(elevation);

  final Offset center;
  final double scale;
  final double elevation;
  final double distance;
  final M3 _view;

  V3 view(V3 w) => _view.apply(w);

  Offset project(V3 v) {
    final double k = scale * distance / (distance - v.z);
    return Offset(center.dx + v.x * k, center.dy - v.y * k);
  }

  Offset projectWorld(V3 w) => project(view(w));
}

/// Toward the light: top left, in front.
final V3 kAvatarLight = const V3(-0.5, 0.75, 0.55).unit;

/// [c] lit by a face whose normal makes [ndl] with the light.
Color litColor(Color c, double ndl) {
  final HSLColor h = HSLColor.fromColor(c);
  final double dl = ((ndl * 0.5 + 0.5) - 0.62) * 0.42;
  return h.withLightness((h.lightness + dl).clamp(0.0, 1.0)).toColor();
}

class Scene {
  Scene(this.cam);
  final Camera cam;
  final List<_Face> _faces = <_Face>[];

  /// Adds a convex face. [center] is a point inside the part; it turns the
  /// normal outward whatever the winding. Quads go bottom-left,
  /// bottom-right, top-right, top-left, so decals are upright.
  void face(
    Xf xf,
    List<V3> local,
    Color color, {
    V3? center,
    Decal? decal,
    bool twoSided = false,
  }) {
    final List<V3> v = <V3>[for (final V3 p in local) cam.view(xf.apply(p))];
    V3 n = (v[1] - v[0]).cross(v[2] - v[0]).unit;
    if (center != null) {
      final V3 c = cam.view(xf.apply(center));
      V3 mid = V3.zero;
      for (final V3 p in v) {
        mid = mid + p;
      }
      mid = mid * (1 / v.length);
      if (n.dot(mid - c) < 0) n = n * -1;
    }
    final bool front = n.dot(V3(0, 0, cam.distance) - v[0]) > 0;
    if (!front) {
      if (!twoSided) return;
      n = n * -1;
    }
    double depth = 0;
    for (final V3 p in v) {
      depth += p.z;
    }
    _faces.add(
      _Face(
        <Offset>[for (final V3 p in v) cam.project(p)],
        color,
        n,
        decal,
        depth / v.length,
      ),
    );
  }

  /// An axis-aligned box from [a] to [b]. [decals] by face name: 'front'
  /// (+z), 'back', 'left', 'right', 'top', 'bottom'.
  void box(
    Xf xf,
    V3 a,
    V3 b,
    Color color, {
    Map<String, Decal>? decals,
    Color? top,
  }) {
    final V3 c = V3.lerp(a, b, 0.5);
    face(
      xf,
      <V3>[
        V3(a.x, a.y, b.z),
        V3(b.x, a.y, b.z),
        V3(b.x, b.y, b.z),
        V3(a.x, b.y, b.z),
      ],
      color,
      center: c,
      decal: decals?['front'],
    );
    face(
      xf,
      <V3>[
        V3(b.x, a.y, a.z),
        V3(a.x, a.y, a.z),
        V3(a.x, b.y, a.z),
        V3(b.x, b.y, a.z),
      ],
      color,
      center: c,
      decal: decals?['back'],
    );
    face(
      xf,
      <V3>[
        V3(b.x, a.y, b.z),
        V3(b.x, a.y, a.z),
        V3(b.x, b.y, a.z),
        V3(b.x, b.y, b.z),
      ],
      color,
      center: c,
      decal: decals?['right'],
    );
    face(
      xf,
      <V3>[
        V3(a.x, a.y, a.z),
        V3(a.x, a.y, b.z),
        V3(a.x, b.y, b.z),
        V3(a.x, b.y, a.z),
      ],
      color,
      center: c,
      decal: decals?['left'],
    );
    face(
      xf,
      <V3>[
        V3(a.x, b.y, b.z),
        V3(b.x, b.y, b.z),
        V3(b.x, b.y, a.z),
        V3(a.x, b.y, a.z),
      ],
      top ?? color,
      center: c,
      decal: decals?['top'],
    );
    face(
      xf,
      <V3>[
        V3(a.x, a.y, a.z),
        V3(b.x, a.y, a.z),
        V3(b.x, a.y, b.z),
        V3(a.x, a.y, b.z),
      ],
      color,
      center: c,
      decal: decals?['bottom'],
    );
  }

  /// A box given by centre and size.
  void cube(Xf xf, V3 c, V3 size, Color color) {
    final V3 h = size * 0.5;
    box(xf, c - h, c + h, color);
  }

  /// An n-sided prism along local z, centred at [c].
  void prismZ(
    Xf xf,
    V3 c,
    double r,
    double len,
    int n,
    Color color, {
    Color? cap,
  }) {
    final List<V3> back = <V3>[], front = <V3>[];
    for (int k = 0; k < n; k++) {
      final double a = k * 2 * math.pi / n;
      back.add(V3(c.x + math.cos(a) * r, c.y + math.sin(a) * r, c.z - len / 2));
      front.add(
        V3(c.x + math.cos(a) * r, c.y + math.sin(a) * r, c.z + len / 2),
      );
    }
    for (int k = 0; k < n; k++) {
      final int j = (k + 1) % n;
      face(xf, <V3>[back[k], back[j], front[j], front[k]], color, center: c);
    }
    face(xf, front, cap ?? color, center: c);
    face(xf, back, color, center: c);
  }

  /// The screen bounds of everything added so far.
  Rect? bounds() {
    Rect? b;
    for (final _Face f in _faces) {
      for (final Offset o in f.pts) {
        final Rect r = Rect.fromLTWH(o.dx, o.dy, 0, 0);
        b = b == null ? r : b.expandToInclude(r);
      }
    }
    return b;
  }

  void render(Canvas canvas) {
    _faces.sort((_Face a, _Face b) => a.depth.compareTo(b.depth));
    final Paint fill = Paint()..isAntiAlias = true;
    // A hairline in the face's own colour closes the gap that anti-aliasing
    // leaves between two faces sharing an edge.
    final Paint seam = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 0.6;
    for (final _Face f in _faces) {
      final Color c = litColor(f.color, f.normal.dot(kAvatarLight));
      final Path p = Path()..addPolygon(f.pts, true);
      fill.color = c;
      seam.color = c;
      canvas.drawPath(p, fill);
      if (c.a == 1) canvas.drawPath(p, seam);
      final Decal? decal = f.decal;
      if (decal != null && f.pts.length == 4) {
        final List<Offset> q = f.pts;
        decal(canvas, (double u, double v) {
          final Offset top = q[3] + (q[2] - q[3]) * u;
          final Offset bot = q[0] + (q[1] - q[0]) * u;
          return top + (bot - top) * v;
        });
      }
    }
    _faces.clear();
  }
}

Paint _fill(Color c) => Paint()
  ..isAntiAlias = true
  ..color = c;

/// A filled ellipse in UV space.
void uvOval(
  Canvas canvas,
  UvMap uv,
  double cu,
  double cv,
  double ru,
  double rv,
  Color color,
) {
  const int n = 18;
  final List<Offset> pts = <Offset>[
    for (int k = 0; k < n; k++)
      uv(
        cu + math.cos(k * 2 * math.pi / n) * ru,
        cv + math.sin(k * 2 * math.pi / n) * rv,
      ),
  ];
  canvas.drawPath(Path()..addPolygon(pts, true), _fill(color));
}

/// A filled rectangle in UV space.
void uvRect(
  Canvas canvas,
  UvMap uv,
  double u0,
  double v0,
  double u1,
  double v1,
  Color color,
) {
  canvas.drawPath(
    Path()..addPolygon(<Offset>[
      uv(u0, v0),
      uv(u1, v0),
      uv(u1, v1),
      uv(u0, v1),
    ], true),
    _fill(color),
  );
}

/// A stroked polyline in UV space.
void uvLine(Canvas canvas, UvMap uv, List<Offset> pts, Paint paint) {
  final Path p = Path();
  for (int k = 0; k < pts.length; k++) {
    final Offset s = uv(pts[k].dx, pts[k].dy);
    if (k == 0) {
      p.moveTo(s.dx, s.dy);
    } else {
      p.lineTo(s.dx, s.dy);
    }
  }
  canvas.drawPath(p, paint);
}
