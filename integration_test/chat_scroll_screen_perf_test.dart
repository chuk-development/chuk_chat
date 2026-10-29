// Scroll-up speed test of the REAL chat screen on a device, in a profile
// build: `MessengerShell` with one 300-message Agents thread (see
// `test/perf/chat_scroll_screen_fixture.dart`), measured with the engine's
// FrameTiming. Run:
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/chat_scroll_screen_perf_test.dart
//
// It reports the whole drag and, on their own, its first 30 frames: the
// stretch where the jump button appears and the first unbuilt rows come in.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

import '../test/perf/chat_scroll_screen_fixture.dart';
import '../test/perf/perf_support.dart';

Map<String, Object> _summary(List<FrameTiming> t) {
  double ms(Duration d) => d.inMicroseconds / 1000.0;
  final build = t.map((f) => ms(f.buildDuration)).toList()..sort();
  final raster = t.map((f) => ms(f.rasterDuration)).toList()..sort();
  double avg(List<double> s) => s.reduce((a, b) => a + b) / s.length;
  double p(List<double> s, double q) => s[((s.length - 1) * q).round()];
  String f(double v) => v.toStringAsFixed(2);
  return <String, Object>{
    'frames': t.length,
    'build_avg_ms': f(avg(build)),
    'build_p90_ms': f(p(build, 0.9)),
    'build_p99_ms': f(p(build, 0.99)),
    'build_worst_ms': f(build.last),
    'raster_avg_ms': f(avg(raster)),
    'raster_worst_ms': f(raster.last),
    'jank_build_over_8ms': build.where((v) => v > 8.0).length,
    'jank_build_over_16ms': build.where((v) => v > 16.0).length,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  ChatOrigin.agentsEnabled = true;

  testWidgets('scroll up the real chat screen', (tester) async {
    debugAgentsChatCoreOverride = true;
    await resetScreenWorld();
    final ScrollableState scrollable = await mountRealScreenThread(
      tester,
      FakeDisk(),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();

    final List<FrameTiming> timings = <FrameTiming>[];
    void collect(List<FrameTiming> t) => timings.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(collect);
    final double start = scrollable.position.pixels;
    final TestGesture g = await tester.startGesture(
      tester.getCenter(find.byWidget(scrollable.widget)),
    );
    await g.moveBy(const Offset(0, 20));
    final List<int> firstFrames = <int>[];
    for (int f = 0; f < 240; f++) {
      await g.moveBy(const Offset(0, 30));
      await tester.pump();
      if (f == 29) firstFrames.add(timings.length);
    }
    await g.up();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    SchedulerBinding.instance.removeTimingsCallback(collect);
    final double moved = start - scrollable.position.pixels;

    final Map<String, Object> report = <String, Object>{
      'moved_px': moved.round(),
      'all': _summary(timings),
      'first30': _summary(
        timings.sublist(0, firstFrames.isEmpty ? 30 : firstFrames.first),
      ),
    };
    debugPrint('SCREENPERF $report');
    binding.reportData = report;
    await MultiplexSession.shutdown();
    debugAgentsChatCoreOverride = null;
  });
}
