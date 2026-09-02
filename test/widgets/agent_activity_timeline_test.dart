// Tests for the agent activity timeline: what the lines say, how steps
// fold into groups, how long the round is reported to have taken, and when
// the whole thing collapses to a single line.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';

final DateTime _t0 = DateTime.utc(2026, 8, 13, 10, 0, 0);

ToolCall _call(
  String name, {
  Map<String, dynamic> arguments = const {},
  ToolCallStatus status = ToolCallStatus.completed,
  int startSecond = 0,
  int? endSecond,
  String? roundThinking,
}) {
  return ToolCall(
    name: name,
    arguments: arguments,
    status: status,
    roundThinking: roundThinking,
    startedAt: _t0.add(Duration(seconds: startSecond)),
    completedAt: endSecond == null
        ? null
        : _t0.add(Duration(seconds: endSecond)),
  );
}

Future<void> _pumpTimeline(
  WidgetTester tester, {
  required List<ToolCall> calls,
  bool isRunning = false,
  DateTime? now,
  bool? initiallyExpanded,
  void Function(ToolCall)? onStepTap,
  void Function(AgentActivitySource)? onSourceTap,
  StreamPhase? phase,
  DateTime? startedAt,
  Duration? finalDuration,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentActivityTimeline(
          toolCalls: calls,
          isRunning: isRunning,
          initiallyExpanded: initiallyExpanded,
          onStepTap: onStepTap,
          onSourceTap: onSourceTap,
          clock: now == null ? null : () => now,
          phase: phase,
          startedAt: startedAt,
          finalDuration: finalDuration,
        ),
      ),
    ),
  );
}

void main() {
  group('entry wording', () {
    test('a search names what was searched for', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'quarterly report'}),
      ]);

      expect(entries, hasLength(1));
      expect(entries.single.kind, AgentActivityKind.search);
      expect(entries.single.label, 'Searched');
      expect(entries.single.detail, 'quarterly report');
    });

    test('an opened page drops scheme and www', () {
      final entries = buildAgentActivityEntries([
        _call('fetch_url', arguments: {'url': 'https://www.example.com/a/b'}),
      ]);

      expect(entries.single.kind, AgentActivityKind.page);
      expect(entries.single.label, 'Opened page');
      expect(entries.single.detail, 'example.com/a/b');
    });

    test('an unknown tool is named in words, not snake_case', () {
      final entries = buildAgentActivityEntries([_call('generate_image')]);

      expect(entries.single.kind, AgentActivityKind.other);
      expect(entries.single.label, 'Ran generate image');
    });

    test('a long query is cut with an ellipsis', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'x' * 200}),
      ]);

      final detail = entries.single.detail!;
      expect(detail.length, lessThanOrEqualTo(96));
      expect(detail.endsWith('…'), isTrue);
    });

    test('a failed step is marked', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', status: ToolCallStatus.error),
      ]);

      expect(entries.single.hasError, isTrue);
    });
  });

  group('one line per step', () {
    test('four searches read as four searches, each with its query', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'}),
        _call('web_search', arguments: {'query': 'c'}),
        _call('web_search', arguments: {'query': 'd'}),
      ]);

      expect(entries, hasLength(4));
      expect(entries.map((e) => e.detail), ['a', 'b', 'c', 'd']);
      expect(entries.every((e) => e.kind == AgentActivityKind.search), isTrue);
    });

    test('kinds keep their order', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'}),
        _call('fetch_url', arguments: {'url': 'https://example.com'}),
        _call('web_search', arguments: {'query': 'c'}),
      ]);

      expect(entries.map((e) => e.label), [
        'Searched',
        'Searched',
        'Opened page',
        'Searched',
      ]);
    });

    test('a failed step is marked on its own line', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'},
            status: ToolCallStatus.error),
      ]);

      expect(entries.map((e) => e.hasError), [false, true]);
    });

    test('a thinking note becomes its own line before its step', () {
      final entries = buildAgentActivityEntries([
        _call(
          'web_search',
          arguments: {'query': 'a'},
          roundThinking: 'Checking the opening hours first. Then compare.',
        ),
      ]);

      expect(entries, hasLength(2));
      expect(entries.first.kind, AgentActivityKind.thinking);
      expect(entries.first.label, 'Checking the opening hours first.');
      expect(entries.last.kind, AgentActivityKind.search);
    });

    test('a thinking note sits directly above the step that carries it', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'}),
        _call('web_search', arguments: {'query': 'c'}, roundThinking: 'Now c.'),
      ]);

      expect(entries.map((e) => e.label), [
        'Searched',
        'Searched',
        'Now c.',
        'Searched',
      ]);
      expect(entries.last.detail, 'c');
    });
  });

  group('sources per step', () {
    test('a search result becomes chips with host and title', () {
      final call = _call('web_search', arguments: {'query': 'annual report'});
      call.result =
          'Search results for "annual report":\n\n'
          '1. Annual report 2025\n'
          '   https://www.example.com/reports/2025\n'
          '   Summary of the year\n\n'
          '2. Investor relations\n'
          '   https://ir.example.org/overview\n'
          '   Overview page\n';

      final sources = extractSourcesFor(call);
      expect(sources, hasLength(2));
      // `www.` is stripped, the numbered heading becomes the title.
      expect(sources.first.host, 'example.com');
      expect(sources.first.title, 'Annual report 2025');
      expect(sources.last.host, 'ir.example.org');
    });

    test('a crawl reports the page it was given', () {
      final call = _call(
        'web_crawl',
        arguments: {'url': 'https://www.example.com/a'},
      );
      call.result = 'Content from https://www.example.com/a\nBody text';

      final sources = extractSourcesFor(call);
      expect(sources, hasLength(1));
      expect(sources.single.host, 'example.com');
    });

    test('any other tool falls back to the URLs in its result', () {
      final call = _call('some_tool', arguments: {'query': 'x'});
      call.result =
          'Found https://a.example.com/x and https://a.example.com/x '
          'again, plus https://b.example.org/y.';

      final sources = extractSourcesFor(call);
      expect(sources.map((s) => s.host), ['a.example.com', 'b.example.org']);
    });

    test('a result without links has no chips', () {
      final call = _call('some_tool', arguments: {'query': 'x'});
      call.result = 'No results.';

      expect(extractSourcesFor(call), isEmpty);
      expect(buildAgentActivityEntries([call]).single.sources, isEmpty);
    });

    test('the chip count is capped', () {
      final call = _call('web_search', arguments: {'query': 'x'});
      call.result = List.generate(
        maxSourcesPerStep + 3,
        (i) => 'https://site$i.example.com/page',
      ).join(' ');

      expect(extractSourcesFor(call).length, maxSourcesPerStep);
    });
  });

  group('reasoning interleaved with calls', () {
    test('reasoning keeps its place between steps', () {
      final entries = buildAgentActivityEntriesFromSteps([
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'a'})),
        const AgentActivityStep.reasoning('Now I check the page. Then done.'),
        AgentActivityStep.tool(
          _call('fetch_url', arguments: {'url': 'https://example.com'}),
        ),
      ]);

      expect(entries.map((e) => e.kind), [
        AgentActivityKind.search,
        AgentActivityKind.thinking,
        AgentActivityKind.page,
      ]);
      expect(entries[1].label, 'Now I check the page.');
    });

    test('reasoning sits between the steps it separates', () {
      final entries = buildAgentActivityEntriesFromSteps([
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'a'})),
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'b'})),
        const AgentActivityStep.reasoning('Need one more angle.'),
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'c'})),
      ]);

      expect(entries.map((e) => e.label), [
        'Searched',
        'Searched',
        'Need one more angle.',
        'Searched',
      ]);
    });

    test('blank reasoning is dropped', () {
      final entries = buildAgentActivityEntriesFromSteps([
        const AgentActivityStep.reasoning('   '),
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'a'})),
      ]);

      expect(entries, hasLength(1));
      expect(entries.single.kind, AgentActivityKind.search);
    });
  });

  group('duration', () {
    test('spans the first start to the last completion', () {
      final duration = agentActivityDuration(
        [
          _call('web_search', startSecond: 0, endSecond: 4),
          _call('fetch_url', startSecond: 4, endSecond: 13),
        ],
        now: _t0.add(const Duration(minutes: 5)),
      );

      expect(duration, const Duration(seconds: 13));
    });

    test('counts up to now while a step is unfinished', () {
      final duration = agentActivityDuration(
        [
          _call('web_search', startSecond: 0, endSecond: 4),
          _call('fetch_url', startSecond: 4),
        ],
        now: _t0.add(const Duration(seconds: 10)),
      );

      expect(duration, const Duration(seconds: 10));
    });

    test('is null without any steps', () {
      expect(agentActivityDuration(const [], now: _t0), isNull);
    });

    test('formats seconds, minutes and hours', () {
      expect(formatAgentDuration(const Duration(seconds: 13)), '13s');
      expect(formatAgentDuration(const Duration(seconds: 63)), '1m 3s');
      expect(formatAgentDuration(const Duration(minutes: 2)), '2m');
      expect(formatAgentDuration(const Duration(minutes: 125)), '2h 5m');
      expect(formatAgentDuration(const Duration(hours: 2)), '2h');
    });
  });

  group('timeline widget', () {
    testWidgets('while running it is open and counts up', (tester) async {
      await _pumpTimeline(
        tester,
        calls: [
          _call('web_search', arguments: {'query': 'quarterly report'}, endSecond: 4),
          _call('fetch_url', arguments: {'url': 'https://example.com'},
              startSecond: 4),
        ],
        isRunning: true,
        now: _t0.add(const Duration(seconds: 10)),
      );

      expect(find.text('Working for 10s'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byIcon(Icons.language), findsOneWidget);
    });

    testWidgets('once finished it folds to one line', (tester) async {
      await _pumpTimeline(
        tester,
        calls: [
          _call('web_search', arguments: {'query': 'quarterly report'}, endSecond: 13),
        ],
        now: _t0.add(const Duration(minutes: 1)),
      );

      expect(find.text('Worked for 13s'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_right), findsOneWidget);
      // The steps are hidden, not removed from the tree by accident.
      expect(find.byIcon(Icons.search), findsNothing);
    });

    testWidgets('tapping the header opens and closes it', (tester) async {
      await _pumpTimeline(
        tester,
        calls: [
          _call('web_search', arguments: {'query': 'quarterly report'}, endSecond: 13),
        ],
        now: _t0.add(const Duration(minutes: 1)),
      );

      await tester.tap(find.text('Worked for 13s'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.text('quarterly report'), findsNothing); // rendered in a rich span

      await tester.tap(find.text('Worked for 13s'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.search), findsNothing);
    });

    testWidgets('every search gets its own line', (tester) async {
      await _pumpTimeline(
        tester,
        calls: [
          _call('web_search', arguments: {'query': 'a'}, endSecond: 2),
          _call('web_search', arguments: {'query': 'b'}, endSecond: 3),
          _call('web_search', arguments: {'query': 'c'}, endSecond: 4),
        ],
        initiallyExpanded: true,
        now: _t0.add(const Duration(seconds: 4)),
      );

      expect(find.byIcon(Icons.search), findsNWidgets(3));
    });

    testWidgets('a search shows its pages as chips', (tester) async {
      final call = _call(
        'web_search',
        arguments: {'query': 'annual report'},
        endSecond: 3,
      );
      call.result =
          'Search results:\n\n'
          '1. Annual report\n'
          '   https://www.example.com/reports\n';

      final tapped = <AgentActivitySource>[];
      await _pumpTimeline(
        tester,
        calls: [call],
        initiallyExpanded: true,
        now: _t0.add(const Duration(seconds: 3)),
        onSourceTap: tapped.add,
      );

      expect(find.text('example.com'), findsOneWidget);

      await tester.tap(find.text('example.com'));
      await tester.pump();
      expect(tapped.single.url, 'https://www.example.com/reports');
    });

    testWidgets('tapping a step reports the call behind it', (tester) async {
      final search = _call(
        'web_search',
        arguments: {'query': 'quarterly report'},
        endSecond: 2,
      );
      final page = _call(
        'fetch_url',
        arguments: {'url': 'https://example.com'},
        startSecond: 2,
        endSecond: 4,
      );
      final tapped = <ToolCall>[];

      await _pumpTimeline(
        tester,
        calls: [search, page],
        initiallyExpanded: true,
        now: _t0.add(const Duration(seconds: 4)),
        onStepTap: tapped.add,
      );

      await tester.tap(find.byIcon(Icons.language));
      await tester.pump();

      expect(tapped, [page]);
    });

    testWidgets('steps are inert without a tap handler', (tester) async {
      await _pumpTimeline(
        tester,
        calls: [_call('web_search', arguments: {'query': 'a'}, endSecond: 2)],
        initiallyExpanded: true,
        now: _t0.add(const Duration(seconds: 2)),
      );

      // Only the header is interactive.
      expect(find.byType(InkWell), findsOneWidget);
    });

    testWidgets('without steps it renders nothing', (tester) async {
      await _pumpTimeline(tester, calls: const []);

      expect(find.byType(Icon), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('the header exposes its expanded state to a11y', (
      tester,
    ) async {
      await _pumpTimeline(
        tester,
        calls: [_call('web_search', arguments: {'query': 'a'}, endSecond: 3)],
        now: _t0.add(const Duration(seconds: 3)),
      );

      final semantics = tester.getSemantics(find.text('Worked for 3s'));
      expect(semantics.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(semantics.hasFlag(SemanticsFlag.isExpanded), isFalse);
    });
  });

  group('a round built from steps', () {
    test('states its thinking once, not once per call', () {
      final call = ToolCall(
        id: '1',
        name: 'web_search',
        arguments: const {'query': 'stau elbtunnel'},
        status: ToolCallStatus.completed,
        result: 'nothing',
        roundThinking: 'The user asks about the Elbtunnel.',
      );

      final entries = buildAgentActivityEntriesFromSteps(<AgentActivityStep>[
        AgentActivityStep.reasoning('The user asks about the Elbtunnel.'),
        AgentActivityStep.tool(call),
      ]);

      final thinking = entries
          .where((e) => e.kind == AgentActivityKind.thinking)
          .toList();
      expect(thinking, hasLength(1));
      expect(entries.last.kind, AgentActivityKind.search);
    });

    test('a thinking line carries the whole text behind it', () {
      const long = 'First sentence. Second sentence that the line drops.';
      final entries = buildAgentActivityEntriesFromSteps(
        <AgentActivityStep>[AgentActivityStep.reasoning(long)],
      );

      expect(entries.single.label, 'First sentence.');
      expect(entries.single.body, long);
      expect(entries.single.hasBody, isTrue);
    });
  });

  group('the header clock', () {
    ToolCall done(DateTime start, DateTime end) => ToolCall(
      id: 'a',
      name: 'web_search',
      arguments: const {'query': 'x'},
      status: ToolCallStatus.completed,
      startedAt: start,
      completedAt: end,
      result: 'ok',
    );

    final start = DateTime(2026, 1, 1, 12, 0, 0);

    test('stops at the last call once the round is over', () {
      final elapsed = agentActivityDuration(
        [done(start, start.add(const Duration(seconds: 3)))],
        now: start.add(const Duration(seconds: 40)),
      );
      expect(elapsed, const Duration(seconds: 3));
    });

    test('keeps running while the model writes after its last tool', () {
      final elapsed = agentActivityDuration(
        [done(start, start.add(const Duration(seconds: 3)))],
        now: start.add(const Duration(seconds: 21)),
        running: true,
      );
      expect(elapsed, const Duration(seconds: 21));
    });
  });

  group('the header names the wait', () {
    testWidgets('a request still in flight says so', (tester) async {
      await _pumpTimeline(
        tester,
        calls: [_call('web_search', endSecond: null)],
        isRunning: true,
        phase: StreamPhase.connecting,
        startedAt: _t0,
        now: _t0.add(const Duration(seconds: 3)),
      );

      expect(find.text('Connecting for 3s'), findsOneWidget);
    });

    testWidgets('a server reading the prompt is not called thinking', (
      tester,
    ) async {
      await _pumpTimeline(
        tester,
        calls: [_call('web_search', endSecond: null)],
        isRunning: true,
        phase: StreamPhase.processing,
        startedAt: _t0,
        now: _t0.add(const Duration(seconds: 12)),
      );

      expect(find.text('Prompt processing for 12s'), findsOneWidget);
    });

    testWidgets('a running tool outranks the stream phase', (tester) async {
      // The model last sent reasoning, but it is waiting on a tool — that is
      // what the reader is waiting for too.
      await _pumpTimeline(
        tester,
        calls: [
          _call('web_search', status: ToolCallStatus.running, endSecond: null),
        ],
        isRunning: true,
        phase: StreamPhase.thinking,
        startedAt: _t0,
        now: _t0.add(const Duration(seconds: 5)),
      );

      expect(find.text('Working for 5s'), findsOneWidget);
    });

    testWidgets('the clock runs from the request, not the first call', (
      tester,
    ) async {
      // The call starts at +30s. Counting from it would show 2s for a turn
      // the reader has been waiting 32s for.
      await _pumpTimeline(
        tester,
        calls: [_call('web_search', startSecond: 30, endSecond: null)],
        isRunning: true,
        phase: StreamPhase.writing,
        startedAt: _t0,
        now: _t0.add(const Duration(seconds: 32)),
      );

      expect(find.text('Writing for 32s'), findsOneWidget);
    });

    testWidgets('a finished turn shows the length it was saved with', (
      tester,
    ) async {
      // Tool stamps say 4s; the recorded turn took 47s. The recorded one is
      // what the reader watched, so it is what a reopened chat shows.
      await _pumpTimeline(
        tester,
        calls: [_call('web_search', startSecond: 0, endSecond: 4)],
        finalDuration: const Duration(seconds: 47),
        now: _t0.add(const Duration(minutes: 5)),
      );

      expect(find.text('Worked for 47s'), findsOneWidget);
    });

    testWidgets('a message from before the stamp still reads sensibly', (
      tester,
    ) async {
      await _pumpTimeline(
        tester,
        calls: [_call('web_search', startSecond: 0, endSecond: 4)],
        now: _t0.add(const Duration(minutes: 5)),
      );

      expect(find.text('Worked for 4s'), findsOneWidget);
    });
  });
}
