// Scroll and rail-jump speed test of the DESKTOP chat in a profile build,
// measured with the engine's own FrameTiming (build = UI thread, raster).
//
// The real `ChukChatUIDesktop` with a 330-row chat (markdown, lists, tables,
// code, tool calls, pictures), at 1440x900. Run headless on Linux, never on
// the owner's display:
//
//   xvfb-run -a -s "-screen 0 1440x900x24" flutter drive --profile -d linux \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/chat_desktop_scroll_perf_test.dart
//
// The report lands in build/integration_response_data.json and in the log
// (`DESKTOPPERF`). Phases:
//
// - open: the chat screen mounts with the chat open, until it settles.
// - wheel up: a mouse wheel, one 53 px notch (GTK's step) every 3rd frame.
//   Besides frame times it reports the motion: the largest single-frame step
//   and the share of frames inside the scroll that stood still.
// - fling up: five flings with the touchpad/drag path.
// - rail jumps: eight clicks on far strips of the message rail.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

import '../test/perf/chat_desktop_perf_fixture.dart';

Map<String, Object> _summary(List<FrameTiming> t) {
  if (t.isEmpty) return <String, Object>{'frames': 0};
  double ms(Duration d) => d.inMicroseconds / 1000.0;
  final List<double> build = t.map((f) => ms(f.buildDuration)).toList()..sort();
  final List<double> raster = t.map((f) => ms(f.rasterDuration)).toList()
    ..sort();
  final List<double> total = t.map((f) => ms(f.totalSpan)).toList()..sort();
  double p(List<double> s, double q) => s[((s.length - 1) * q).round()];
  String f(double v) => v.toStringAsFixed(2);
  return <String, Object>{
    'frames': t.length,
    'build_p50': f(p(build, .5)),
    'build_p90': f(p(build, .9)),
    'build_p99': f(p(build, .99)),
    'build_max': f(build.last),
    'raster_p50': f(p(raster, .5)),
    'raster_p90': f(p(raster, .9)),
    'raster_max': f(raster.last),
    'jank_build_16': build.where((v) => v > 16.67).length,
    'jank_total_16': total.where((v) => v > 16.67).length,
  };
}

Future<Map<String, Object>> _measure(Future<void> Function() body) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> t) => timings.addAll(t);
  SchedulerBinding.instance.addTimingsCallback(collect);
  await body();
  // FrameTimings arrive in batches; give the last batch time to land.
  await Future<void>.delayed(const Duration(milliseconds: 600));
  SchedulerBinding.instance.removeTimingsCallback(collect);
  return _summary(timings);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('desktop chat: open, wheel up, fling up, rail jumps', (
    tester,
  ) async {
    debugAgentsChatCoreOverride = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MessageRenderCache.debugClearShared();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final Map<String, Object> report = <String, Object>{};

    seedDesktopPerfChat();
    report['open'] = await _measure(() async {
      await tester.pumpWidget(desktopPerfScreen());
      for (int i = 0; i < 60; i++) {
        await tester.pump();
      }
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();

    final ScrollPosition position = desktopChatPosition(tester);
    final Offset centre = tester.getCenter(find.byType(Scaffold).first);

    // Wheel up.
    debugPrint('PHASE wheel');
    final OffsetSampler wheel = OffsetSampler(position);
    final TestPointer mouse = TestPointer(7, PointerDeviceKind.mouse);
    final double wheelStart = position.pixels;
    report['wheel_up'] = await _measure(() async {
      wheel.start();
      await tester.sendEventToBinding(mouse.hover(centre));
      for (int f = 0; f < 360; f++) {
        if (f % 3 == 0) {
          await tester.sendEventToBinding(mouse.scroll(const Offset(0, -53)));
        }
        await tester.pump();
      }
      for (int f = 0; f < 30; f++) {
        await tester.pump();
      }
      wheel.stop();
    });
    final smooth = wheelSmoothness(wheel.steps);
    report['wheel_motion'] = <String, Object>{
      'moved_px': (wheelStart - position.pixels).round(),
      'max_step_px': smooth.maxStep.toStringAsFixed(1),
      'still_frames_pct': (smooth.stillShare * 100).toStringAsFixed(0),
      'frames': smooth.frames,
    };

    // Fling up.
    debugPrint('PHASE fling');
    report['fling_up'] = await _measure(() async {
      for (int n = 0; n < 5; n++) {
        await tester.flingFrom(centre, const Offset(0, 300), 2500);
        for (int f = 0; f < 60; f++) {
          await tester.pump();
        }
      }
    });

    // Rail jumps between far messages, each measured on its own.
    debugPrint('PHASE rail');
    final List<int> order = <int>[0, -1, 3, -4, 1, -2, 10, -10];
    final List<FrameTiming> all = <FrameTiming>[];
    final List<String> perJump = <String>[];
    for (final int pick in order) {
      final List<Rect> strips = desktopRailStrips(tester);
      final int i = pick < 0 ? strips.length + pick : pick;
      debugPrint('PHASE jump $i');
      final List<FrameTiming> timings = <FrameTiming>[];
      void collect(List<FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(collect);
      final TestGesture tap = await tester.startGesture(
        strips[i].center,
        kind: PointerDeviceKind.mouse,
      );
      await tap.up();
      for (int f = 0; f < 40; f++) {
        await tester.pump();
      }
      await tap.removePointer();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      SchedulerBinding.instance.removeTimingsCallback(collect);
      all.addAll(timings);
      final double worst = timings
          .map((FrameTiming f) => f.buildDuration.inMicroseconds / 1000.0)
          .fold<double>(0, (double a, double b) => a > b ? a : b);
      perJump.add(worst.toStringAsFixed(1));
    }
    report['rail_jumps'] = _summary(all);
    report['rail_jump_worst_build_ms'] = perJump;

    binding.reportData = report;
    debugPrint('DESKTOPPERF $report');
    removeDesktopPerfChat();
  });
}
