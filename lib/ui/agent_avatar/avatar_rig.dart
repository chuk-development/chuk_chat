/// The avatar's states and its pose for each of them: joint angles, eyes and
/// the prop in its hands. Pure functions of state, time and look, so a pose
/// can be tested and the painter stays stateless.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;

/// What the avatar shows.
enum AgentAvatarState {
  /// Nothing going on: breathes, blinks, looks where it is told.
  idle,

  /// Inactive for a long while: tipped over, eyes shut, a small Zzz.
  sleep,

  /// A turn is running: busy with a prop.
  work,

  /// A turn just ended: one cheer jump.
  done,
}

enum AvatarEyes { open, closed, happy, focus }

/// What the figure holds while it works. It changes now and then, whatever
/// the agent's role is.
enum AvatarProp { none, laptop, letter, book, palette, binoculars }

/// The props a working avatar takes turns with.
const List<AvatarProp> kWorkProps = <AvatarProp>[
  AvatarProp.laptop,
  AvatarProp.letter,
  AvatarProp.book,
  AvatarProp.palette,
  AvatarProp.binoculars,
];

/// Seconds one prop stays in the hands before the next one.
const double kPropSeconds = 7;

/// How long one cheer takes; the done state lasts one of them.
const double kCheerSeconds = 1.7;

/// Everything that moves for one frame.
@immutable
class AvatarPose {
  const AvatarPose({
    this.look = Offset.zero,
    this.blink = 0,
    this.t = 0,
    this.state = AgentAvatarState.idle,
    this.stateT = 10,
    this.prev = AgentAvatarState.idle,
    this.prevT = 10,
    this.seed = 0,
  });

  /// Look direction, length at most 1; +x right, +y down.
  final Offset look;

  /// 0 open, 1 shut.
  final double blink;

  /// Running clock in seconds.
  final double t;

  final AgentAvatarState state;

  /// Seconds since [state] began.
  final double stateT;

  /// The state before and how long it ran; the pose blends out of it.
  final AgentAvatarState prev;
  final double prevT;

  /// Per-agent offset, so two working agents do not swap props in step.
  final double seed;
}

/// Clamps a look vector to length 1.
Offset clampLook(Offset look) {
  final double d = look.distance;
  return d > 1 ? look / d : look;
}

/// The prop a working avatar holds at clock [t].
AvatarProp propAt(double t, double seed) {
  final int i = ((t + seed * kPropSeconds) / kPropSeconds).floor();
  return kWorkProps[i % kWorkProps.length];
}

class RigPose {
  RigPose({
    this.yaw = 0,
    this.lean = 0,
    this.lie = 0,
    this.jump = 0,
    this.squash = 0,
    this.bob = 0,
    this.headYaw = 0,
    this.headPitch = 0,
    this.headRoll = 0,
    this.armLx = 0,
    this.armLz = 0.08,
    this.armRx = 0,
    this.armRz = 0.08,
    this.legLx = 0,
    this.legRx = 0,
    this.eyes = AvatarEyes.open,
    this.prop = AvatarProp.none,
    this.propT = 0,
    this.zzz = 0,
    this.pupil = Offset.zero,
    this.blink = 0,
  });

  double yaw, lean, lie, jump, squash, bob;
  double headYaw, headPitch, headRoll;
  double armLx, armLz, armRx, armRz, legLx, legRx;
  AvatarEyes eyes;
  AvatarProp prop;
  double propT, zzz;
  Offset pupil;
  double blink;

  static double _l(double a, double b, double t) => a + (b - a) * t;

  /// Blends [a] into [b]; the discrete parts switch half way.
  static RigPose lerp(RigPose a, RigPose b, double t) => RigPose(
    yaw: _l(a.yaw, b.yaw, t),
    lean: _l(a.lean, b.lean, t),
    lie: _l(a.lie, b.lie, t),
    jump: _l(a.jump, b.jump, t),
    squash: _l(a.squash, b.squash, t),
    bob: _l(a.bob, b.bob, t),
    headYaw: _l(a.headYaw, b.headYaw, t),
    headPitch: _l(a.headPitch, b.headPitch, t),
    headRoll: _l(a.headRoll, b.headRoll, t),
    armLx: _l(a.armLx, b.armLx, t),
    armLz: _l(a.armLz, b.armLz, t),
    armRx: _l(a.armRx, b.armRx, t),
    armRz: _l(a.armRz, b.armRz, t),
    legLx: _l(a.legLx, b.legLx, t),
    legRx: _l(a.legRx, b.legRx, t),
    eyes: t < 0.5 ? a.eyes : b.eyes,
    prop: t < 0.5 ? a.prop : b.prop,
    propT: b.propT,
    zzz: _l(a.zzz, b.zzz, t),
    pupil: a.pupil + (b.pupil - a.pupil) * t,
    blink: b.blink,
  );
}

double _ease(double x) {
  final double c = x.clamp(0.0, 1.0);
  return c * c * (3 - 2 * c);
}

/// The working pose for [prop].
void _work(RigPose r, AvatarProp prop, double t, Offset look) {
  const double tau = 2 * math.pi;
  r.prop = prop;
  switch (prop) {
    case AvatarProp.none:
    case AvatarProp.laptop:
      final double w = t * tau * 4.5;
      r.armLx = -0.85 + math.sin(w) * 0.12;
      r.armRx = -0.85 + math.sin(w + math.pi) * 0.12;
      r.armLz = r.armRz = 0.2;
      r.headPitch = 0.28;
      r.yaw = look.dx * 0.2;
      r.eyes = AvatarEyes.focus;
      r.pupil = Offset(math.sin(t * tau * 0.7) * 0.5, 0.5);
      r.bob = math.sin(w * 0.5).abs() * 0.04;
    case AvatarProp.letter:
      final double w = t * tau * 1.8;
      r.legLx = math.sin(w) * 0.65;
      r.legRx = -math.sin(w) * 0.65;
      r.bob = math.sin(w).abs() * 0.2;
      r.armLx = r.armRx = -1.15;
      r.armLz = r.armRz = 0.12;
      r.yaw = math.sin(t * 0.9) * 0.35 + look.dx * 0.2;
      r.headPitch = 0.05 + math.sin(w * 2) * 0.03;
      r.pupil = Offset(look.dx * 0.5, 0.2);
    case AvatarProp.book:
      r.armLx = r.armRx = -1.0;
      r.armLz = r.armRz = 0.28;
      r.headPitch = 0.38 + math.sin(t * tau * 0.5) * 0.04;
      r.headYaw = math.sin(t * tau * 0.45) * 0.18;
      r.yaw = look.dx * 0.25;
      r.propT = (t * 0.7) % 1.0;
      r.eyes = AvatarEyes.focus;
      r.pupil = Offset(math.sin(t * tau * 0.9) * 0.6, 0.6);
    case AvatarProp.palette:
      r.armLx = -0.95;
      r.armLz = 0.32;
      r.armRx = -1.35 + math.sin(t * tau * 1.3) * 0.35;
      r.armRz = 0.3 + math.sin(t * tau * 0.65) * 0.28;
      r.yaw = 0.35 + look.dx * 0.1;
      r.headYaw = 0.1;
      r.headPitch = 0.05;
      r.propT = (t * 0.15) % 1.0;
      r.eyes = AvatarEyes.focus;
      r.pupil = const Offset(0.7, 0.1);
      r.bob = math.sin(t * tau * 1.3).abs() * 0.05;
    case AvatarProp.binoculars:
      r.armLx = r.armRx = -2.3;
      r.armLz = r.armRz = 0.42;
      r.yaw = math.sin(t * tau * 0.22) * 0.85;
      r.headPitch = -0.12;
      r.pupil = Offset.zero;
  }
}

/// The pose in [state] after [st] seconds, at clock [t].
RigPose rigFor(
  AgentAvatarState state,
  double st,
  double t,
  Offset look,
  double blink, {
  double seed = 0,
}) {
  const double tau = 2 * math.pi;
  final RigPose r = RigPose(blink: blink, pupil: look);
  switch (state) {
    case AgentAvatarState.idle:
      r.yaw = look.dx * 0.55;
      r.lean = look.dy * 0.1;
      r.headYaw = look.dx * 0.45;
      r.headPitch = look.dy * 0.35;
      r.headRoll = -look.dx * 0.07;
      r.bob = math.sin(t * tau * 0.3) * 0.03;
      r.armLx = math.sin(t * tau * 0.3) * 0.06;
      r.armRx = -r.armLx;
    case AgentAvatarState.sleep:
      r.lie = _ease(st / 0.9);
      r.eyes = AvatarEyes.closed;
      r.zzz = _ease((st - 0.6) / 0.6);
      r.yaw = 0.3;
      r.armLz = r.armRz = 0.04;
      r.armLx = r.armRx = -0.25;
      r.legLx = -0.15;
      r.legRx = 0.1;
      r.headRoll = 0.15 * r.lie;
      r.headPitch = 0.35 * r.lie;
      r.squash = 0.1 * r.lie;
      r.pupil = Offset.zero;
    case AgentAvatarState.work:
      _work(r, propAt(t, seed), t, look);
      // A short squash when a prop is swapped hides the swap.
      final double sinceSwap = (t + seed * kPropSeconds) % kPropSeconds;
      if (sinceSwap < 0.3) {
        r.squash += math.sin(sinceSwap / 0.3 * math.pi) * 0.12;
      }
    case AgentAvatarState.done:
      final double p = st % kCheerSeconds;
      final double j = (p / 0.95).clamp(0.0, 1.0);
      final bool air = p < 0.95;
      r.jump = air ? math.sin(math.pi * j) * 1.25 : 0;
      r.yaw = air ? _ease(j) * 2 * math.pi : 0;
      final double land = p >= 0.95 && p < 1.25
          ? math.sin((p - 0.95) / 0.3 * math.pi)
          : 0;
      final double crouch = p < 0.12 ? math.sin(p / 0.12 * math.pi) : 0;
      r.squash = (land + crouch) * 0.14;
      r.armLz = r.armRz = air ? 2.55 : 0.5 + land * 0.5;
      r.legLx = air ? -0.45 * math.sin(math.pi * j) : 0;
      r.legRx = air ? 0.45 * math.sin(math.pi * j) : 0;
      r.eyes = AvatarEyes.happy;
      r.headPitch = -0.15;
  }
  return r;
}

/// The rig for [p], blending out of the state before.
RigPose rigForPose(AvatarPose p) {
  final Offset look = clampLook(p.look);
  final RigPose now = rigFor(
    p.state,
    p.stateT,
    p.t,
    look,
    p.blink,
    seed: p.seed,
  );
  final double e = _ease(p.stateT / 0.45);
  if (e >= 1 || p.prev == p.state) return now;
  final RigPose before = rigFor(
    p.prev,
    p.prevT,
    p.t,
    look,
    p.blink,
    seed: p.seed,
  );
  return RigPose.lerp(before, now, e);
}

/// Poses every move must fit in: looking around, each prop, asleep, the top
/// of the cheer.
List<RigPose> fitPoses() => <RigPose>[
  for (final Offset l in const <Offset>[
    Offset(0.9, 0),
    Offset(-0.9, 0),
    Offset(0, -0.9),
    Offset(0, 0.9),
  ])
    rigFor(AgentAvatarState.idle, 10, 0, l, 0),
  for (int k = 0; k < kWorkProps.length; k++)
    for (final double dt in const <double>[0.1, 0.35, 0.6, 2.1, 3.3])
      rigFor(AgentAvatarState.work, 10, k * kPropSeconds + dt, Offset.zero, 0),
  rigFor(AgentAvatarState.sleep, 10, 0, Offset.zero, 1),
  for (final double st in const <double>[0.3, 0.475, 0.65])
    rigFor(AgentAvatarState.done, st, 0, Offset.zero, 0),
];
