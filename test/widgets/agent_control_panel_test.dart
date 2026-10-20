import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';

AgentsAgent _agent({bool onHost = true}) => AgentsAgent(
      id: 'host:cowork-host',
      name: 'cowork-host',
      onHost: onHost,
      brief: onHost ? null : 'weekly crypto news',
      threads: const <AgentsThreadInfo>[
        AgentsThreadInfo(key: 'host:cowork-host', title: 'General'),
      ],
    );

Future<void> _pump(
  WidgetTester tester,
  AgentControlSource source, {
  AgentsAgent? agent,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentControlPanel(agent: agent ?? _agent(), source: source),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _fullSnapshot = AgentControlSnapshot(
  model: ControlAvailable<AgentModelChoice>(
    AgentModelChoice(
      id: 'anthropic/claude-sonnet',
      provider: 'anthropic',
      reasoningEffort: 'low',
    ),
  ),
  tokens: ControlAvailable<AgentTokenUsage>(
    AgentTokenUsage(total: 1234567, runs: 3, lastRun: 4321),
  ),
  runtime: ControlAvailable<AgentSessionRuntime>(
    AgentSessionRuntime(
      active: Duration(minutes: 4, seconds: 2),
      runs: 3,
      running: false,
    ),
  ),
  sandbox: ControlAvailable<AgentSandbox>(
    AgentSandbox(
      kind: 'docker',
      container: 'agents-amber-0a1b2c3d',
      containerId: 'deadbeef0011',
      workspace: '/home/u/.agents/agents/amber',
    ),
  ),
  skills: ControlAvailable<List<AgentSkill>>(<AgentSkill>[
    AgentSkill(name: 'deep-research', description: 'reads the web', enabled: true),
  ]),
);

void main() {
  testWidgets('what the host does not report says so, never a zero',
      (tester) async {
    final source = FakeAgentControlSource(
      initial: const AgentControlSnapshot(
        model: ControlUnavailable<AgentModelChoice>('It has not run yet.'),
        tokens: ControlUnavailable<AgentTokenUsage>('It has not run yet.'),
        runtime: ControlUnavailable<AgentSessionRuntime>('It has not run yet.'),
        sandbox: ControlUnavailable<AgentSandbox>('It has not run yet.'),
        skills: ControlUnavailable<List<AgentSkill>>('It has not run yet.'),
      ),
    );
    addTearDown(source.dispose);
    await _pump(tester, source);

    // Four measured blocks. Skills are not a block here: the Skills page owns
    // them, and the panel only links to it.
    expect(find.text('It has not run yet.'), findsNWidgets(4));
    // Crucially: no invented numbers anywhere.
    expect(find.textContaining('0 tokens'), findsNothing);
    expect(find.textContaining('0s'), findsNothing);
    expect(find.text('No skills.'), findsNothing);
  });

  testWidgets('the panel asks the host about the agent it shows',
      (tester) async {
    final source = FakeAgentControlSource();
    addTearDown(source.dispose);
    await _pump(tester, source);

    expect(source.refreshed, <String>['host:cowork-host']);
  });

  testWidgets('measured figures are shown as measured', (tester) async {
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    await _pump(tester, source);

    expect(find.text('anthropic/claude-sonnet'), findsOneWidget);
    expect(find.text('Anthropic · Reasoning low'), findsOneWidget);
    expect(find.text('Last run'), findsOneWidget);
    expect(find.text('1 234 567 tokens'), findsOneWidget);
    expect(find.text('4 321 in the last run · 3 runs'), findsOneWidget);
    expect(find.text('4m 02s working'), findsOneWidget);
    // The skills themselves live on the Skills page; the row counts them.
    expect(find.text('deep-research'), findsNothing);
    expect(find.text('1 of 1 on'), findsOneWidget);
  });

  testWidgets('the sandbox block names the agent s own container',
      (tester) async {
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    await _pump(tester, source);

    expect(find.text('Its own container'), findsOneWidget);
    expect(find.text('agents-amber-0a1b2c3d · deadbeef0011'), findsOneWidget);
    expect(find.text('/home/u/.agents/agents/amber'), findsOneWidget);
  });

  testWidgets('a live run is called out while it runs', (tester) async {
    final source = FakeAgentControlSource(
      initial: const AgentControlSnapshot(
        runtime: ControlAvailable<AgentSessionRuntime>(
          AgentSessionRuntime(
            active: Duration(seconds: 30),
            runs: 2,
            running: true,
            current: Duration(seconds: 9),
          ),
        ),
      ),
    );
    addTearDown(source.dispose);
    await _pump(tester, source);

    expect(find.text('Running now, 9s into this run.'), findsOneWidget);
  });

  testWidgets('the skills row opens the Skills page, no second list', (
    tester,
  ) async {
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    int opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentControlPanel(
            agent: _agent(),
            source: source,
            onOpenSkills: () => opened++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsNothing);
    final Finder row = find.byKey(const ValueKey<String>('panel-skills-row'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('no messenger channel is offered', (tester) async {
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    await _pump(tester, source);
    expect(find.textContaining('Telegram'), findsNothing);
    expect(find.text('Channels'), findsNothing);
  });

  testWidgets('an agent the host does not know says so', (tester) async {
    final source = FakeAgentControlSource();
    addTearDown(source.dispose);
    await _pump(tester, source, agent: _agent(onHost: false));

    expect(
      find.text('Created in the app. It is not installed on the host yet.'),
      findsOneWidget,
    );
  });

  testWidgets('an app-made agent the host runs is not called uninstalled', (
    tester,
  ) async {
    // The host measured a sandbox for it: it runs there, whatever onHost says.
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    await _pump(tester, source, agent: _agent(onHost: false));

    expect(
      find.text('Created in the app. It is not installed on the host yet.'),
      findsNothing,
    );
  });

  testWidgets('the panel leaves the role to the agent page', (tester) async {
    final source = FakeAgentControlSource();
    addTearDown(source.dispose);
    final agent = AgentsAgent(
      id: 'local:amber',
      name: 'amber-otter',
      role: 'researcher',
      threads: const <AgentsThreadInfo>[
        AgentsThreadInfo(key: 'local:amber', title: 'General'),
      ],
    );
    await _pump(tester, source, agent: agent);
    expect(find.text('researcher'), findsNothing);
    expect(source.refreshed, <String>['local:amber']);
  });

  testWidgets('the panel is the measured blocks, no profile fields', (
    tester,
  ) async {
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    await _pump(tester, source);

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Technical details'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Token use'), findsOneWidget);
    expect(find.text('1 234 567 tokens'), findsOneWidget);
  });

  group('formatRuntime', () {
    test('reads plainly at every scale', () {
      expect(formatRuntime(const Duration(seconds: 9)), '9s');
      expect(formatRuntime(const Duration(minutes: 4, seconds: 2)), '4m 02s');
      expect(formatRuntime(const Duration(hours: 1, minutes: 4)), '1h 04m');
    });
  });

  group('formatCount', () {
    test('groups so a six-figure count is readable', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1234), '1 234');
      expect(formatCount(1234567), '1 234 567');
    });
  });
}
