import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/main_agent_launcher.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_page.dart';

import 'dashboard_test_support.dart';

Finder _key(String k) => find.byKey(ValueKey<String>(k));

void main() {
  tearDown(() => MainAgentLauncher.instance.requests.value = null);

  group('packDashboardRows', () {
    List<DashboardWidget> ws(List<String> sizes) => <DashboardWidget>[
      for (int i = 0; i < sizes.length; i++)
        DashboardWidget.tryParse(<String, dynamic>{
          'id': 'w$i',
          'type': 'note',
          'size': sizes[i],
        })!,
    ];

    test('phone: halves pair, a full takes the row', () {
      final List<List<DashboardWidget>> rows = packDashboardRows(
        ws(<String>['half', 'half', 'half', 'full', 'half']),
        2,
      );
      expect(rows.map((List<DashboardWidget> r) => r.length), <int>[
        2,
        1,
        1,
        1,
      ]);
    });

    test('wide: a full takes two of four', () {
      final List<List<DashboardWidget>> rows = packDashboardRows(
        ws(<String>['full', 'half', 'half', 'full', 'full']),
        4,
      );
      expect(rows.map((List<DashboardWidget> r) => r.length), <int>[3, 2]);
    });
  });

  testWidgets('empty Home explains itself and the chips open the agent', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[]);
    await pumpDashboard(tester, host, height: 900);
    expect(find.text('Your Home is empty'), findsOneWidget);
    await tester.tap(find.text('Track push-ups, 100 a day'));
    expect(MainAgentLauncher.instance.requests.value, contains('push-ups'));
    expect(_key('dash-edit'), findsNothing);
  });

  testWidgets('tracker: a step logs at once and sends a log op', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[pushupsWidget()]);
    await pumpDashboard(tester, host, height: 900);
    expect(tester.widget<Text>(_key('tracker-today-pushups')).data, '55');
    await tester.tap(_key('tracker-step-pushups-1'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_key('tracker-today-pushups')).data, '65');
    expect(host.ops.single['action'], 'log');
    expect(host.ops.single['value'], 10);
    expect(find.text('3-day streak'), findsOneWidget);
  });

  testWidgets('tracker: undo logs the negative of the last entry', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[pushupsWidget()]);
    await pumpDashboard(tester, host, height: 900);
    await tester.tap(_key('tracker-menu-pushups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo last +25'));
    await tester.pumpAndSettle();
    expect(host.ops.single['value'], -25);
    expect(tester.widget<Text>(_key('tracker-today-pushups')).data, '30');
  });

  testWidgets('checklist: a tap ticks through a check op', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[checklistWidget()]);
    await pumpDashboard(tester, host, height: 900);
    expect(find.text('1 of 3'), findsOneWidget);
    await tester.tap(_key('check-groceries-eggs'));
    await tester.pumpAndSettle();
    expect(host.ops.single, containsPair('item', 'eggs'));
    expect(host.ops.single, containsPair('done', true));
    expect(find.text('2 of 3'), findsOneWidget);
  });

  testWidgets('the ask pill and a metric open the main agent', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[metricWidget()]);
    await pumpDashboard(tester, host, height: 900);
    expect(find.text('Ask your assistant'), findsOneWidget);
    await tester.tap(_key('dash-ask'));
    expect(MainAgentLauncher.instance.requests.value, '');
    await tester.tap(_key('metric-value-weight'));
    expect(MainAgentLauncher.instance.requests.value, contains('Weight'));
  });

  testWidgets('header: today as the title and a weather pill', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[weatherWidget()]);
    await pumpDashboard(tester, host, height: 900);
    expect(find.text('Today, November 2'), findsOneWidget);
    expect(find.text('8°  Kiel'), findsOneWidget);
  });

  testWidgets('agenda says when the next item starts', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[agendaWidget()]);
    await pumpDashboard(tester, host, height: 900);
    expect(find.text('in 30m'), findsOneWidget);
  });

  testWidgets('prompts open the main agent with the prompt', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[promptsWidget()]);
    await pumpDashboard(tester, host, height: 900);
    await tester.tap(_key('prompt-ask-1'));
    expect(
      MainAgentLauncher.instance.requests.value,
      'Summarise my unread mail.',
    );
    expect(host.ops, isEmpty);
  });

  testWidgets('metric, note, agenda, weather and chart draw their data', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[
      metricWidget(),
      noteWidget(),
      agendaWidget(),
      weatherWidget(),
      chartWidget(),
    ]);
    await pumpDashboard(tester, host, height: 2400);
    expect(tester.widget<Text>(_key('metric-value-weight')).data, '78.4');
    expect(find.text('-0.6 kg'), findsOneWidget);
    expect(find.textContaining('Ship the dashboard'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
    expect(tester.widget<Text>(_key('weather-temp-kiel')).data, '8°');
    expect(find.text('Sleep'), findsOneWidget);
    expect(find.text('Coach · 12 h ago'), findsNWidgets(2));
  });

  testWidgets('long-press enters edit mode; resize and remove send ops', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(realisticDashboard());
    await pumpDashboard(tester, host, height: 1400);
    await tester.longPress(_key('dash-tile-weight'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Home'), findsOneWidget);
    await tester.tap(_key('dash-size-weight'));
    await tester.pumpAndSettle();
    expect(host.ops.last['action'], 'update');
    expect(host.ops.last['patch'], <String, dynamic>{'size': 'full'});
    await tester.tap(_key('dash-remove-groceries'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Groceries?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(host.ops.last['action'], 'remove');
    expect(_key('dash-tile-groceries'), findsNothing);
    await tester.tap(_key('dash-edit-done'));
    await tester.pumpAndSettle();
    expect(find.text('Good evening'), findsOneWidget);
  });

  testWidgets('offline: the status says so and taps wait', (
    WidgetTester tester,
  ) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[pushupsWidget()]);
    host.host.value = null;
    await pumpDashboard(tester, host, height: 900);
    await tester.tap(_key('tracker-step-pushups-0'));
    await tester.pumpAndSettle();
    expect(host.ops, isEmpty);
    expect(
      find
          .descendant(of: _key('dash-status'), matching: find.byType(Text))
          .evaluate()
          .map((Element e) => (e.widget as Text).data)
          .single,
      'Your computer is offline · 1 change waits to sync',
    );
  });

  testWidgets('a refused op shows a message', (WidgetTester tester) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[pushupsWidget()]);
    await pumpDashboard(tester, host, height: 900);
    host.controller.handleFrame(<String, dynamic>{
      'type': 'dashboard_error',
      'op_id': 'x',
      'message': 'That widget is gone.',
    });
    await tester.pumpAndSettle();
    expect(find.text('That widget is gone.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  for (final double width in <double>[360, 1100]) {
    testWidgets('no overflow at $width px and 1.3 text scale', (
      WidgetTester tester,
    ) async {
      final FakeDashboardHost host = FakeDashboardHost();
      host.show(<Map<String, dynamic>>[
        ...realisticDashboard(),
        noteWidget(),
        chartWidget(),
      ]);
      await pumpDashboard(
        tester,
        host,
        width: width,
        height: 4000,
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(DashboardPage), findsOneWidget);
      // Edit mode too.
      await tester.tap(_key('dash-edit'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
