import 'package:cowork/widgets/vnc_trackpad_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rfb/flutter_rfb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the pointer/click/key calls the overlay makes, standing in for
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

  @override
  void key({required final bool down, required final int key}) {
    events.add('k $key ${down ? 'down' : 'up'}');
  }

  /// The last left click, as a framebuffer point.
  String? get lastLeftClick =>
      events.lastWhere((String e) => e.endsWith('b1'), orElse: () => '');
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
              // The overlay places the picture itself now, so what it is given
              // is the bare framebuffer widget at its native size.
              child: const SizedBox(
                width: 800,
                height: 600,
                child: ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pinches the two fingers apart (or together) by [factor] about the centre of
/// the overlay. The fingers move symmetrically, so the centroid never shifts
/// and the resulting zoom is exactly [factor].
Future<void> _pinch(WidgetTester tester, double factor) async {
  final Offset centre = tester.getCenter(find.byType(VncTrackpadOverlay));
  const double half = 50;
  final TestGesture left = await tester.createGesture();
  final TestGesture right = await tester.createGesture();
  await left.down(centre - const Offset(half, 0));
  await tester.pump();
  await right.down(centre + const Offset(half, 0));
  await tester.pump();
  const int steps = 4;
  for (int i = 1; i <= steps; i++) {
    final double reach = half + (half * factor - half) * i / steps;
    await left.moveTo(centre - Offset(reach, 0));
    await right.moveTo(centre + Offset(reach, 0));
    await tester.pump();
  }
  await left.up();
  await tester.pump();
  await right.up();
  await tester.pump();
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

  // The point of the whole exercise: zooming must not move the target. A drag
  // of N screen pixels moves the cursor N / scale framebuffer pixels, and the
  // click that follows lands exactly there.
  group('a click lands on the right remote pixel', () {
    testWidgets('at zoom 1', (tester) async {
      final _SpyController c = _SpyController();
      await _pump(tester, c);

      // Scale 0.5: 40 screen px -> 80 fb px, 20 -> 40.
      await tester.drag(find.byType(VncTrackpadOverlay), const Offset(40, 20));
      await tester.pump();
      await tester.tap(find.byType(VncTrackpadOverlay));
      await tester.pump();

      expect(c.lastLeftClick, 'c 480,340 b1');
    });

    testWidgets('at zoom 2', (tester) async {
      final _SpyController c = _SpyController();
      await _pump(tester, c);
      await _pinch(tester, 2);
      expect(find.text('200%'), findsOneWidget);

      // Scale 1.0 now: the cursor tracks the finger one for one.
      c.events.clear();
      await tester.drag(find.byType(VncTrackpadOverlay), const Offset(40, 20));
      await tester.pump();
      await tester.tap(find.byType(VncTrackpadOverlay));
      await tester.pump();

      expect(c.lastLeftClick, 'c 440,320 b1');
    });

    testWidgets('at zoom 3', (tester) async {
      final _SpyController c = _SpyController();
      await _pump(tester, c);
      await _pinch(tester, 3);
      expect(find.text('300%'), findsOneWidget);

      // Scale 1.5: 30 screen px -> 20 fb px, 15 -> 10.
      c.events.clear();
      await tester.drag(find.byType(VncTrackpadOverlay), const Offset(30, 15));
      await tester.pump();
      await tester.tap(find.byType(VncTrackpadOverlay));
      await tester.pump();

      expect(c.lastLeftClick, 'c 420,310 b1');
    });

    testWidgets('at zoom 2 after the view has panned to follow the cursor', (
      tester,
    ) async {
      final _SpyController c = _SpyController();
      await _pump(tester, c);
      await _pinch(tester, 2);

      // Far enough right that the cursor would leave the box: the view pans to
      // keep it, and the mapping has to survive that pan.
      c.events.clear();
      await tester.drag(find.byType(VncTrackpadOverlay), const Offset(250, 0));
      await tester.pump();
      await tester.tap(find.byType(VncTrackpadOverlay));
      await tester.pump();

      expect(c.lastLeftClick, 'c 650,300 b1');
    });
  });

  testWidgets('the zoom chip only exists while zoomed, and fits back', (
    tester,
  ) async {
    final _SpyController c = _SpyController();
    await _pump(tester, c);
    expect(find.byKey(const Key('vnc_trackpad_zoom_chip')), findsNothing);

    await _pinch(tester, 2);
    expect(find.byKey(const Key('vnc_trackpad_zoom_chip')), findsOneWidget);

    await tester.tap(find.byKey(const Key('vnc_trackpad_zoom_chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vnc_trackpad_zoom_chip')), findsNothing);

    // Back to the contain fit: 40 screen px is 80 framebuffer px again.
    c.events.clear();
    await tester.drag(find.byType(VncTrackpadOverlay), const Offset(40, 0));
    await tester.pump();
    await tester.tap(find.byType(VncTrackpadOverlay));
    await tester.pump();
    expect(c.lastLeftClick, 'c 480,300 b1');
  });

  testWidgets('a pinch in never shrinks the picture below the whole screen', (
    tester,
  ) async {
    final _SpyController c = _SpyController();
    await _pump(tester, c);

    await _pinch(tester, 0.4);
    expect(find.byKey(const Key('vnc_trackpad_zoom_chip')), findsNothing);

    // Still the contain fit, so the mapping is unchanged.
    c.events.clear();
    await tester.drag(find.byType(VncTrackpadOverlay), const Offset(40, 0));
    await tester.pump();
    await tester.tap(find.byType(VncTrackpadOverlay));
    await tester.pump();
    expect(c.lastLeftClick, 'c 480,300 b1');
  });

  testWidgets('the keyboard button sends what is typed as X keysyms', (
    tester,
  ) async {
    final _SpyController c = _SpyController();
    await _pump(tester, c);

    await tester.tap(find.byKey(const Key('vnc_trackpad_keyboard_button')));
    await tester.pumpAndSettle();

    c.events.clear();
    // The field holds one invisible sentinel; the IME appends to it.
    await tester.enterText(
      find.byKey(const Key('vnc_trackpad_key_field')),
      '​hi',
    );
    await tester.pump();
    expect(c.events, <String>['k 104 down', 'k 104 up', 'k 105 down',
      'k 105 up']);

    // Deleting the sentinel is the backspace the remote screen never sees
    // otherwise.
    c.events.clear();
    await tester.enterText(find.byKey(const Key('vnc_trackpad_key_field')), '');
    await tester.pump();
    expect(c.events, <String>['k 65288 down', 'k 65288 up']);

    // And the bar carries the keys a phone keyboard has no room for.
    c.events.clear();
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();
    expect(c.events, <String>['k 65307 down', 'k 65307 up']);
  });
}
