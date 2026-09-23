import 'dart:ui';

import 'package:chuk_chat/widgets/vnc_view_fit.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mapping the whole browser view rests on: a touch has to reach the remote
/// pixel under it at EVERY zoom and pan, or the agent's screen gets clicked
/// somewhere the user never pointed.
///
/// A 800x600 framebuffer in a 400x300 box makes the contain scale exactly 0.5,
/// so every number below can be read by hand.
void main() {
  const Size box = Size(400, 300);
  const Size fb = Size(800, 600);

  group('the fit', () {
    test('shows the whole picture, centred, at zoom 1', () {
      final VncViewFit fit = VncViewFit.compute(box: box, frameBuffer: fb);
      expect(fit.scale, 0.5);
      expect(fit.origin, Offset.zero);
      expect(fit.size, const Size(400, 300));
    });

    test('centres the short axis when the shapes differ', () {
      final VncViewFit fit = VncViewFit.compute(
        box: const Size(400, 400),
        frameBuffer: fb,
      );
      expect(fit.scale, 0.5);
      expect(fit.origin, const Offset(0, 50));
    });

    test('is empty before the framebuffer size is known', () {
      expect(
        VncViewFit.compute(box: box, frameBuffer: Size.zero),
        VncViewFit.empty,
      );
    });
  });

  group('a touch lands on the right remote pixel', () {
    void expectMaps(
      VncViewFit fit,
      Offset screen,
      Offset framebuffer,
    ) {
      final Offset mapped = fit.toFrameBuffer(screen);
      expect(mapped.dx, closeTo(framebuffer.dx, 0.001));
      expect(mapped.dy, closeTo(framebuffer.dy, 0.001));
      // And back again: the two directions are one mapping, not two.
      final Offset back = fit.toScreen(mapped);
      expect(back.dx, closeTo(screen.dx, 0.001));
      expect(back.dy, closeTo(screen.dy, 0.001));
    }

    test('at zoom 1', () {
      expectMaps(
        VncViewFit.compute(box: box, frameBuffer: fb),
        const Offset(100, 60),
        const Offset(200, 120),
      );
    });

    test('at zoom 2, centred', () {
      final VncViewFit fit = VncViewFit.compute(
        box: box,
        frameBuffer: fb,
        zoom: 2,
      );
      expect(fit.scale, 1.0);
      expect(fit.origin, const Offset(-200, -150));
      expectMaps(fit, const Offset(100, 60), const Offset(300, 210));
    });

    test('at zoom 2, panned', () {
      final VncViewFit fit = VncViewFit.compute(
        box: box,
        frameBuffer: fb,
        zoom: 2,
        pan: const Offset(-100, -50),
      );
      expect(fit.origin, const Offset(-300, -200));
      expectMaps(fit, const Offset(100, 60), const Offset(400, 260));
    });

    test('at zoom 3, panned', () {
      final VncViewFit fit = VncViewFit.compute(
        box: box,
        frameBuffer: fb,
        zoom: 3,
        pan: const Offset(60, 40),
      );
      expect(fit.scale, 1.5);
      expect(fit.origin, const Offset(-340, -260));
      expectMaps(
        fit,
        const Offset(100, 60),
        Offset(440 / 1.5, 320 / 1.5),
      );
    });
  });

  group('the pan', () {
    test('cannot drag the picture past its own edge', () {
      final VncViewFit far = VncViewFit.compute(
        box: box,
        frameBuffer: fb,
        zoom: 2,
        pan: const Offset(9999, -9999),
      );
      // Left edge of the picture at the left edge of the box, and the bottom
      // edge at the bottom.
      expect(far.origin, const Offset(0, -300));
    });

    test('is ignored on an axis that still fits', () {
      // A wide box: at zoom 1 the picture is narrower than the box, so the
      // horizontal pan stays centred whatever the gesture asked for.
      final VncViewFit fit = VncViewFit.compute(
        box: const Size(600, 300),
        frameBuffer: fb,
        pan: const Offset(120, 0),
      );
      expect(fit.origin.dx, 100);
    });
  });

  group('panFor', () {
    test('keeps the pinched point under the fingers', () {
      const Offset fingers = Offset(120, 90);
      final VncViewFit before = VncViewFit.compute(box: box, frameBuffer: fb);
      final Offset anchor = before.toFrameBuffer(fingers);
      final Offset pan = VncViewFit.panFor(
        box: box,
        frameBuffer: fb,
        zoom: 2.5,
        framebufferPoint: anchor,
        screenPoint: fingers,
      );
      final VncViewFit after = VncViewFit.compute(
        box: box,
        frameBuffer: fb,
        zoom: 2.5,
        pan: pan,
      );
      expect(after.toScreen(anchor).dx, closeTo(fingers.dx, 0.001));
      expect(after.toScreen(anchor).dy, closeTo(fingers.dy, 0.001));
    });
  });

  group('panToKeepVisible', () {
    test('brings a point that ran off the right edge back inside', () {
      const double margin = 56;
      const Offset cursor = Offset(650, 300);
      final Offset pan = VncViewFit.panToKeepVisible(
        box: box,
        frameBuffer: fb,
        zoom: 2,
        pan: Offset.zero,
        framebufferPoint: cursor,
        margin: margin,
      );
      final VncViewFit fit = VncViewFit.compute(
        box: box,
        frameBuffer: fb,
        zoom: 2,
        pan: pan,
      );
      expect(fit.toScreen(cursor).dx, closeTo(box.width - margin, 0.001));
    });

    test('leaves a point that is already comfortable alone', () {
      final Offset pan = VncViewFit.panToKeepVisible(
        box: box,
        frameBuffer: fb,
        zoom: 2,
        pan: Offset.zero,
        framebufferPoint: const Offset(400, 300),
      );
      expect(pan, Offset.zero);
    });
  });
}
