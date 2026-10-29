// Speed test for scrolling UP through a long Agents thread, on the REAL chat
// screen: `MessengerShell` with one agent whose thread holds 300 mixed
// messages (markdown, lists, tables, code, tool calls), at phone size. It
// drags upwards frame by frame and times each frame, then flings.
//
// `chat_scroll_up_perf_test.dart` measures the list alone; this one also pays
// for everything the screen does around it (its setState calls, the jump
// button, the composer). Wall clock in debug mode on the test machine: a
// shape, not a phone figure. Nothing is asserted about speed.
//
// The store's SQLite is replaced by a map, see `perf_support.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

import 'chat_scroll_fixture.dart';
import 'chat_scroll_screen_fixture.dart';
import 'perf_support.dart';

const Timeout _guard = Timeout(Duration(minutes: 5));

void main() {
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);
  ChatOrigin.agentsEnabled = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDisk disk;

  setUp(() async {
    await resetScreenWorld();
    disk = FakeDisk();
  });

  tearDown(() async {
    await MultiplexSession.shutdown();
    await resetScreenWorld();
  });

  testWidgets('scrolling up a 300-message Agents thread on the real screen', (
    tester,
  ) async {
    silenceUnrelatedPlugins(tester);
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ScrollableState scrollable = await mountRealScreenThread(
      tester,
      disk,
    );
    final Finder list = find.byWidgetPredicate(
      (w) =>
          w is CustomScrollView &&
          w.center == const ValueKey<String>('chat-transcript-center'),
    );
    final double start = scrollable.position.pixels;

    Future<List<double>> drag() async {
      final List<double> ms = <double>[];
      final TestGesture g = await tester.startGesture(
        tester.getCenter(list.first),
      );
      await g.moveBy(const Offset(0, 20));
      final List<String> dirty = <String>[];
      debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
        dirty.add(e.widget.runtimeType.toString());
      };
      for (int f = 0; f < 200; f++) {
        await g.moveBy(const Offset(0, 40));
        dirty.clear();
        final Stopwatch w = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 16));
        w.stop();
        ms.add(w.elapsedMicroseconds / 1000.0);
        if (const bool.fromEnvironment('PERF_DIRTY') && ms.last > 8) {
          final Map<String, int> c = <String, int>{};
          for (final String d in dirty) {
            c[d] = (c[d] ?? 0) + 1;
          }
          debugPrint('DIRTY f$f ${ms.last.toStringAsFixed(1)}ms $c');
        }
      }
      debugOnRebuildDirtyWidget = null;
      await g.up();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      return ms;
    }

    final List<double> frames = await drag();
    final double moved = start - scrollable.position.pixels;
    expect(moved, greaterThan(3000));

    int jank(List<double> s) => s.where((double v) => v > 16).length;
    double mean(List<double> s) => s.reduce((a, b) => a + b) / s.length;
    PerfTable('real screen: scroll up, $scrollPerfMessageCount msgs, 412x892')
      ..add(
        'drag frames (200)',
        frames,
        note: 'mean ${mean(frames).toStringAsFixed(2)}, >16ms: ${jank(frames)}',
      )
      ..add(
        'first 10 drag frames',
        frames.sublist(0, 10),
        note: 'mean ${mean(frames.sublist(0, 10)).toStringAsFixed(2)}',
      )
      ..report();
    debugPrint('moved ${moved.toStringAsFixed(0)} px');
    debugPrint('FRAMES ${frames.map((v) => v.toStringAsFixed(1)).join(" ")}');

    await releaseIdleTimers(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }, timeout: _guard);
}
