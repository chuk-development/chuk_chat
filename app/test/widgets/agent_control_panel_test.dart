import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_control_source.dart';
import 'package:cowork/services/cowork/schedule_spec.dart';
import 'package:cowork/widgets/agent_control_panel.dart';

CoworkAgent _agent({ScheduleSpec? schedule, bool onHost = true}) => CoworkAgent(
      id: 'host:cowork-host',
      name: 'cowork-host',
      onHost: onHost,
      brief: onHost ? null : 'weekly crypto news',
      schedule: schedule,
      threads: const <CoworkThreadInfo>[
        CoworkThreadInfo(key: 'default', title: 'General'),
      ],
    );

Future<void> _pump(
  WidgetTester tester,
  AgentControlSource source, {
  CoworkAgent? agent,
  void Function(ScheduleSpec spec)? onScheduleSubmitted,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentControlPanel(
          agent: agent ?? _agent(),
          source: source,
          onScheduleSubmitted: onScheduleSubmitted,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('what the host does not report reads as not connected, never a zero',
      (tester) async {
    final source = HostUnavailableControlSource();
    addTearDown(source.dispose);
    await _pump(tester, source);

    // Every block: model, tokens, runtime, schedule, skills, integrations.
    expect(find.text('Not connected yet'), findsNWidgets(6));
    expect(
      find.text('The host does not report this yet.'),
      findsNWidgets(6),
    );
    // Crucially: no invented numbers anywhere.
    expect(find.textContaining('0 tokens'), findsNothing);
    expect(find.textContaining('0s'), findsNothing);
    expect(find.text('No skills.'), findsNothing);
  });

  testWidgets('real values are shown when the source has them', (tester) async {
    final source = FakeAgentControlSource(
      initial: AgentControlSnapshot(
        skills: const ControlAvailable<List<AgentSkill>>(<AgentSkill>[
          AgentSkill(
            name: 'deep-research',
            description: 'multi-source research',
            enabled: false,
          ),
        ]),
        integrations: const ControlAvailable<List<AgentIntegration>>(
          <AgentIntegration>[
            AgentIntegration(name: 'GitHub', connected: true, account: 'chuk'),
          ],
        ),
        model: const ControlAvailable<AgentModelChoice>(
          AgentModelChoice(
            selectedId: 'qwen/qwen3.6-35b-a3b',
            available: <String>['qwen/qwen3.6-35b-a3b', 'qwen/qwen3.5-397b-a17b'],
          ),
        ),
        tokens: const ControlAvailable<AgentTokenUsage>(
          AgentTokenUsage(promptTokens: 1200, completionTokens: 300),
        ),
        sessionRuntime: const ControlAvailable<Duration>(
          Duration(minutes: 4, seconds: 12),
        ),
        schedule: ControlAvailable<AgentSchedule>(
          AgentSchedule(
            source: '0 9 * * *',
            description: 'cron: 0 9 * * *',
            nextRuns: <DateTime>[DateTime(2026, 8, 14, 9)],
          ),
        ),
      ),
    );
    addTearDown(source.dispose);
    await _pump(tester, source);

    expect(find.text('1500 tokens'), findsOneWidget);
    expect(find.text('1200 in · 300 out'), findsOneWidget);
    expect(find.text('4m 12s'), findsOneWidget);
    expect(find.text('cron: 0 9 * * *'), findsOneWidget);
    expect(find.text('2026-08-14 09:00'), findsOneWidget);
    expect(find.text('deep-research'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Not connected yet'), findsNothing);
    expect(source.refreshCalls, 1);
  });

  testWidgets('a skill toggle and an integration button reach the source',
      (tester) async {
    final source = FakeAgentControlSource(
      initial: const AgentControlSnapshot(
        skills: ControlAvailable<List<AgentSkill>>(<AgentSkill>[
          AgentSkill(name: 'deep-research', description: 'x', enabled: false),
        ]),
        integrations: ControlAvailable<List<AgentIntegration>>(
          <AgentIntegration>[AgentIntegration(name: 'GitHub', connected: false)],
        ),
      ),
    );
    addTearDown(source.dispose);
    await _pump(tester, source);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(source.snapshot.value.skills.valueOrNull!.single.enabled, isTrue);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(source.snapshot.value.integrations.valueOrNull!.single.connected, isTrue);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('picking another model reaches the source', (tester) async {
    final source = FakeAgentControlSource(
      initial: const AgentControlSnapshot(
        model: ControlAvailable<AgentModelChoice>(
          AgentModelChoice(
            selectedId: 'a',
            available: <String>['a', 'b'],
          ),
        ),
      ),
    );
    addTearDown(source.dispose);
    await _pump(tester, source);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b').last);
    await tester.pumpAndSettle();

    expect(source.selectedModels, <String>['b']);
  });

  testWidgets('a schedule the user set in the app is shown as not installed',
      (tester) async {
    final source = HostUnavailableControlSource();
    addTearDown(source.dispose);
    await _pump(
      tester,
      source,
      agent: _agent(onHost: false, schedule: ScheduleSpec.parse('every 30m')),
    );

    expect(find.textContaining('every 30 minutes'), findsOneWidget);
    expect(find.text('Set in the app. The host does not run it yet.'),
        findsOneWidget);
    expect(find.text('Next runs'), findsOneWidget);
    // The agent itself is flagged as not installed either.
    expect(
      find.text('Created in the app. It is not installed on the host yet.'),
      findsOneWidget,
    );
    // One block fewer says "not connected": the schedule speaks for itself.
    expect(find.text('Not connected yet'), findsNWidgets(5));
  });

  testWidgets('junk in the schedule field is refused with a message',
      (tester) async {
    final source = HostUnavailableControlSource();
    addTearDown(source.dispose);
    final submitted = <ScheduleSpec>[];
    await _pump(tester, source, onScheduleSubmitted: submitted.add);

    await tester.enterText(find.byType(TextField), 'banana');
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();

    expect(find.text('Not a schedule this app understands.'), findsOneWidget);
    expect(submitted, isEmpty);

    await tester.enterText(find.byType(TextField), 'every 15m');
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();

    expect(submitted.single.source, 'every 15m');
    expect(find.text('Not a schedule this app understands.'), findsNothing);
  });

  testWidgets('a refused mutation is reported, not swallowed', (tester) async {
    final source = FakeAgentControlSource(
      initial: const AgentControlSnapshot(
        skills: ControlAvailable<List<AgentSkill>>(<AgentSkill>[
          AgentSkill(name: 'deep-research', description: 'x', enabled: false),
        ]),
      ),
    );
    addTearDown(source.dispose);
    final failing = _ThrowingControlSource(source);
    await _pump(tester, failing);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.textContaining('the host said no'), findsOneWidget);
  });

  group('formatRuntime', () {
    test('reads plainly at every scale', () {
      expect(formatRuntime(const Duration(seconds: 9)), '9s');
      expect(formatRuntime(const Duration(minutes: 4, seconds: 2)), '4m 02s');
      expect(formatRuntime(const Duration(hours: 1, minutes: 4)), '1h 04m');
    });
  });

  testWidgets('the panel shows the agent role',
      (tester) async {
    final source = HostUnavailableControlSource();
    final agent = CoworkAgent(
      id: 'local:amber',
      name: 'amber-otter',
      role: 'researcher',
      threads: const <CoworkThreadInfo>[
        CoworkThreadInfo(key: 'a', title: 'General'),
        CoworkThreadInfo(key: 'b', title: 'Side'),
      ],
    );
    await _pump(tester, source, agent: agent);
    expect(find.text('researcher'), findsOneWidget);
  });

}

/// Wraps a source and refuses the skill toggle, to prove the failure surfaces.
class _ThrowingControlSource implements AgentControlSource {
  _ThrowingControlSource(this._inner);
  final AgentControlSource _inner;

  @override
  ValueListenable<AgentControlSnapshot> get snapshot => _inner.snapshot;

  @override
  Future<void> refresh() => _inner.refresh();

  @override
  Future<void> setSkillEnabled(String skillName, {required bool enabled}) async {
    throw StateError('the host said no');
  }

  @override
  Future<void> setIntegrationConnected(String name, {required bool connected}) =>
      _inner.setIntegrationConnected(name, connected: connected);

  @override
  Future<void> selectModel(String modelId) => _inner.selectModel(modelId);

  @override
  Future<void> setSchedule(String source) => _inner.setSchedule(source);

  @override
  void dispose() {}
}