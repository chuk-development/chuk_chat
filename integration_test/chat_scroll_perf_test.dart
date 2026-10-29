// Scroll-up speed test on a real device, in a profile build.
//
// The same fixture as `test/perf/chat_scroll_up_perf_test.dart` (300 mixed
// messages in the mobile chat's anchored transcript), measured with the
// engine's own FrameTiming: build (UI thread) and raster per frame. Run:
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/chat_scroll_perf_test.dart
//
// The summary is printed and lands in build/integration_response_data.json.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show debugProfileLayoutsEnabled;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

import '../test/perf/chat_scroll_fixture.dart';

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
    'raster_p90_ms': f(p(raster, 0.9)),
    'raster_worst_ms': f(raster.last),
    'jank_build_over_16ms': build.where((v) => v > 16.0).length,
    'jank_raster_over_16ms': raster.where((v) => v > 16.0).length,
  };
}

/// `--dart-define=PERF_TRACE=true`: one run under a timeline trace with a
/// timeline event per widget build and per layout, for attributing the cost.
const bool _trace = bool.fromEnvironment('PERF_TRACE');

/// `--dart-define=PERF_MIX=prose|table|list|tools|plain`: one kind of answer
/// only (see [scrollPerfTranscript]). `plain` is the control: the same texts
/// as bare [Text] rows, no bubble at all.
const String _mix = String.fromEnvironment('PERF_MIX');

class _PlainList extends StatelessWidget {
  const _PlainList({required this.messages});

  final List<Map<String, String>> messages;

  @override
  Widget build(BuildContext context) => ListView.builder(
    reverse: true,
    itemCount: messages.length,
    itemBuilder: (context, i) => Padding(
      padding: const EdgeInsets.all(12),
      child: Text(messages[messages.length - 1 - i]['text'] ?? ''),
    ),
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('scroll up a 300-message chat', (tester) async {
    debugAgentsChatCoreOverride = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MessageRenderCache.debugClearShared();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: _mix == 'plain'
                ? _PlainList(messages: scrollPerfTranscript(mix: 'prose'))
                : ScrollPerfHost(messages: scrollPerfTranscript(mix: _mix)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(seconds: 2));

    final Finder list = find.byType(Scrollable).first;
    final Map<String, Object> report = <String, Object>{};
    if (_trace) {
      debugProfileBuildsEnabled = true;
      debugProfileLayoutsEnabled = true;
      await binding.traceAction(() async {
        final TestGesture g = await tester.startGesture(tester.getCenter(list));
        await g.moveBy(const Offset(0, 20));
        for (int f = 0; f < 240; f++) {
          await g.moveBy(const Offset(0, 30));
          await tester.pump();
        }
        await g.up();
      }, reportKey: 'timeline');
      debugProfileBuildsEnabled = false;
      debugProfileLayoutsEnabled = false;
      return;
    }
    for (int run = 0; run < 2; run++) {
      final List<FrameTiming> timings = <FrameTiming>[];
      void collect(List<FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(collect);

      // A reader's drag upwards: 30 px per frame for ~4 s.
      final TestGesture g = await tester.startGesture(tester.getCenter(list));
      await g.moveBy(const Offset(0, 20));
      for (int f = 0; f < 240; f++) {
        await g.moveBy(const Offset(0, 30));
        await tester.pump();
      }
      await g.up();
      // Then two flings further up.
      for (int k = 0; k < 2; k++) {
        await tester.fling(list, const Offset(0, 500), 4000);
        for (int f = 0; f < 90; f++) {
          await tester.pump();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      SchedulerBinding.instance.removeTimingsCallback(collect);
      report['run$run'] = _summary(timings);
      debugPrint('SCROLLPERF run$run ${report['run$run']}');
      // Back to the bottom for the second run: a fresh thread open.
      final ScrollableState s = tester.state<ScrollableState>(list);
      s.position.jumpTo(s.position.maxScrollExtent);
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      MessageRenderCache.debugClearShared();
    }
    binding.reportData = report;
  });
}
