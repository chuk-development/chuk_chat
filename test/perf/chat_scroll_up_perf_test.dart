// Speed test for scrolling UP through a long chat.
//
// The owner reported that scrolling up in a long Agents thread lags, most of
// all at the start of the scroll. The Agents thread is the bottom-anchored
// transcript (`ChatScrollMixin.buildAnchoredTranscript`): it opens at the
// bottom and builds only the visible tail, so every row above the viewport
// is built for the FIRST time while the reader scrolls up. This test puts the
// same pieces on screen as the mobile chat — the anchored transcript, the
// shared SelectionCopyArea around it, `MessageRenderCache` and the real
// `ChatMessageListItem`/`MessageBubble` rows — with 300 mixed messages, then
// drags upwards frame by frame and times each frame.
//
// The numbers are wall clock on the test machine in debug mode, so they are a
// shape, not a phone figure. The test prints them and asserts nothing about
// speed; it only checks that the scroll really moved.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

import 'chat_scroll_fixture.dart';
import 'perf_support.dart';

void main() {
  setUp(() {
    debugAgentsChatCoreOverride = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MessageRenderCache.debugClearShared();
    MarkdownMessage.clearCaches();
  });
  tearDown(() => debugAgentsChatCoreOverride = null);

  testWidgets('scrolling up a 300-message chat, frame by frame', (
    tester,
  ) async {
    // Pixel 7 Pro in logical pixels.
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messages = scrollPerfTranscript();
    await tester.pumpWidget(perfApp(ScrollPerfHost(messages: messages)));
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final double startPixels = scrollable.position.pixels;

    // A reader's drag: 40 px per frame (2400 px/s), 240 frames ~ 9600 px.
    final List<double> frameMs = <double>[];
    final List<double> firstFramesMs = <double>[];
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(Scrollable).first),
    );
    // The touch slop comes first, as on a phone.
    await gesture.moveBy(const Offset(0, 20));
    for (int f = 0; f < 240; f++) {
      await gesture.moveBy(const Offset(0, 40));
      final Stopwatch watch = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      watch.stop();
      final double ms = watch.elapsedMicroseconds / 1000.0;
      frameMs.add(ms);
      if (f < 10) firstFramesMs.add(ms);
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));

    // A fling up from where the drag stopped, timed until it settles.
    final List<double> flingMs = <double>[];
    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, 400),
      3000,
    );
    for (int f = 0; f < 120; f++) {
      final Stopwatch watch = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      watch.stop();
      flingMs.add(watch.elapsedMicroseconds / 1000.0);
    }

    final double moved = startPixels - scrollable.position.pixels;
    expect(moved, greaterThan(3000));

    int jank(List<double> s) => s.where((double v) => v > 16).length;
    double mean(List<double> s) => s.reduce((a, b) => a + b) / s.length;
    final table = PerfTable('Scroll up, $scrollPerfMessageCount messages, 412x892')
      ..add(
        'drag frames (240)',
        frameMs,
        note:
            'mean ${mean(frameMs).toStringAsFixed(2)} ms, >16ms: ${jank(frameMs)}',
      )
      ..add(
        'first 10 drag frames',
        firstFramesMs,
        note: 'mean ${mean(firstFramesMs).toStringAsFixed(2)} ms',
      )
      ..add(
        'fling frames (120)',
        flingMs,
        note:
            'mean ${mean(flingMs).toStringAsFixed(2)} ms, >16ms: ${jank(flingMs)}',
      );
    table.report();
    debugPrint('moved ${moved.toStringAsFixed(0)} px');
  });
}
