import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/automations_page.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/widgets/automation_card.dart';

import '../services/automations/automations_source_test.dart'
    show FakeAutomationController;

AgentsAutomation _automation(
  String id, {
  String session = 'thread-1',
  String state = 'active',
}) => AgentsAutomation.fromPayload(<String, dynamic>{
  'id': id,
  'session_key': session,
  'kind': 'schedule',
  'name': 'job $id',
  'state': state,
  'spec': {'every': 600},
  'created_at': id.hashCode.toDouble(),
})!;

void main() {
  final source = AutomationsSource.instance;
  late FakeAutomationController controller;

  setUp(() {
    source.reset();
    AgentsRelayLink.instance.reset();
    controller = FakeAutomationController();
    AgentsRelayLink.instance.bind(controller);
  });

  tearDown(() {
    source.reset();
    AgentsRelayLink.instance.reset();
  });

  Future<void> pump(WidgetTester tester) async {
    // Tall enough for every card: the page's list builds lazily, so a card
    // below the fold would not exist to be found.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: AutomationsPage()));
    await tester.pump();
  }

  testWidgets('asks the host for the whole list on open and waits', (
    tester,
  ) async {
    await pump(tester);
    expect(controller.listRequests, [null]);
    expect(find.text('Waiting for the host…'), findsOneWidget);
  });

  testWidgets(
    'lists what the host answers, grouped by coworker, with actions',
    (tester) async {
      await pump(tester);
      controller.emit(
        AgentsRelayAutomationList(
          automations: [
            _automation('a1'),
            _automation('a2', session: 'other-agent', state: 'paused'),
            _automation('a3', state: 'done'),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('thread-1'), findsOneWidget);
      expect(find.text('other-agent'), findsOneWidget);
      expect(find.byType(AutomationCard), findsNWidgets(2));
      expect(find.text('job a3'), findsNothing);
      expect(find.text('Show 1 finished'), findsOneWidget);

      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(controller.controls, [('a1', 'pause')]);
      await tester.tap(find.byTooltip('Resume'));
      expect(controller.controls.last, ('a2', 'resume'));

      // The toggle sits below the two cards, past the bottom of the default
      // 800x600 test surface: bring it on screen before tapping it.
      await tester.ensureVisible(find.text('Show 1 finished'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show 1 finished'));
      await tester.pump();
      expect(find.byType(AutomationCard), findsNWidgets(3));
      expect(find.text('Hide finished'), findsOneWidget);
    },
  );

  testWidgets('a live event updates a card in place', (tester) async {
    await pump(tester);
    controller.emit(
      AgentsRelayAutomationList(automations: [_automation('a1')]),
    );
    await tester.pump();
    expect(find.text('active'), findsOneWidget);
    controller.emit(
      AgentsRelayAutomation(
        event: 'paused',
        automation: _automation('a1', state: 'paused'),
      ),
    );
    await tester.pump();
    expect(find.text('paused'), findsOneWidget);
    expect(find.byTooltip('Resume'), findsOneWidget);
  });

  testWidgets('says so when the host is not connected', (tester) async {
    AgentsRelayLink.instance.reset();
    await pump(tester);
    expect(find.textContaining('Not connected to the host'), findsOneWidget);
    expect(find.textContaining('No automations'), findsNothing);
  });

  testWidgets('an empty answered list says there is nothing', (tester) async {
    await pump(tester);
    controller.emit(const AgentsRelayAutomationList(automations: []));
    await tester.pump();
    expect(find.textContaining('No automations'), findsOneWidget);
  });

  testWidgets('names the coworker over each group, never the session key', (
    tester,
  ) async {
    await pump(tester);
    controller.emit(
      AgentsRelayAutomationList(
        automations: [
          _automation('a1', session: 'local:brisk-heron:2:116636868'),
          _automation('a2', session: 'host:cowork-host'),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('brisk-heron'), findsOneWidget);
    expect(find.text('cowork-host'), findsOneWidget);
    expect(find.text('local:brisk-heron:2:116636868'), findsNothing);
  });

  testWidgets('one row per automation, and the fold count matches the list', (
    tester,
  ) async {
    AgentsAutomation watcher(String id, String state, double created) =>
        AgentsAutomation.fromPayload(<String, dynamic>{
          'id': id,
          'session_key': 'thread-1',
          'kind': 'watcher',
          'name': 'Wahlradar LT Sachsen-Anhalt 2026',
          'state': state,
          'spec': {'script_path': 'monitor_lt26.py', 'restart': true},
          'created_at': created,
        })!;
    await pump(tester);
    controller.emit(
      AgentsRelayAutomationList(
        automations: [
          watcher('dead', 'done', 10),
          watcher('live', 'active', 20),
        ],
      ),
    );
    await tester.pump();
    // The dead twin is the same automation, so it is neither a second row nor
    // something the reader is invited to unfold.
    expect(find.byType(AutomationCard), findsOneWidget);
    expect(find.textContaining('finished'), findsNothing);
    expect(find.text('active'), findsOneWidget);
    expect(find.text('done'), findsNothing);
  });

  testWidgets('the body does not repeat the heading of the pane', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Automations'), findsOneWidget);
  });

  testWidgets(
    'chat scope filters live and finished rows and requests only this chat',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AutomationsPage(sessionKey: 'thread-1', chatName: 'Alex'),
        ),
      );
      await tester.pump();
      expect(controller.listRequests, ['thread-1']);
      controller.emit(
        AgentsRelayAutomationList(
          automations: [
            _automation('mine'),
            _automation('mine-done', state: 'done'),
            _automation('other', session: 'thread-2'),
            _automation('other-done', session: 'thread-2', state: 'done'),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('job mine'), findsOneWidget);
      expect(find.text('job other'), findsNothing);
      expect(find.text('Show 1 finished'), findsOneWidget);
      await tester.tap(find.text('Show 1 finished'));
      await tester.pump();
      expect(find.text('job mine-done'), findsOneWidget);
      expect(find.text('job other-done'), findsNothing);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      expect(controller.listRequests.last, 'thread-1');
      controller.emit(
        AgentsRelayAutomation(
          event: 'created',
          automation: _automation('other-live', session: 'thread-2'),
        ),
      );
      await tester.pump();
      expect(find.text('job other-live'), findsNothing);
    },
  );
}
