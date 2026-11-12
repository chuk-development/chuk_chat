/// The agent avatar figure ("D1"): a voxel cube creature. The body is one
/// cube with a face, stubby arms at the sides and two small feet. It turns
/// and tilts as a whole, tips onto its side to sleep, hops when a turn is
/// done and works with a prop in front of it. Nothing is worn on the head
/// and nothing flies around it; the state shows in the figure itself.
///
/// The camera is fitted once to the union of all poses ([fitPoses]), so
/// every move stays inside a round or square frame of any size.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/agent_avatar/avatar_engine.dart';
import 'package:chuk_chat/ui/agent_avatar/avatar_rig.dart';

/// Cheer jump height of the figure, relative to the rig.
const double kCubeJump = 0.45;

const double _h = 2.0; // half edge of the cube
const double _base = 0.8; // height of the feet
const V3 _centre = V3(0, _base + _h, 0);
const Color _ink = Color(0xFF231C2E);

Color _shade(Color c, double dl) {
  final HSLColor h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness + dl).clamp(0.0, 1.0)).toColor();
}

/// The body colour for an agent accent: the accent's hue, softened so the
/// face light and shade have room. Same hue as the agent's bubbles.
Color cubeBodyColor(Color accent) {
  final HSLColor h = HSLColor.fromColor(accent);
  return HSLColor.fromAHSL(
    1,
    h.hue,
    math.min(h.saturation, 0.72),
    0.62,
  ).toColor();
}

Decal _grid({Decal? over}) => (Canvas c, UvMap uv) {
  final Paint g = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8
    ..strokeCap = StrokeCap.round
    ..color = Colors.black.withValues(alpha: 0.06);
  for (int k = 1; k < 4; k++) {
    uvLine(c, uv, <Offset>[Offset(k / 4, 0), Offset(k / 4, 1)], g);
    uvLine(c, uv, <Offset>[Offset(0, k / 4), Offset(1, k / 4)], g);
  }
  over?.call(c, uv);
};

/// The face: square pixel eyes with moving pupils, cheeks, a mouth.
Decal _face(RigPose r, Color body) => (Canvas c, UvMap uv) {
  final Color cheek = _shade(body, 0.16);
  uvRect(c, uv, 0.08, 0.6, 0.22, 0.7, cheek);
  uvRect(c, uv, 0.78, 0.6, 0.92, 0.7, cheek);
  for (final double cu in <double>[0.3, 0.7]) {
    switch (r.eyes) {
      case AvatarEyes.closed:
        uvRect(c, uv, cu - 0.11, 0.47, cu + 0.11, 0.52, _ink);
      case AvatarEyes.happy:
        uvLine(
          c,
          uv,
          <Offset>[
            Offset(cu - 0.1, 0.5),
            Offset(cu, 0.38),
            Offset(cu + 0.1, 0.5),
          ],
          Paint()
            ..isAntiAlias = true
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = _ink,
        );
      case AvatarEyes.open:
      case AvatarEyes.focus:
        final double open =
            (1 - r.blink).clamp(0.1, 1.0) *
            (r.eyes == AvatarEyes.focus ? 0.65 : 1);
        final double hv = 0.15 * open;
        final double cv = 0.45 + (r.eyes == AvatarEyes.focus ? 0.04 : 0);
        uvRect(
          c,
          uv,
          cu - 0.11,
          cv - hv,
          cu + 0.11,
          cv + hv,
          const Color(0xFFF8F6FC),
        );
        final Offset look = clampLook(r.pupil);
        final double pu = cu + look.dx * 0.045;
        final double pv = cv + look.dy * 0.05 * open;
        final double ph = 0.09 * open;
        uvRect(c, uv, pu - 0.06, pv - ph, pu + 0.06, pv + ph, _ink);
        if (open > 0.5) {
          uvRect(
            c,
            uv,
            pu - 0.05,
            pv - ph,
            pu - 0.015,
            pv - ph + 0.05,
            Colors.white,
          );
        }
    }
  }
  if (r.eyes == AvatarEyes.happy) {
    uvRect(c, uv, 0.42, 0.66, 0.58, 0.76, _ink);
    uvRect(c, uv, 0.45, 0.72, 0.55, 0.76, const Color(0xFFE5484D));
  } else if (r.eyes == AvatarEyes.closed) {
    uvRect(c, uv, 0.46, 0.7, 0.54, 0.73, _ink);
  } else {
    uvRect(c, uv, 0.44, 0.7, 0.56, 0.74, _ink);
  }
};

/// Turn, tilt, hop and tip over, around the cube's centre.
Xf _bodyXf(RigPose r) {
  final Xf root =
      Xf.move(
        0,
        r.jump * 0.8 + r.bob - r.squash * 0.8 - r.lie * _base * 0.85,
        0,
      ) *
      Xf(M3.rotY(r.yaw + r.headYaw * 0.7));
  return root *
      Xf.about(
        _centre,
        M3.rotZ(r.headRoll * 0.6 + r.lie * 1.4) *
            M3.rotX(r.lean + r.headPitch * 0.45),
      );
}

void _props(
  Scene sc,
  Xf body,
  List<Xf> arms,
  RigPose r,
  Color bodyColor,
  Color accent,
) {
  const double fz = _h + 0.25;
  switch (r.prop) {
    case AvatarProp.none:
      break;
    case AvatarProp.letter:
      sc.box(
        body,
        const V3(-1.2, _base + 0.15, fz),
        const V3(1.2, _base + 1.6, fz + 0.14),
        const Color(0xFFFFF6E0),
        decals: <String, Decal>{
          'front': (Canvas c, UvMap uv) {
            uvLine(
              c,
              uv,
              const <Offset>[
                Offset(0.04, 0.06),
                Offset(0.5, 0.55),
                Offset(0.96, 0.06),
              ],
              Paint()
                ..isAntiAlias = true
                ..style = PaintingStyle.stroke
                ..strokeJoin = StrokeJoin.round
                ..strokeCap = StrokeCap.round
                ..strokeWidth = 1.2
                ..color = const Color(0xFFB9A88A),
            );
            uvRect(c, uv, 0.74, 0.14, 0.9, 0.42, const Color(0xFFE5484D));
          },
        },
      );
    case AvatarProp.book:
      final Xf bk =
          body * Xf.about(const V3(0, _base + 0.9, fz), M3.rotX(-0.3));
      final Color cover = _shade(bodyColor, -0.28);
      final Xf l = bk * Xf.about(const V3(0, 0, fz), M3.rotY(0.25));
      final Xf rr = bk * Xf.about(const V3(0, 0, fz), M3.rotY(-0.25));
      sc.box(
        l,
        const V3(-1.25, _base + 0.15, fz),
        const V3(0, _base + 1.65, fz + 0.1),
        cover,
      );
      sc.box(
        rr,
        const V3(0, _base + 0.15, fz),
        const V3(1.25, _base + 1.65, fz + 0.1),
        cover,
      );
      Decal lines() => (Canvas c, UvMap uv) {
        final Paint ink = Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 0.9
          ..color = const Color(0xFF9A93A8);
        for (int k = 0; k < 4; k++) {
          uvLine(c, uv, <Offset>[
            Offset(0.15, 0.22 + k * 0.17),
            Offset(0.85, 0.22 + k * 0.17),
          ], ink);
        }
      };
      sc.box(
        l,
        const V3(-1.15, _base + 0.22, fz + 0.1),
        const V3(0, _base + 1.58, fz + 0.18),
        const Color(0xFFFBF8F1),
        decals: <String, Decal>{'front': lines()},
      );
      sc.box(
        rr,
        const V3(0, _base + 0.22, fz + 0.1),
        const V3(1.15, _base + 1.58, fz + 0.18),
        const Color(0xFFFBF8F1),
        decals: <String, Decal>{'front': lines()},
      );
      final double a = -0.25 + math.pi * Curves.easeInOut.transform(r.propT);
      sc.face(
        bk * Xf.about(const V3(0, 0, fz + 0.19), M3.rotY(-a)),
        const <V3>[
          V3(0, _base + 0.24, fz + 0.19),
          V3(1.1, _base + 0.24, fz + 0.19),
          V3(1.1, _base + 1.56, fz + 0.19),
          V3(0, _base + 1.56, fz + 0.19),
        ],
        const Color(0xFFF2EEE4),
        twoSided: true,
      );
    case AvatarProp.palette:
      sc.box(
        arms[0],
        const V3(-_h - 1.0, _base + 0.75, 0.2),
        const V3(-_h + 0.1, _base + 0.9, 1.3),
        const Color(0xFFD9B48A),
        decals: <String, Decal>{
          'top': (Canvas c, UvMap uv) {
            const List<Color> dots = <Color>[
              Color(0xFFE5484D),
              Color(0xFFFFC94D),
              Color(0xFF4DD4FF),
            ];
            for (int k = 0; k < 3; k++) {
              uvOval(c, uv, 0.25 + k * 0.25, 0.5, 0.1, 0.12, dots[k]);
            }
          },
        },
      );
      final double wave = math.sin(r.propT * 2 * math.pi * 8) * 0.5;
      final Xf brush =
          arms[1] *
          Xf.about(
            const V3(_h + 0.4, _base + 1.0, 0),
            M3.rotX(-0.9 + wave * 0.4) * M3.rotZ(wave * 0.3),
          );
      sc.box(
        brush,
        const V3(_h + 0.32, _base + 1.0, -0.08),
        const V3(_h + 0.48, _base + 2.4, 0.08),
        const Color(0xFF8A5A3B),
      );
      sc.cube(
        brush,
        const V3(_h + 0.4, _base + 2.55, 0),
        const V3(0.26, 0.32, 0.26),
        accent,
      );
    case AvatarProp.binoculars:
      const double ey = _base + 2 * _h * 0.55;
      for (final double side in <double>[-1, 1]) {
        sc.prismZ(
          body,
          V3(side * 0.6, ey, fz + 0.35),
          0.4,
          0.8,
          8,
          const Color(0xFF2E2B3B),
          cap: const Color(0xFF7FD3FF),
        );
      }
    case AvatarProp.laptop:
      const double y = _base + 0.25;
      sc.box(
        body,
        const V3(-1.3, y, fz - 0.05),
        const V3(1.3, y + 0.16, fz + 1.2),
        const Color(0xFFB8BCC8),
      );
      final Xf lid =
          body * Xf.about(const V3(0, y + 0.16, fz + 1.2), M3.rotX(0.3));
      sc.box(
        lid,
        const V3(-1.3, y + 0.16, fz + 1.1),
        const V3(1.3, y + 1.6, fz + 1.22),
        const Color(0xFFCDD1DB),
        decals: <String, Decal>{
          'front': (Canvas c, UvMap uv) =>
              uvOval(c, uv, 0.5, 0.5, 0.1, 0.16, accent),
        },
      );
  }
}

/// Adds the figure in pose [r] to [sc].
void buildCube(Scene sc, RigPose r, Color accent) {
  final Color body = cubeBodyColor(accent);
  final Xf b = _bodyXf(r);
  for (final bool left in <bool>[true, false]) {
    final double swing = left ? r.legLx : r.legRx;
    final double x = left ? -0.95 : 0.95;
    final double fz = -swing * 0.7;
    final double lift = math.max(0, -swing) * 0.4;
    sc.box(
      b,
      V3(x - 0.55, lift, -0.55 + fz),
      V3(x + 0.55, _base + 0.1 + lift, 0.75 + fz),
      _shade(body, -0.2),
    );
  }
  sc.box(
    b,
    const V3(-_h, _base, -_h),
    const V3(_h, _base + 2 * _h, _h),
    body,
    decals: <String, Decal>{
      'front': _grid(over: _face(r, body)),
      'right': _grid(),
      'left': _grid(),
      'top': _grid(),
    },
  );
  final List<Xf> arms = <Xf>[];
  for (final bool left in <bool>[true, false]) {
    final double sx = left ? -_h : _h;
    final double side = left ? -1 : 1;
    final Xf arm =
        b *
        Xf.about(
          V3(sx, _base + 2.3, 0),
          M3.rotZ(side * (left ? r.armLz : r.armRz) * 0.9) *
              M3.rotX((left ? r.armLx : r.armRx) * 0.9),
        );
    arms.add(arm);
    sc.box(
      arm,
      V3(sx + side * 0.05, _base + 0.9, -0.4),
      V3(sx + side * 0.75, _base + 2.45, 0.4),
      _shade(body, -0.06),
      top: _shade(body, 0.05),
    );
  }
  _props(sc, b, arms, r, body, accent);
}

/// Body radius of the round figure (half edge of the cube it replaces).
const double _rr = 2.05;

/// Adds the round figure ("D1 rund") in pose [r] to [sc]: the same creature
/// as [buildCube] with a soft, rounded body (a faceted superellipsoid),
/// ball arms and ball feet. Its face is drawn on top by [_roundFace].
void buildRound(Scene sc, RigPose r, Color accent) {
  final Color body = cubeBodyColor(accent);
  final Xf b = _bodyXf(r);
  for (final bool left in <bool>[true, false]) {
    final double swing = left ? r.legLx : r.legRx;
    final double x = left ? -0.95 : 0.95;
    final double fz = -swing * 0.7;
    final double lift = math.max(0, -swing) * 0.4;
    sc.ball(
      b,
      V3(x, 0.45 + lift, 0.2 + fz),
      0.62,
      _shade(body, -0.16),
      seg: 9,
      sy: 0.7,
    );
  }
  sc.superBall(
    b,
    _centre,
    _rr * 1.02,
    _rr * 0.98,
    _rr * 0.92,
    body,
    e: 0.62,
    seg: 16,
    rings: 11,
  );
  final List<Xf> arms = <Xf>[];
  for (final bool left in <bool>[true, false]) {
    final double sx = left ? -_rr * 0.98 : _rr * 0.98;
    final double side = left ? -1 : 1;
    final Xf arm =
        b *
        Xf.about(
          V3(sx, _base + 2.3, 0),
          M3.rotZ(side * (left ? r.armLz : r.armRz) * 0.9) *
              M3.rotX((left ? r.armLx : r.armRx) * 0.9),
        );
    arms.add(arm);
    sc.ball(
      arm,
      V3(sx + side * 0.3, _base + 1.5, 0),
      0.55,
      _shade(body, -0.05),
      sy: 1.25,
    );
  }
  _props(sc, b, arms, r, body, accent);
}

/// The round figure's face, H2 style: big white eyes with pupils and a
/// highlight, cheeks, a mouth; drawn at their projected spots on the body,
/// so they turn with it and hide when it turns away.
void _roundFace(Canvas canvas, Camera cam, RigPose r, Color accent) {
  final Color body = cubeBodyColor(accent);
  final Xf b = _bodyXf(r);
  final V3 vc = cam.view(b.apply(_centre));
  final Offset c0 = cam.project(vc);
  final double unit =
      (cam.project(cam.view(b.apply(_centre + const V3(1, 0, 0)))) - c0)
          .distance;
  Offset? at(V3 local) {
    final V3 vw = cam.view(b.apply(local));
    if ((vw - vc).unit.z < 0.2) return null;
    return cam.project(vw);
  }

  Paint fill(Color c) => Paint()
    ..isAntiAlias = true
    ..color = c;
  final double er = unit * 0.43;
  const double fz = _rr * 0.92;
  for (final double side in <double>[-1, 1]) {
    final Offset? c = at(V3(side * 1.25, _base + _h - 0.35, fz * 0.92));
    if (c != null) {
      canvas.drawOval(
        Rect.fromCenter(center: c, width: er * 1.5, height: er * 0.8),
        fill(_shade(body, 0.16).withValues(alpha: 0.8)),
      );
    }
  }
  if (r.prop != AvatarProp.binoculars) {
    for (final double side in <double>[-1, 1]) {
      final V3 local = V3(side * 0.72, _base + _h + 0.35, fz);
      final Offset? e = at(local);
      if (e == null) continue;
      final double nz = (cam.view(b.apply(local)) - vc).unit.z;
      final double squeeze = nz.clamp(0.35, 1.0);
      switch (r.eyes) {
        case AvatarEyes.closed:
        case AvatarEyes.happy:
          canvas.drawArc(
            Rect.fromCenter(
              center: e,
              width: er * 2 * squeeze,
              height: er * 1.4,
            ),
            r.eyes == AvatarEyes.happy ? math.pi : 0.1,
            math.pi * 0.8,
            false,
            Paint()
              ..isAntiAlias = true
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = math.max(1.2, er * 0.38)
              ..color = _ink,
          );
        case AvatarEyes.open:
        case AvatarEyes.focus:
          final double open =
              (1 - r.blink).clamp(0.1, 1.0) *
              (r.eyes == AvatarEyes.focus ? 0.7 : 1);
          canvas.drawOval(
            Rect.fromCenter(
              center: e,
              width: er * 2 * squeeze,
              height: er * 2.3 * open,
            ),
            fill(Colors.white),
          );
          final Offset look = clampLook(r.pupil);
          final Offset pp =
              e + Offset(look.dx * er * 0.38, look.dy * er * 0.4 * open);
          canvas.drawOval(
            Rect.fromCenter(
              center: pp,
              width: er * 1.2 * squeeze,
              height: er * 1.4 * open,
            ),
            fill(_ink),
          );
          canvas.drawCircle(
            pp + Offset(-er * 0.22, -er * 0.28 * open),
            er * 0.24,
            fill(Colors.white),
          );
      }
    }
  }
  final Offset? m = at(const V3(0, _base + _h - 0.55, fz * 0.97));
  if (m != null) {
    if (r.eyes == AvatarEyes.happy) {
      canvas.drawArc(
        Rect.fromCenter(
          center: m.translate(0, -er * 0.3),
          width: er * 1.3,
          height: er * 1.1,
        ),
        0,
        math.pi,
        true,
        fill(_ink),
      );
    } else if (r.eyes != AvatarEyes.closed) {
      canvas.drawArc(
        Rect.fromCenter(
          center: m.translate(0, -er * 0.35),
          width: er * 0.9,
          height: er * 0.6,
        ),
        0.2,
        math.pi - 0.4,
        false,
        Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(1.0, er * 0.3)
          ..color = _ink,
      );
    }
  }
}

typedef _Build = void Function(Scene sc, RigPose r, Color accent);

final Map<String, Rect> _bounds = <String, Rect>{};

Rect _union(String key, _Build build, Iterable<RigPose> poses) =>
    _bounds.putIfAbsent(key, () {
      final Camera c0 = Camera(center: Offset.zero, scale: 1);
      Rect? u;
      for (final RigPose r in poses) {
        r.jump *= kCubeJump;
        final Scene sc = Scene(c0);
        build(sc, r, const Color(0xFF7C4DFF));
        final Rect? b = sc.bounds();
        if (b != null) u = u == null ? b : u.expandToInclude(b);
      }
      return u ?? Rect.zero;
    });

/// The union of all poses of the square figure, at scale 1, computed once.
Rect cubeFitBounds({bool round = false}) => _union(
  '${round ? 'round' : 'cube'}/any',
  round ? buildRound : buildCube,
  fitPoses(),
);

/// A camera for a square of [s]: the resting figure (looking around) fills
/// [fill] of it and sits in the middle; every other move still stays inside
/// (2 % edge), which can shift or shrink it a little.
Camera cubeCamera(double s, {double fill = 0.8, bool round = false}) {
  final _Build build = round ? buildRound : buildCube;
  final String tag = round ? 'round' : 'cube';
  final Rect rest = _union('$tag/rest', build, fitPoses().take(4));
  final Rect any = cubeFitBounds(round: round);
  double k = s * fill / math.max(rest.width, rest.height);
  k = math.min(k, s * 0.96 / math.max(any.width, any.height));
  double cx = s / 2 - rest.center.dx * k;
  double cy = s / 2 - rest.center.dy * k;
  final double top = cy + any.top * k, bottom = cy + any.bottom * k;
  if (top < s * 0.02) cy += s * 0.02 - top;
  if (bottom > s * 0.98) cy -= bottom - s * 0.98;
  final double left = cx + any.left * k, right = cx + any.right * k;
  if (left < s * 0.02) cx += s * 0.02 - left;
  if (right > s * 0.98) cx -= right - s * 0.98;
  return Camera(center: Offset(cx, cy), scale: k);
}

/// A soft neutral ground shadow (radial gradient, no blur filter).
void _shadow(Canvas canvas, Camera cam, RigPose r, double s) {
  final Offset c = cam.projectWorld(V3.zero);
  final double k = 1 / (1 + r.jump * 0.35);
  final double w = s * 0.5 * k;
  final Rect rect = Rect.fromCenter(center: c, width: w, height: w * 0.3);
  canvas.save();
  canvas.translate(rect.center.dx, rect.center.dy);
  canvas.scale(1, rect.height / rect.width);
  final double rad = rect.width / 2;
  canvas.drawCircle(
    Offset.zero,
    rad,
    Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.black.withValues(alpha: 0.22 * k),
          Colors.black.withValues(alpha: 0.13 * k),
          Colors.black.withValues(alpha: 0),
        ],
        stops: const <double>[0, 0.55, 1],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: rad)),
  );
  canvas.restore();
}

/// A small Zzz in the top-right corner, inside a round frame too. Left out
/// below 40 px, where it would only be noise.
void _zzz(Canvas canvas, double s, RigPose r, double t, Color color) {
  if (r.zzz <= 0.01 || s < 40) return;
  for (int k = 0; k < 2; k++) {
    final double ph = (t * 0.4 + k / 2) % 1.0;
    final double sz = s * (0.045 + ph * 0.03);
    final Offset c = Offset(s * (0.72 + ph * 0.06), s * (0.3 - ph * 0.1));
    final double a = r.zzz * (ph < 0.2 ? ph / 0.2 : 1 - (ph - 0.2) / 0.8);
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - sz / 2, c.dy - sz / 2)
        ..lineTo(c.dx + sz / 2, c.dy - sz / 2)
        ..lineTo(c.dx - sz / 2, c.dy + sz / 2)
        ..lineTo(c.dx + sz / 2, c.dy + sz / 2),
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = math.max(1.0, sz * 0.2)
        ..color = color.withValues(alpha: a.clamp(0.0, 1.0)),
    );
  }
}

/// Paints the square figure for [pose] into a square of [s] logical pixels.
void paintCubeAvatar(
  Canvas canvas,
  double s,
  Color accent,
  AvatarPose pose, {
  bool dark = false,
}) => _paint(canvas, s, accent, pose, dark: dark, round: false);

/// Paints the round figure ("D1 rund", the app's avatar) for [pose] into a
/// square of [s] logical pixels.
void paintRoundAvatar(
  Canvas canvas,
  double s,
  Color accent,
  AvatarPose pose, {
  bool dark = false,
}) => _paint(canvas, s, accent, pose, dark: dark, round: true);

void _paint(
  Canvas canvas,
  double s,
  Color accent,
  AvatarPose pose, {
  required bool dark,
  required bool round,
}) {
  final RigPose r = rigForPose(pose)..jump *= kCubeJump;
  final Camera cam = cubeCamera(s, round: round);
  _shadow(canvas, cam, r, s);
  final Scene sc = Scene(cam);
  if (round) {
    buildRound(sc, r, accent);
  } else {
    buildCube(sc, r, accent);
  }
  sc.render(canvas);
  if (round) _roundFace(canvas, cam, r, accent);
  _zzz(canvas, s, r, pose.t, dark ? Colors.white : _ink);
}
