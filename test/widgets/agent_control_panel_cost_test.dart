import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';

AgentsAgent _agent() => AgentsAgent(
  id: 'local:amber:1:x',
  name: 'Amber',
  onHost: true,
  threads: const <AgentsThreadInfo>[
    AgentsThreadInfo(key: 'local:amber:1:x', title: 'General'),
  ],
);

AgentControlSnapshot _withCost(Map<String, dynamic>? cost) =>
    AgentControlSnapshot(
      tokens: const ControlAvailable<AgentTokenUsage>(
        AgentTokenUsage(total: 5200, runs: 2, lastRun: 1100),
      ),
      cost: cost == null
          ? const ControlUnavailable<AgentCostTotals>()
          : ControlAvailable<AgentCostTotals>(
              AgentCostTotals.fromPayload(cost)!,
            ),
    );

void main() {
  late ValueNotifier<Set<String>> capabilities;
  late List<Map<String, dynamic>> sent;
  late AgentsPermissionsService permissions;
  final sinkBefore = AgentsRelayClient.agentPermissionsSink;

  setUp(() {
    capabilities = ValueNotifier<Set<String>>(<String>{
      'agent_permissions',
      'cost_budget',
    });
    sent = <Map<String, dynamic>>[];
    permissions = AgentsPermissionsService(
      send: (Map<String, dynamic> payload) async => sent.add(payload),
      connection: ValueNotifier<Object?>(Object()),
      capabilities: capabilities,
    );
  });

  tearDown(() {
    AgentsRelayClient.agentPermissionsSink = sinkBefore;
    permissions.dispose();
  });

  Future<void> pump(WidgetTester tester, AgentControlSnapshot snapshot) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentControlPanel(
            agent: _agent(),
            source: FakeAgentControlSource(initial: snapshot),
            permissions: permissions,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void hostSays(double budget, {String? error}) {
    permissions.handleFrame(<String, dynamic>{
      'type': 'agent_permissions',
      'agent_id': 'local:amber:1:x',
      'permissions': <String, dynamic>{'sudo': true},
      'budget_weekly': budget,
      'error': ?error,
    });
  }

  testWidgets('thread, today and the week against the budget', (tester) async {
    await pump(
      tester,
      _withCost(<String, dynamic>{
        'currency': 'EUR',
        'session_total': 0.41,
        'last_run': 0.002345,
        'today': 0.12,
        'week': 4.2,
        'week_starts_at': 1759701600.0,
        'budget_weekly': 5.0,
        'budget_state': 'warning',
      }),
    );
    expect(find.text('Cost'.toUpperCase()), findsOneWidget);
    expect(find.text('This thread'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cost-thread'))).data,
      '€0.41',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cost-today'))).data,
      '€0.12',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cost-week'))).data,
      '€4.20 of €5.00',
    );
    expect(find.text('Last run < €0.01'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('cost-week-bar')),
    );
    expect(bar.value, closeTo(0.84, 1e-9));
    final context = tester.element(find.byKey(const ValueKey('cost-week-bar')));
    expect(bar.color, Theme.of(context).m3.warning);
    expect(find.text('80 % of the weekly budget used.'), findsOneWidget);
    // The token figures stay.
    expect(find.text('5 200 tokens'), findsOneWidget);
  });

  testWidgets('exceeded uses the error colour; no budget, no bar', (
    tester,
  ) async {
    await pump(
      tester,
      _withCost(<String, dynamic>{
        'session_total': 1.0,
        'today': 1.0,
        'week': 6.0,
        'budget_weekly': 5.0,
        'budget_state': 'exceeded',
      }),
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('cost-week-bar')),
    );
    expect(bar.value, 1.0);
    final context = tester.element(find.byKey(const ValueKey('cost-week-bar')));
    expect(bar.color, Theme.of(context).colorScheme.error);

    await pump(
      tester,
      _withCost(<String, dynamic>{
        'session_total': 1.0,
        'today': 1.0,
        'week': 6.0,
      }),
    );
    expect(find.byKey(const ValueKey('cost-week-bar')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cost-week'))).data,
      '€6.00',
    );
  });

  testWidgets('no cost block: token figures only', (tester) async {
    await pump(tester, _withCost(null));
    expect(find.text('This thread'), findsNothing);
    expect(find.text('5 200 tokens'), findsOneWidget);
  });

  testWidgets('the budget field is hidden for a host without cost_budget', (
    tester,
  ) async {
    capabilities.value = <String>{'agent_permissions'};
    await pump(tester, _withCost(null));
    expect(find.byKey(const ValueKey('budget-weekly-field')), findsNothing);
    expect(sent, isEmpty);
  });

  testWidgets('the budget field asks, shows, validates and sends', (
    tester,
  ) async {
    await pump(tester, _withCost(null));
    // The panel asked the host for the coworker's settings.
    expect(sent.single['type'], 'agent_permissions_get');
    expect(find.text('Weekly budget'.toUpperCase()), findsOneWidget);

    hostSays(0);
    await tester.pump();
    final field = find.byKey(const ValueKey('budget-weekly-field'));
    expect(tester.widget<TextField>(field).controller!.text, '');
    expect(find.text('No limit'), findsOneWidget);

    await tester.enterText(field, '20000');
    await tester.tap(find.byKey(const ValueKey('budget-weekly-save')));
    await tester.pump();
    expect(
      find.text('Enter an amount from 0 to 10000. 0 means no limit.'),
      findsOneWidget,
    );
    expect(sent, hasLength(1));

    await tester.enterText(field, '7,5');
    await tester.tap(find.byKey(const ValueKey('budget-weekly-save')));
    await tester.pump();
    expect(sent.last, <String, dynamic>{
      'type': 'agent_permissions_set',
      'agent_id': 'local:amber:1:x',
      'budget_weekly': 7.5,
    });

    hostSays(7.5);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '7.50');

    // A refusal from the host is shown as it said it.
    await tester.enterText(field, '8');
    await tester.tap(find.byKey(const ValueKey('budget-weekly-save')));
    await tester.pump();
    hostSays(7.5, error: 'budget_weekly must be a number from 0 to 10000');
    await tester.pump();
    expect(
      find.text('budget_weekly must be a number from 0 to 10000'),
      findsOneWidget,
    );
  });

  testWidgets('cost and budget fit 360 dp at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: AgentControlPanel(
            agent: _agent(),
            source: FakeAgentControlSource(
              initial: _withCost(<String, dynamic>{
                'session_total': 1234.56,
                'today': 999.99,
                'week': 4321.0,
                'budget_weekly': 10000.0,
                'budget_state': 'ok',
              }),
            ),
            permissions: permissions,
          ),
        ),
      ),
    );
    final first = tester.takeException();
    hostSays(10000);
    await tester.pump();
    expect(first, isNull);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('budget-weekly-field')), findsOneWidget);
  });

  test('parseBudgetWeekly', () {
    expect(parseBudgetWeekly(''), 0);
    expect(parseBudgetWeekly('€ 5'), 5);
    expect(parseBudgetWeekly('4,999'), 5.0);
    expect(parseBudgetWeekly('10000'), 10000);
    expect(parseBudgetWeekly('10000.01'), isNull);
    expect(parseBudgetWeekly('-1'), isNull);
    expect(parseBudgetWeekly('abc'), isNull);
    expect(parseBudgetWeekly('NaN'), isNull);
  });

  test('formatEuro', () {
    expect(formatEuro(0), '€0.00');
    expect(formatEuro(0.004), '< €0.01');
    expect(formatEuro(0.0123), '€0.01');
    expect(formatEuro(12.346), '€12.35');
  });

  test('the status frame carries the cost block', () {
    final status = AgentsRelayAgentStatus.fromPayload(<String, dynamic>{
      'type': 'agent_status',
      'session_key': 'k',
      'cost': <String, dynamic>{'session_total': 0.4, 'today': 0.1, 'week': 1},
    });
    final cost = AgentCostTotals.fromPayload(status.cost)!;
    expect(cost.sessionTotal, 0.4);
    expect(cost.week, 1.0);
    expect(cost.hasBudget, isFalse);
    expect(cost.weekShare, isNull);
  });
}
