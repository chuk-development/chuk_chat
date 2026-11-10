// The "Tool detail" modes, the preparing row, the edit change count and the
// running-title shimmer on the activity timeline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/settings/tool_detail_service.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:chuk_chat/widgets/text_shimmer.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 5, 10);

ToolCall _call(
  String name, {
  Map<String, dynamic> args = const {},
  ToolCallStatus status = ToolCallStatus.completed,
  int start = 0,
  String? result,
}) => ToolCall(
  name: name,
  arguments: args,
  status: status,
  result: result,
  startedAt: _t0.add(Duration(seconds: start)),
  completedAt:
      status == ToolCallStatus.completed || status == ToolCallStatus.error
      ? _t0.add(Duration(seconds: start + 1))
      : null,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<ToolCall> calls,
  bool running = false,
  ToolDetailMode? mode,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentActivityTimeline(
          toolCalls: calls,
          isRunning: running,
          clock: () => _t0.add(const Duration(seconds: 20)),
          startedAt: _t0,
          finalDuration: running ? null : const Duration(seconds: 13),
          toolDetailMode: mode,
        ),
      ),
    ),
  );
}

List<ToolCall> _runningSearches() => [
  _call('web_search', args: {'query': 'first'}),
  _call(
    'web_search',
    args: {'query': 'react hooks'},
    status: ToolCallStatus.running,
    start: 2,
  ),
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ToolDetailService.instance.debugReset();
  });

  testWidgets('Standard: running group title carries the live detail', (
    tester,
  ) async {
    await _pump(tester, calls: _runningSearches(), running: true);
    expect(find.text('Searching the web · react hooks'), findsOneWidget);
    // The group's steps stay behind a tap.
    expect(find.textContaining('first', findRichText: true), findsNothing);
  });

  testWidgets('Compact: title only, no detail', (tester) async {
    await _pump(
      tester,
      calls: _runningSearches(),
      running: true,
      mode: ToolDetailMode.compact,
    );
    expect(find.text('Searching the web'), findsOneWidget);
  });

  testWidgets('Detailed: a running group is open, a settled one closed', (
    tester,
  ) async {
    await _pump(
      tester,
      calls: _runningSearches(),
      running: true,
      mode: ToolDetailMode.detailed,
    );
    expect(find.textContaining('first', findRichText: true), findsOneWidget);

    final settled = [
      _call('web_search', args: {'query': 'first'}),
      _call('web_search', args: {'query': 'second'}, start: 2),
    ];
    await _pump(tester, calls: settled, mode: ToolDetailMode.detailed);
    // The settled turn folds; opened, the group stays closed.
    expect(find.text('Worked for 13s'), findsOneWidget);
    await tester.tap(find.text('Worked for 13s'));
    await tester.pump();
    expect(find.text('Searched the web'), findsOneWidget);
    expect(find.textContaining('second', findRichText: true), findsNothing);
  });

  testWidgets('Verbose: a settled turn stays open with its steps', (
    tester,
  ) async {
    await _pump(
      tester,
      calls: [
        _call('web_search', args: {'query': 'first'}),
        _call('web_search', args: {'query': 'second'}, start: 2),
      ],
      mode: ToolDetailMode.verbose,
    );
    expect(find.text('Searched the web'), findsOneWidget);
    expect(find.textContaining('second', findRichText: true), findsOneWidget);
  });

  testWidgets('a failed turn stays open in every mode', (tester) async {
    for (final ToolDetailMode mode in ToolDetailMode.values) {
      await _pump(
        tester,
        calls: [
          _call('web_search', args: {'query': 'a'}),
          _call(
            'web_search',
            args: {'query': 'b'},
            status: ToolCallStatus.error,
          ),
        ],
        mode: mode,
      );
      expect(
        find.textContaining('Search failed', findRichText: true),
        findsOneWidget,
        reason: mode.name,
      );
    }
  });

  testWidgets('the setting drives the timeline when no mode is pinned', (
    tester,
  ) async {
    await _pump(tester, calls: _runningSearches(), running: true);
    expect(find.text('Searching the web · react hooks'), findsOneWidget);
    await ToolDetailService.instance.setMode(ToolDetailMode.compact);
    // The new title may wait up to 150 ms (MinDurationHold), then shows.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Searching the web'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ToolDetailService.prefsKey), 'compact');
  });

  testWidgets('a pending call shows its preparing row', (tester) async {
    await _pump(
      tester,
      calls: [
        _call(
          'write_file',
          args: {'path': '/w/intro.md', 'content': 'x' * 100},
          status: ToolCallStatus.pending,
        ),
      ],
      running: true,
    );
    expect(find.text('Preparing: Write intro.md 1KB'), findsOneWidget);
  });

  testWidgets('a finished edit shows +added -removed on its row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentActivityTimeline(
            initiallyExpanded: true,
            toolCalls: [
              _call(
                'notes',
                args: {'title': 'Groceries'},
                result: 'Updated.\n<diff>{"before":"milk\\nbread","after":"milk\\neggs\\njam"}</diff>',
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('agent-activity-change-count')),
      findsOneWidget,
    );
    expect(find.text('+2 -1', findRichText: true), findsOneWidget);
  });

  testWidgets('the running header has tabular figures', (tester) async {
    await _pump(tester, calls: _runningSearches(), running: true);
    final Text header = tester.widget<Text>(
      find.text('Searching the web for 20s'),
    );
    expect(
      header.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  group('shimmer', () {
    setUp(() => TextShimmer.enabled = true);
    tearDown(() => TextShimmer.enabled = false);

    testWidgets('only running text shimmers, after 300 ms', (tester) async {
      await _pump(tester, calls: _runningSearches(), running: true);
      expect(find.byType(ShaderMask), findsNothing);
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ShaderMask), findsWidgets);

      await _pump(tester, calls: [_call('web_search')]);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('reduced motion keeps the text still', (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: TextShimmer(child: Text('Searching the web')),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('sweep then rest: no mask during the rest', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: TextShimmer(child: Text('Running commands'))),
      );
      await tester.pump(TextShimmer.delay);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ShaderMask), findsOneWidget);
      // 1.2 s into the 1.5 s cycle is the rest.
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(ShaderMask), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
