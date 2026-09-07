import 'dart:ui';

import 'package:cowork/widgets/vnc_trackpad_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rfb/flutter_rfb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the pointer/click/scroll calls the overlay makes, standing in for
/// the real RFB isolate. The framebuffer is a fixed 800x600 so the maths is
/// easy to assert; laid into a 400x300 box the contain-fit scale is 0.5.
class _SpyController extends RemoteFrameBufferController {
  final List<String> events = <String>[];

  @override
  bool get isReady => true;

  @override
  Size? get frameBufferSize => const Size(800, 600);

  @override
  void pointer({
    required final int x,
    required final int y,
    final Set<int> buttons = const <int>{},
  }) {
    final List<int> b = buttons.toList()..sort();
    events.add('p $x,$y $b');
  }

  @override
  void click({
    required final int x,
    required final int y,
    final int button = 1,
  }) {
    events.add('c $x,$y b$button');
  }
}

Future<void> _pump(WidgetTester tester, _SpyController c) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: VncTrackpadOverlay(
              controller: c,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // Help card already dismissed, so it never covers the touch surface.
    SharedPreferences.setMockInitialValues(
      <String, Object>{'vnc_trackpad_help_seen_v1': true},
    );
  });

  testWidgets('tap left-clicks at the centred cursor', (tester) async {
    final _SpyController c = _SpyController();
    await _pump(tester, c);

    // Cursor seeds to framebuffer centre (400,300); a tap at the box centre
    // does not move it, so the click lands there.
    await tester.tap(find.byType(VncTrackpadOverlay));
    await tester.pump();

    expect(c.events, contains('c 400,300 b1'));
  });

  testWidgets('one-finger drag moves the cursor, no click', (tester) async {
    final _SpyController c = _SpyController();
    await _pump(tester, c);

    // Drag right by 40 screen px. Scale 0.5 -> cursor +80 fb px: 400 -> 480.
    await tester.drag(find.byType(VncTrackpadOverlay), const Offset(40, 0));
    await tester.pump();

    // Ended on a move, so no click was emitted.
    expect(c.events.any((e) => e.startsWith('c ')), isFalse);
    // A pointer move reached the right edge of the travel.
    expect(c.events.any((e) => e.startsWith('p 480,300')), isTrue);
  });

  testWidgets('two-finger tap right-clicks at the cursor', (tester) async {
    final _SpyController c = _SpyController();
    await _pump(tester, c);

    final Offset center = tester.getCenter(find.byType(VncTrackpadOverlay));
    final TestGesture g1 = await tester.createGesture();
    final TestGesture g2 = await tester.createGesture();
    await g1.down(center);
    await tester.pump();
    await g2.down(center + const Offset(30, 0));
    await tester.pump();
    await g1.up();
    await tester.pump();
    await g2.up();
    await tester.pump();

    expect(c.events, contains('c 400,300 b3'));
    expect(c.events.contains('c 400,300 b1'), isFalse);
  });

  testWidgets('two-finger drag scrolls, does not click', (tester) async {
    final _SpyController c = _SpyController();
    await _pump(tester, c);

    final Offset center = tester.getCenter(find.byType(VncTrackpadOverlay));
    final TestGesture g1 = await tester.createGesture();
    final TestGesture g2 = await tester.createGesture();
    await g1.down(center);
    await g2.down(center + const Offset(30, 0));
    await tester.pump();
    // Move both fingers up by 60 px -> centroid up 60 -> >= 2 notches down.
    for (int i = 0; i < 6; i++) {
      await g1.moveBy(const Offset(0, -10));
      await g2.moveBy(const Offset(0, -10));
      await tester.pump();
    }
    await g1.up();
    await g2.up();
    await tester.pump();

    // Fingers up -> wheel down = button 5, pressed then released.
    expect(c.events.any((e) => e.contains('[5]')), isTrue);
    expect(c.events.any((e) => e.startsWith('c ')), isFalse);
  });
}
