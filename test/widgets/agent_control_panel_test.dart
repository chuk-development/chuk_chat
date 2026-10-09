import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';
import 'package:chuk_chat/widgets/agent_details_identity.dart';
import 'package:chuk_chat/widgets/coworker_model_tile.dart';

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

    expect(find.text('It has not run yet.'), findsNWidgets(5));
    // Crucially: no invented numbers anywhere.
    expect(find.textContaining('0 tokens'), findsNothing);
    expect(find.textContaining('0s'), findsNothing);
    expect(find.text('No skills.'), findsNothing);
  });

  testWidgets('the panel asks the host about the coworker it shows',
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
    expect(find.text('deep-research'), findsOneWidget);
  });

  testWidgets('the sandbox block names the coworker s own container',
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

  testWidgets('a skill switch reaches the host', (tester) async {
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    await _pump(tester, source);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(source.skillSwitches, <String>['deep-research=false']);
  });

  testWidgets('a refused mutation is reported, not swallowed', (tester) async {
    final source = FakeAgentControlSource(initial: _fullSnapshot);
    addTearDown(source.dispose);
    final failing = _ThrowingControlSource(source);
    await _pump(tester, failing);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.textContaining('the host said no'), findsOneWidget);
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

  testWidgets('the panel shows the agent role', (tester) async {
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
    expect(find.text('researcher'), findsOneWidget);
    expect(source.refreshed, <String>['local:amber']);
  });

  group('profile layout (the desktop details pane)', () {
    Future<void> pumpProfile(
      WidgetTester tester,
      AgentControlSource source, {
      AgentsAgent? agent,
      ValueChanged<String>? onRename,
      AgentProfileStore? profiles,
    }) async {
      tester.view.physicalSize = const Size(380, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentControlPanel(
              agent: agent ?? _agent(),
              source: source,
              profileLayout: true,
              onRename: onRename,
              profiles: profiles ?? AgentProfileStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final Finder nameField = find.byKey(
      const ValueKey<String>('details-name-field'),
    );
    final Finder roleField = find.byKey(
      const ValueKey<String>('details-role-field'),
    );
    final Finder briefField = find.byKey(
      const ValueKey<String>('details-brief-field'),
    );

    testWidgets('face, name, role and description, then one settings group', (
      tester,
    ) async {
      final source = FakeAgentControlSource(initial: _fullSnapshot);
      addTearDown(source.dispose);
      final agent = AgentsAgent(
        id: 'local:amber',
        name: 'amber-otter',
        role: 'researcher',
        brief: 'Reads the news every Monday.',
        threads: const <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'local:amber', title: 'General'),
        ],
      );
      await pumpProfile(tester, source, agent: agent, onRename: (_) {});

      final Finder face = find.byKey(const ValueKey<String>('details-face'));
      expect(face, findsOneWidget);
      expect(tester.getSize(face).width, AgentDetailsIdentity.faceSize);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Role (optional)'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'amber-otter',
      );
      expect(tester.widget<TextField>(roleField).controller!.text, 'researcher');
      expect(
        tester.widget<TextField>(briefField).controller!.text,
        'Reads the news every Monday.',
      );

      // The settings group holds the model row (it opens the model page).
      final Finder group = find.byKey(
        const ValueKey<String>('details-settings-group'),
      );
      expect(group, findsOneWidget);
      expect(
        find.descendant(of: group, matching: find.byType(CoworkerModelTile)),
        findsOneWidget,
      );
      // The face and the fields sit above the group.
      expect(
        tester.getTopLeft(briefField).dy,
        lessThan(tester.getTopLeft(group).dy),
      );
      // The phone's long list is not drawn.
      expect(find.text('MODEL'), findsNothing);
    });

    testWidgets('the technical details are folded until asked for', (
      tester,
    ) async {
      final source = FakeAgentControlSource(initial: _fullSnapshot);
      addTearDown(source.dispose);
      await pumpProfile(tester, source);

      expect(find.text('Technical details'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('details-technical')),
          findsNothing);
      expect(find.text('1 234 567 tokens'), findsNothing);
      expect(find.text('Its own container'), findsNothing);
      expect(find.text('deep-research'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('details-technical-toggle')),
      );
      await tester.pumpAndSettle();
      // Unchanged inside: what the phone panel shows, under the same labels.
      expect(find.text('LAST RUN'), findsOneWidget);
      expect(find.text('anthropic/claude-sonnet'), findsOneWidget);
      expect(find.text('1 234 567 tokens'), findsOneWidget);
      expect(find.text('4m 02s working'), findsOneWidget);
      expect(find.text('Its own container'), findsOneWidget);
      expect(find.text('deep-research'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('details-technical-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 234 567 tokens'), findsNothing);
    });

    testWidgets('the name saves through the rename path', (tester) async {
      final source = FakeAgentControlSource();
      addTearDown(source.dispose);
      final List<String> renamed = <String>[];
      await pumpProfile(tester, source, onRename: renamed.add);

      await tester.enterText(nameField, '  steady-kestrel ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(renamed, <String>['steady-kestrel']);

      // An empty name is not sent; the field goes back to the real name.
      await tester.enterText(nameField, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(renamed, <String>['steady-kestrel']);
      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'cowork-host',
      );
    });

    testWidgets('without a rename path the name is read-only', (tester) async {
      final source = FakeAgentControlSource();
      addTearDown(source.dispose);
      await pumpProfile(tester, source);
      expect(tester.widget<TextField>(nameField).readOnly, isTrue);
      expect(tester.widget<TextField>(roleField).readOnly, isFalse);
    });

    testWidgets('role and description go to the profile store', (
      tester,
    ) async {
      final source = FakeAgentControlSource();
      addTearDown(source.dispose);
      final AgentProfileStore store = AgentProfileStore();
      await pumpProfile(tester, source, profiles: store);

      await tester.enterText(roleField, 'Research');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.profileOf('host:cowork-host').role, 'Research');

      // The description is multi-line: it saves when it loses focus.
      await tester.enterText(briefField, 'Weekly crypto news.');
      await tester.tap(roleField);
      await tester.pumpAndSettle();
      expect(store.profileOf('host:cowork-host').brief, 'Weekly crypto news.');

      // Clearing a field clears the stored value.
      await tester.enterText(roleField, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.profileOf('host:cowork-host').role, isNull);
    });

    testWidgets('an edit still open when the pane closes is saved', (
      tester,
    ) async {
      final source = FakeAgentControlSource();
      addTearDown(source.dispose);
      final AgentProfileStore store = AgentProfileStore();
      final List<String> renamed = <String>[];
      await pumpProfile(
        tester,
        source,
        profiles: store,
        onRename: renamed.add,
      );

      await tester.enterText(briefField, 'Keeps the inbox clean.');
      await tester.enterText(nameField, 'inbox-keeper');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(renamed, <String>['inbox-keeper']);
      expect(
        store.profileOf('host:cowork-host').brief,
        'Keeps the inbox clean.',
      );
    });

    testWidgets('the phone panel keeps its long list', (tester) async {
      final source = FakeAgentControlSource(initial: _fullSnapshot);
      addTearDown(source.dispose);
      await _pump(tester, source);

      expect(find.byKey(const ValueKey<String>('details-profile')),
          findsNothing);
      expect(find.byType(AgentDetailsIdentity), findsNothing);
      expect(find.text('Technical details'), findsNothing);
      expect(find.text('MODEL'), findsOneWidget);
      expect(find.text('TOKEN USE'), findsOneWidget);
      expect(find.text('1 234 567 tokens'), findsOneWidget);
    });
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

/// Wraps a source and refuses the skill toggle, to prove the failure surfaces.
class _ThrowingControlSource implements AgentControlSource {
  _ThrowingControlSource(this._inner);
  final AgentControlSource _inner;

  @override
  ValueListenable<AgentControlSnapshot> snapshotFor(String sessionKey) =>
      _inner.snapshotFor(sessionKey);

  @override
  Future<void> refresh(String sessionKey) => _inner.refresh(sessionKey);

  @override
  Future<void> setSkillEnabled(String skillName, {required bool enabled}) async {
    throw StateError('the host said no');
  }

  @override
  void dispose() => _inner.dispose();
}
