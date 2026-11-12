// Agent avatar perf harness (not shipped, docs/AGENT_AVATAR.md): 100 agents in a lazy list, a pinned row,
// 20 working, 15 asleep, one following a moving pointer, the list scrolled
// half the time. Prints FrameTiming stats after 12 s and exits.
// Run: xvfb-run -a flutter run --profile -d linux -t tool/agent_avatar_perf.dart
// (add --dart-define=BASELINE=true for plain circles instead of avatars)
// ignore_for_file: avoid_print, invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/ui/agent_avatar/agent_avatar.dart';

const bool _baseline = bool.fromEnvironment('BASELINE');

Widget _face(AgentsAgent a, double size) => _baseline
    ? CircleAvatar(radius: size / 2, child: Text(a.name[0]))
    : AgentAvatar(agent: a, size: size);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final DateTime now = DateTime.now();
  final List<AgentsAgent> agents = <AgentsAgent>[
    for (int i = 0; i < 100; i++)
      AgentsAgent(
        id: 'agent-$i',
        name: 'Agent $i',
        threads: const <AgentsThreadInfo>[],
        running: i % 5 == 0,
        lastActivity: i % 7 == 3 ? now.subtract(const Duration(days: 1)) : now,
      ),
  ];
  runApp(_Harness(agents: agents));
}

class _Harness extends StatefulWidget {
  const _Harness({required this.agents});
  final List<AgentsAgent> agents;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final ScrollController _scroll = ScrollController();
  final List<FrameTiming> _timings = <FrameTiming>[];
  final List<int> _ticking = <int>[];
  final List<int> _live = <int>[];

  @override
  void initState() {
    super.initState();
    AgentAvatarFocus.instance.openAgentId = 'agent-1';
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
    final Stopwatch sw = Stopwatch()..start();
    Timer.periodic(const Duration(milliseconds: 16), (Timer t) {
      final double s = sw.elapsedMilliseconds / 1000;
      // A pointer circling over the open agent's header avatar.
      GestureBinding.instance.handlePointerEvent(
        PointerHoverEvent(
          position: Offset(
            600 + math.cos(s * 2) * 300,
            60 + math.sin(s * 2) * 40,
          ),
          kind: PointerDeviceKind.mouse,
        ),
      );
      _ticking.add(AgentAvatarFocus.instance.debugTickingCount);
      _live.add(AgentAvatarFocus.instance.debugLiveCount);
      if (s > 12) {
        t.cancel();
        _report();
      }
    });
    Timer(const Duration(seconds: 3), () {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(seconds: 4),
        curve: Curves.linear,
      );
    });
  }

  void _report() {
    List<double> ms(Duration Function(FrameTiming) f) =>
        _timings.map((FrameTiming t) => f(t).inMicroseconds / 1000).toList()
          ..sort();
    String stats(List<double> v) {
      if (v.isEmpty) return 'n/a';
      double q(double p) => v[((v.length - 1) * p).round()];
      return 'p50 ${q(0.5).toStringAsFixed(2)} p90 ${q(0.9).toStringAsFixed(2)} '
          'p99 ${q(0.99).toStringAsFixed(2)} max ${v.last.toStringAsFixed(2)} ms';
    }

    final List<double> build = ms((FrameTiming t) => t.buildDuration);
    final List<double> raster = ms((FrameTiming t) => t.rasterDuration);
    final int slow = _timings
        .where(
          (FrameTiming t) =>
              t.buildDuration.inMicroseconds > 16667 ||
              t.rasterDuration.inMicroseconds > 16667,
        )
        .length;
    _ticking.sort();
    _live.sort();
    print('PERF frames=${_timings.length} over 12 s');
    print('PERF build(UI) ${stats(build)}');
    print('PERF raster    ${stats(raster)}');
    print('PERF frames over 16.7 ms: $slow');
    print(
      'PERF mounted avatars: max ${_live.last} of 104; ticking: median ${_ticking[_ticking.length ~/ 2]} max ${_ticking.last}',
    );
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final List<AgentsAgent> a = widget.agents;
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            // "Chat header": the open agent.
            SizedBox(height: 120, child: Center(child: _face(a[1], 64))),
            // Pinned row, 64 px.
            SizedBox(
              height: 80,
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < 4; i++)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: _face(a[i], 64),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemCount: a.length,
                itemBuilder: (BuildContext c, int i) => ListTile(
                  leading: _face(a[i], 48),
                  title: Text(a[i].name),
                  subtitle: const Text('Letzte Nachricht …'),
                  trailing: const Text('09:41'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
