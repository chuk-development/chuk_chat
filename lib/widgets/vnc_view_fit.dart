import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';

/// Where the remote framebuffer sits on the screen, and how to convert between
/// the two coordinate spaces.
///
/// The browser view used to be nailed to `FittedBox(fit: BoxFit.contain)`: one
/// scale, no zoom, and the trackpad overlay recomputed that same contain fit by
/// hand so its virtual cursor landed on the right remote pixel. Two places had
/// to agree, and neither could zoom.
///
/// This is the one place that agrees. The overlay paints the framebuffer at
/// [rect] and maps every touch through [toFrameBuffer], so a click lands on the
/// same remote pixel at any zoom and any pan — that is the whole contract, and
/// `test/vnc/view_fit_test.dart` checks it at several zoom steps.
///
/// Coordinate spaces:
///   framebuffer px  the remote screen, 0..width-1 / 0..height-1
///   screen px       logical pixels inside the overlay box
@immutable
class VncViewFit {
  const VncViewFit({
    required this.scale,
    required this.origin,
    required this.size,
  });

  /// A fit that paints nothing, for before the framebuffer size is known.
  static const VncViewFit empty = VncViewFit(
    scale: 1,
    origin: Offset.zero,
    size: Size.zero,
  );

  /// The smallest zoom: 1 is "show the whole screen", so the picture can never
  /// be smaller than the box that holds it.
  static const double minZoom = 1;

  /// The largest zoom. Eight times a contain fit is already far past the point
  /// where a 1280-wide remote screen shows single pixels on a phone.
  static const double maxZoom = 8;

  /// Framebuffer pixels to screen pixels.
  final double scale;

  /// Where framebuffer pixel (0, 0) is painted, in screen pixels.
  final Offset origin;

  /// The painted size of the whole framebuffer, in screen pixels.
  final Size size;

  Rect get rect => origin & size;

  /// The screen point that shows framebuffer point [point].
  Offset toScreen(Offset point) =>
      Offset(origin.dx + point.dx * scale, origin.dy + point.dy * scale);

  /// The framebuffer point under screen point [point].
  Offset toFrameBuffer(Offset point) =>
      Offset((point.dx - origin.dx) / scale, (point.dy - origin.dy) / scale);

  /// The scale that fits the whole framebuffer into [box] (a contain fit).
  static double baseScale({required Size box, required Size frameBuffer}) {
    if (box.isEmpty || frameBuffer.isEmpty) return 1;
    return math.min(
      box.width / frameBuffer.width,
      box.height / frameBuffer.height,
    );
  }

  /// The fit for a framebuffer of [frameBuffer] shown in [box] at [zoom], moved
  /// by [pan] screen pixels away from the centred position.
  ///
  /// [pan] is clamped: an axis that still fits in the box stays centred, and an
  /// axis that does not can never be dragged past its own edge. So the picture
  /// never floats away from the box, whatever the gesture asked for.
  static VncViewFit compute({
    required Size box,
    required Size frameBuffer,
    double zoom = 1,
    Offset pan = Offset.zero,
  }) {
    if (box.isEmpty || frameBuffer.isEmpty) return empty;
    final double scale =
        baseScale(box: box, frameBuffer: frameBuffer) *
        zoom.clamp(minZoom, maxZoom);
    final Size shown = Size(
      frameBuffer.width * scale,
      frameBuffer.height * scale,
    );
    return VncViewFit(
      scale: scale,
      origin: Offset(
        _axisOrigin(box.width, shown.width, pan.dx),
        _axisOrigin(box.height, shown.height, pan.dy),
      ),
      size: shown,
    );
  }

  /// The pan that puts framebuffer point [framebufferPoint] under screen point
  /// [screenPoint] at [zoom]. This is what keeps a pinch anchored: take the
  /// framebuffer point under the fingers before the pinch, ask for it to stay
  /// under the fingers after it.
  static Offset panFor({
    required Size box,
    required Size frameBuffer,
    required double zoom,
    required Offset framebufferPoint,
    required Offset screenPoint,
  }) {
    if (box.isEmpty || frameBuffer.isEmpty) return Offset.zero;
    final double scale =
        baseScale(box: box, frameBuffer: frameBuffer) *
        zoom.clamp(minZoom, maxZoom);
    final Size shown = Size(
      frameBuffer.width * scale,
      frameBuffer.height * scale,
    );
    return Offset(
      screenPoint.dx - framebufferPoint.dx * scale - (box.width - shown.width) / 2,
      screenPoint.dy -
          framebufferPoint.dy * scale -
          (box.height - shown.height) / 2,
    );
  }

  /// A pan that brings [framebufferPoint] back inside the box, with [margin]
  /// screen pixels of air around it where there is room to give.
  ///
  /// This is how the view follows the virtual cursor: zoomed in, the cursor can
  /// be nudged off the visible part of the remote screen, and losing it is the
  /// fastest way to make a zoom useless. The returned pan is always the
  /// CLAMPED one, so repeated calls cannot pile up an offset that does nothing.
  static Offset panToKeepVisible({
    required Size box,
    required Size frameBuffer,
    required double zoom,
    required Offset pan,
    required Offset framebufferPoint,
    double margin = 56,
  }) {
    if (box.isEmpty || frameBuffer.isEmpty) return pan;
    final VncViewFit fit = compute(
      box: box,
      frameBuffer: frameBuffer,
      zoom: zoom,
      pan: pan,
    );
    // The pan actually in force after clamping, so the caller's stored pan is
    // normalised on every call instead of drifting.
    final Offset effective = Offset(
      fit.origin.dx - (box.width - fit.size.width) / 2,
      fit.origin.dy - (box.height - fit.size.height) / 2,
    );
    final Offset point = fit.toScreen(framebufferPoint);
    final double marginX = math.min(margin, box.width / 3);
    final double marginY = math.min(margin, box.height / 3);
    double dx = 0;
    double dy = 0;
    if (point.dx < marginX) {
      dx = marginX - point.dx;
    } else if (point.dx > box.width - marginX) {
      dx = box.width - marginX - point.dx;
    }
    if (point.dy < marginY) {
      dy = marginY - point.dy;
    } else if (point.dy > box.height - marginY) {
      dy = box.height - marginY - point.dy;
    }
    return effective + Offset(dx, dy);
  }

  static double _axisOrigin(double box, double shown, double pan) {
    final double centred = (box - shown) / 2;
    if (shown <= box) return centred;
    return (centred + pan).clamp(box - shown, 0.0);
  }

  @override
  bool operator ==(Object other) =>
      other is VncViewFit &&
      other.scale == scale &&
      other.origin == origin &&
      other.size == size;

  @override
  int get hashCode => Object.hash(scale, origin, size);

  @override
  String toString() => 'VncViewFit(scale: $scale, origin: $origin, size: $size)';
}
