// Speed and smoothness test of the DESKTOP chat (`ChukChatUIDesktop`, the
// plain chat) with a 330-row chat: mouse-wheel scrolling up, a fling up, and
// jumps through the message rail (the minimap) between far messages.
//
// Wall clock in debug mode on the test machine: a shape, not a device
// figure. The profile numbers come from
// `integration_test/chat_desktop_scroll_perf_test.dart`. Asserted: the
// scrolls really move, a wheel scroll moves in small steps on every frame
// (no 53 px jumps with standing frames between them), and a rail jump lands
// its message at the top.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/widgets/chat_turn_rail.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

import 'chat_desktop_perf_fixture.dart';
import 'chat_scroll_screen_fixture.dart';
import 'perf_support.dart';

const Timeout _guard = Timeout(Duration(minutes: 5));

int _jank(List<double> s) => s.where((double v) => v > 16).length;
double _mean(List<double> s) => s.reduce((a, b) => a + b) / s.length;
double _p(List<double> s, double q) {
  final List<double> sorted = List<double>.of(s)..sort();
  return sorted[((sorted.length - 1) * q).round()];
}

String _note(List<double> s) =>
    'mean ${_mean(s).toStringAsFixed(1)} p90 ${_p(s, .9).toStringAsFixed(1)} '
    'p99 ${_p(s, .99).toStringAsFixed(1)} >16ms ${_jank(s)}';

Future<double> _timedPump(WidgetTester tester) async {
  final Stopwatch w = Stopwatch()..start();
  await tester.pump(const Duration(milliseconds: 16));
  w.stop();
  return w.elapsedMicroseconds / 1000.0;
}

void main() {
  setUp(() async {
    debugAgentsChatCoreOverride = true;
    await resetScreenWorld();
    MessageRenderCache.debugClearShared();
    MarkdownMessage.clearCaches();
  });
  tearDown(() async {
    debugAgentsChatCoreOverride = null;
    removeDesktopPerfChat();
    await MultiplexSession.shutdown();
    await resetScreenWorld();
  });

  testWidgets('desktop chat: wheel up, fling up, rail jumps', (tester) async {
    silenceUnrelatedPlugins(tester);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    seedDesktopPerfChat();
    await tester.pumpWidget(desktopPerfScreen());
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final ScrollPosition position = desktopChatPosition(tester);
    expect(position.maxScrollExtent - position.pixels, lessThan(1));
    final Offset centre = tester.getCenter(find.byType(Scaffold).first);

    // 1. Mouse wheel up: one 53 px notch (GTK's step) every third frame,
    // 120 notches.
    final OffsetSampler wheel = OffsetSampler(position)..start();
    final TestPointer mouse = TestPointer(7, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(centre));
    final List<double> wheelMs = <double>[];
    final double wheelStart = position.pixels;
    for (int f = 0; f < 360; f++) {
      if (f % 3 == 0) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -53)));
      }
      wheelMs.add(await _timedPump(tester));
    }
    for (int f = 0; f < 30; f++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    wheel.stop();
    final double wheelMoved = wheelStart - position.pixels;
    final smooth = wheelSmoothness(wheel.steps);

    // 2. A plain rebuild of the screen (what a stream tick or the composer
    // does): the rows must come back from the row memo, not be rebuilt.
    final List<double> rebuildMs = <double>[];
    for (int k = 0; k < 10; k++) {
      tester.element(find.byType(ChukChatUIDesktop)).markNeedsBuild();
      rebuildMs.add(await _timedPump(tester));
    }

    // 3. Fling up, five times.
    final List<double> flingMs = <double>[];
    for (int n = 0; n < 5; n++) {
      await tester.flingFrom(centre, const Offset(0, 300), 2500);
      for (int f = 0; f < 60; f++) {
        flingMs.add(await _timedPump(tester));
      }
    }

    // 4. Rail jumps between far messages: first, last, and back and forth.
    final List<double> jumpMs = <double>[];
    final List<double> jumpWorst = <double>[];
    final List<int> order = <int>[0, -1, 3, -4, 1, -2, 10, -10];
    double worstLanding = 0;
    for (final int pick in order) {
      final List<Rect> strips = desktopRailStrips(tester);
      final int i = pick < 0 ? strips.length + pick : pick;
      final TestGesture tap = await tester.startGesture(
        strips[i].center,
        kind: PointerDeviceKind.mouse,
      );
      await tap.up();
      final List<double> frames = <double>[];
      for (int f = 0; f < 40; f++) {
        frames.add(await _timedPump(tester));
      }
      jumpMs.addAll(frames);
      jumpWorst.add(frames.reduce((a, b) => a > b ? a : b));
      await tap.removePointer();
      // The message lands 24 px below the top of the list.
      final ChatTurnRail rail = tester.widget(find.byType(ChatTurnRail));
      final int row = chatTurnRailTicks(rail.messages)[i].index;
      final Finder target = find.byWidgetPredicate(
        (Widget w) =>
            w is KeyedSubtree &&
            w.key is GlobalKey &&
            w.key.toString().endsWith(' turn $row]'),
      );
      expect(target, findsOneWidget, reason: 'strip $i (row $row)');
      final double off = (tester.getTopLeft(target).dy - 24).abs();
      if (off > worstLanding) worstLanding = off;
    }

    PerfTable('desktop chat 1440x900, 330 rows (debug wall clock)')
      ..add('wheel up, 360 frames', wheelMs, note: _note(wheelMs))
      ..add('screen rebuild x10', rebuildMs, note: _note(rebuildMs))
      ..add('fling up x5, 300 frames', flingMs, note: _note(flingMs))
      ..add('rail jumps x8, 40 frames each', jumpMs, note: _note(jumpMs))
      ..add('rail jump worst frame', jumpWorst)
      ..report();
    debugPrint(
      'wheel: moved ${wheelMoved.round()} px, max step '
      '${smooth.maxStep.toStringAsFixed(1)} px, still frames '
      '${(smooth.stillShare * 100).toStringAsFixed(0)}% of ${smooth.frames}',
    );

    debugPrint('rail: worst landing ${worstLanding.toStringAsFixed(1)} px off');

    expect(wheelMoved, greaterThan(2000));
    // A wheel glides: no notch-sized jumps, no standing frames.
    expect(smooth.maxStep, lessThan(40));
    expect(smooth.stillShare, lessThan(0.05));
    expect(worstLanding, lessThan(2));

    await releaseIdleTimers(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }, timeout: _guard);
}
