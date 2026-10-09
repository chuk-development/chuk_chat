// The first page of the desktop details pane: the coworker's screen box and
// its routines.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/widgets/agent_details_overview.dart';

import '../services/automations/automations_source_test.dart'
    show FakeAutomationController;

AgentsAutomation _routine(
  String id, {
  String session = 'amber-main',
  String state = 'active',
  String kind = 'schedule',
  Map<String, dynamic> spec = const <String, dynamic>{'cron': '13 8 * * *'},
  String? name,
}) => AgentsAutomation.fromPayload(<String, dynamic>{
  'id': id,
  'session_key': session,
  'kind': kind,
  'name': name ?? 'Job $id',
  'state': state,
  'spec': spec,
  'created_at': id.hashCode.toDouble(),
})!;

void main() {
  final AutomationsSource source = AutomationsSource.instance;
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

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onOpenScreen,
    VoidCallback? onScreenParked,
  }) async {
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentDetailsOverview(
            name: 'Amber',
            sessionKey: 'amber-main',
            onOpenScreen: onOpenScreen,
            onScreenParked: onScreenParked,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final Finder screen = find.byKey(const ValueKey<String>('details-screen'));

  testWidgets('a live screen is a 16:10 box that opens the viewer', (
    tester,
  ) async {
    int opened = 0;
    await pump(tester, onOpenScreen: () => opened++);

    final Size box = tester.getSize(
      find.descendant(of: screen, matching: find.byType(AspectRatio)),
    );
    expect(box.width / box.height, closeTo(1.6, 0.01));
    expect(find.text("Amber's screen"), findsOneWidget);
    expect(find.text('Open screen'), findsOneWidget);

    await tester.tap(screen);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('no screen: a quiet box, and a tap says why', (tester) async {
    int parked = 0;
    await pump(tester, onScreenParked: () => parked++);
    expect(find.text('Open screen'), findsNothing);
    expect(find.text("Amber's screen"), findsOneWidget);

    await tester.tap(screen);
    await tester.pump();
    expect(parked, 1);
  });

  testWidgets('routines: asks the host once, shows this coworker\'s live '
      'ones, and says so when there are none', (tester) async {
    await pump(tester);
    expect(controller.listRequests, <String?>['amber-main']);
    expect(find.text('Routines'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('details-routines-empty')),
      findsOneWidget,
    );

    controller.emit(
      AgentsRelayAutomationList(
        sessionKey: 'amber-main',
        automations: <AgentsAutomation>[
          _routine('a1', name: 'OSS Voice Check'),
          _routine(
            'a2',
            state: 'paused',
            spec: const <String, dynamic>{'every': 1800},
          ),
          _routine('a3', state: 'done'),
          _routine('b1', session: 'cobalt-main'),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('OSS Voice Check'), findsOneWidget);
    expect(find.text('Every day at 08:13'), findsOneWidget);
    expect(find.text('Job a2'), findsOneWidget);
    expect(find.text('Every 30 minutes · Paused'), findsOneWidget);
    // History and other coworkers' routines are not this pane's business.
    expect(find.text('Job a3'), findsNothing);
    expect(find.text('Job b1'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('details-routines-empty')),
      findsNothing,
    );
  });

  testWidgets('a tap on a routine opens the automation editor', (tester) async {
    await pump(tester);
    controller.emit(
      AgentsRelayAutomationList(
        sessionKey: 'amber-main',
        automations: <AgentsAutomation>[
          _routine('a1', name: 'OSS Voice Check'),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('details-routine-a1')));
    await tester.pumpAndSettle();
    expect(find.text('Edit automation'), findsOneWidget);
  });

  group('routineScheduleText', () {
    String text(Map<String, dynamic> spec, {String kind = 'schedule'}) =>
        routineScheduleText(_routine('x', spec: spec, kind: kind));

    test('reads the plain cron shapes', () {
      expect(
        text(<String, dynamic>{'cron': '13 8 * * *'}),
        'Every day at 08:13',
      );
      expect(
        text(<String, dynamic>{'cron': '0 9 * * 1-5'}),
        'Weekdays at 09:00',
      );
      expect(
        text(<String, dynamic>{'cron': '30 18 * * 0,6'}),
        'Weekends at 18:30',
      );
      expect(
        text(<String, dynamic>{'cron': '0 7 * * 1'}),
        'Every Monday at 07:00',
      );
      expect(
        text(<String, dynamic>{'cron': '0 7 * * 7'}),
        'Every Sunday at 07:00',
      );
      // Anything else keeps the host's own words.
      expect(
        text(<String, dynamic>{'cron': '*/5 * * * *'}),
        'cron */5 * * * *',
      );
    });

    test('reads intervals and one-off times', () {
      expect(text(<String, dynamic>{'every': 1800}), 'Every 30 minutes');
      expect(text(<String, dynamic>{'every': 3600}), 'Every hour');
      expect(text(<String, dynamic>{'every': 7200}), 'Every 2 hours');
      expect(text(<String, dynamic>{'every': 86400}), 'Every day');
      expect(
        text(<String, dynamic>{'at': '2026-10-06T09:00:00'}),
        'Once at 2026-10-06 09:00',
      );
    });

    test('an event trigger keeps its label, capitalised', () {
      expect(
        text(<String, dynamic>{'script_path': 'poll.py'}, kind: 'watcher'),
        'Watch poll.py',
      );
    });
  });
}
