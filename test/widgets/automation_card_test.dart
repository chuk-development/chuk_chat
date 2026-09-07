import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/automations/cowork_automation.dart';
import 'package:cowork/widgets/automation_card.dart';

CoworkAutomation _automation({
  String state = 'active',
  String kind = 'schedule',
  int fireCount = 3,
  String? error,
}) =>
    CoworkAutomation.fromPayload(<String, dynamic>{
      'id': 'ab12cd34',
      'session_key': 'thread-1',
      'kind': kind,
      'name': 'inbox check',
      'state': state,
      'spec': kind == 'watcher' ? {'script_path': 'poll.py'} : {'every': 300},
      'prompt': 'check the inbox',
      'fire_count': fireCount,
      'next_fire_at': DateTime.now().add(const Duration(minutes: 4)).millisecondsSinceEpoch / 1000,
      'last_fired_at': DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch / 1000,
      'last_error': ?error,
    })!;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('an active schedule shows its facts and offers Pause + Cancel',
      (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(_wrap(AutomationCard(
      automation: _automation(),
      onPause: () => pressed.add('pause'),
      onResume: () => pressed.add('resume'),
      onCancel: () => pressed.add('cancel'),
    )));
    expect(find.text('inbox check'), findsOneWidget);
    expect(find.text('active'), findsOneWidget);
    expect(find.textContaining('every 5m'), findsOneWidget);
    expect(find.textContaining('next in 3m'), findsOneWidget);
    expect(find.textContaining('fired 3×'), findsOneWidget);
    expect(find.text('check the inbox'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Resume'), findsNothing);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    await tester.tap(find.byTooltip('Cancel'));
    expect(pressed, ['pause', 'cancel']);
  });

  testWidgets('a paused one offers Resume; a finished one offers nothing',
      (tester) async {
    await tester.pumpWidget(_wrap(AutomationCard(
      automation: _automation(state: 'paused'),
      onPause: () {},
      onResume: () {},
      onCancel: () {},
    )));
    expect(find.byTooltip('Resume'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsNothing);

    await tester.pumpWidget(_wrap(AutomationCard(
      automation: _automation(state: 'done'),
      onPause: () {},
      onResume: () {},
      onCancel: () {},
    )));
    expect(find.byType(IconButton), findsNothing);
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('a failed watcher shows its error and the watch spec',
      (tester) async {
    await tester.pumpWidget(_wrap(AutomationCard(
      automation: _automation(state: 'failed', kind: 'watcher', error: 'exit code 3'),
      compact: true,
    )));
    expect(find.text('exit code 3'), findsOneWidget);
    expect(find.textContaining('watch poll.py'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    // Compact hides the prompt line.
    expect(find.text('check the inbox'), findsNothing);
  });

  testWidgets('every row says which kind it is, not only the footnote',
      (tester) async {
    await tester.pumpWidget(_wrap(AutomationCard(automation: _automation())));
    expect(find.textContaining('Schedule · every 5m'), findsOneWidget);

    await tester.pumpWidget(_wrap(AutomationCard(
      automation: _automation(kind: 'watcher'),
    )));
    expect(find.textContaining('Watcher · watch poll.py'), findsOneWidget);
  });

  testWidgets('a long task is one line until the row is opened', (tester) async {
    final long = List<String>.filled(60, 'sammle die zahlen').join(' ');
    final a = CoworkAutomation.fromPayload(<String, dynamic>{
      'id': 'x1',
      'session_key': 'thread-1',
      'kind': 'schedule',
      'name': 'Wahlradar',
      'state': 'active',
      'spec': {'at': '2026-09-06T09:00:00Z'},
      'prompt': long,
    })!;
    await tester.pumpWidget(_wrap(AutomationCard(automation: a)));
    Text prompt() => tester.widget<Text>(find.text(long));
    expect(prompt().maxLines, 1);
    await tester.tap(find.text(long));
    await tester.pump();
    expect(prompt().maxLines, greaterThan(1));
  });
}

