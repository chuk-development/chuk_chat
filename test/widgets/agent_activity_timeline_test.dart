// Tests for the agent activity timeline: what the lines say, how steps
// fold into groups, how long the round is reported to have taken, and when
// the whole thing collapses to a single line.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

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
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentActivityTimeline(
          toolCalls: calls,
          isRunning: isRunning,
          initiallyExpanded: initiallyExpanded,
          onStepTap: onStepTap,
          clock: now == null ? null : () => now,
        ),
      ),
    ),
  );
}

void main() {
  group('entry wording', () {
    test('a search names what was searched for', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'VR Bank Selent'}),
      ]);

      expect(entries, hasLength(1));
      expect(entries.single.kind, AgentActivityKind.search);
      expect(entries.single.label, 'Searched for');
      expect(entries.single.detail, 'VR Bank Selent');
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

  group('grouping', () {
    test('consecutive searches fold into one group with children', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'}),
        _call('web_search', arguments: {'query': 'c'}),
        _call('web_search', arguments: {'query': 'd'}),
      ]);

      expect(entries, hasLength(1));
      expect(entries.single.label, 'Ran 4 searches');
      expect(entries.single.isGroup, isTrue);
      expect(entries.single.children, hasLength(4));
      expect(entries.single.children.first.detail, 'a');
    });

    test('a single step is not turned into a group', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
      ]);

      expect(entries.single.isGroup, isFalse);
    });

    test('different kinds stay separate lines in order', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'}),
        _call('fetch_url', arguments: {'url': 'https://example.com'}),
        _call('web_search', arguments: {'query': 'c'}),
      ]);

      expect(entries.map((e) => e.label), [
        'Ran 2 searches',
        'Opened page',
        'Searched for',
      ]);
    });

    test('a group inherits the error of any child', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'},
            status: ToolCallStatus.error),
      ]);

      expect(entries.single.isGroup, isTrue);
      expect(entries.single.hasError, isTrue);
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

    test('a thinking note breaks a run so it stays next to its step', () {
      final entries = buildAgentActivityEntries([
        _call('web_search', arguments: {'query': 'a'}),
        _call('web_search', arguments: {'query': 'b'}),
        _call('web_search', arguments: {'query': 'c'}, roundThinking: 'Now b.'),
        _call('web_search', arguments: {'query': 'd'}),
      ]);

      expect(entries.map((e) => e.label), [
        'Ran 2 searches',
        'Now b.',
        'Ran 2 searches',
      ]);
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

    test('reasoning breaks a run of same-kind calls', () {
      final entries = buildAgentActivityEntriesFromSteps([
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'a'})),
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'b'})),
        const AgentActivityStep.reasoning('Need one more angle.'),
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'c'})),
        AgentActivityStep.tool(_call('web_search', arguments: {'query': 'd'})),
      ]);

      expect(entries.map((e) => e.label), [
        'Ran 2 searches',
        'Need one more angle.',
        'Ran 2 searches',
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
          _call('web_search', arguments: {'query': 'VR Bank'}, endSecond: 4),
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
          _call('web_search', arguments: {'query': 'VR Bank'}, endSecond: 13),
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
          _call('web_search', arguments: {'query': 'VR Bank'}, endSecond: 13),
        ],
        now: _t0.add(const Duration(minutes: 1)),
      );

      await tester.tap(find.text('Worked for 13s'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.text('VR Bank'), findsNothing); // rendered in a rich span

      await tester.tap(find.text('Worked for 13s'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.search), findsNothing);
    });

    testWidgets('a group shows its header and its children', (tester) async {
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

      expect(find.text('Ran 3 searches'), findsOneWidget);
      // Header plus three children.
      expect(find.byIcon(Icons.search), findsNWidgets(4));
    });

    testWidgets('tapping a step reports the call behind it', (tester) async {
      final search = _call(
        'web_search',
        arguments: {'query': 'VR Bank'},
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

    testWidgets('a group header is not tappable', (tester) async {
      final tapped = <ToolCall>[];

      await _pumpTimeline(
        tester,
        calls: [
          _call('web_search', arguments: {'query': 'a'}, endSecond: 2),
          _call('web_search', arguments: {'query': 'b'}, endSecond: 3),
        ],
        initiallyExpanded: true,
        now: _t0.add(const Duration(seconds: 3)),
        onStepTap: tapped.add,
      );

      await tester.tap(find.text('Ran 2 searches'));
      await tester.pump();

      expect(tapped, isEmpty);
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
}
