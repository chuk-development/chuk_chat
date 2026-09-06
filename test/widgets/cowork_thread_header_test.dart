import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/widgets/cowork_thread_header.dart';

/// The header only ever gets the width its parent has, so every test states
/// one: what folds and what fits is the whole point of the widget.
Widget _wrap(Widget child, {double width = 900}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: width, child: child),
    ),
  ),
);

CoworkThreadAction _action(String tooltip, List<String> log) =>
    CoworkThreadAction(
      icon: Icons.tune,
      tooltip: tooltip,
      onPressed: () => log.add(tooltip),
    );

void main() {
  testWidgets('the coworker and its role name the thread', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const CoworkThreadHeader(title: 'Marta', subtitle: 'release manager'),
      ),
    );

    expect(find.text('Marta'), findsOneWidget);
    expect(find.text('release manager'), findsOneWidget);
    // A live socket is not news: no state line, only the dot.
    expect(find.text('Connecting…'), findsNothing);
    expect(find.byTooltip('Connected'), findsOneWidget);
  });

  testWidgets('a connection that is down colours the dot and says so on hover', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const CoworkThreadHeader(
          title: 'Marta',
          subtitle: 'release manager',
          connection: CoworkThreadConnection.down,
        ),
      ),
    );

    // Still no status line anywhere: the connection is not the user's job.
    expect(find.text('Offline'), findsNothing);
    expect(find.text('release manager'), findsOneWidget);
    expect(find.byTooltip('Offline'), findsOneWidget);
    final dot = tester.widget<Icon>(
      find.descendant(
        of: find.byTooltip('Offline'),
        matching: find.byIcon(Icons.circle),
      ),
    );
    expect(dot.color, Theme.of(tester.element(find.text('Marta'))).colorScheme.error);
  });

  testWidgets('the automation chip names the run and toggles the cards', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _wrap(
        CoworkThreadHeader(
          title: 'Marta',
          automationLabel: 'Wahlradar · Active',
          onToggleAutomations: () => toggles++,
        ),
      ),
    );

    expect(find.text('Wahlradar · Active'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.text('Wahlradar · Active'));
    expect(toggles, 1);
  });

  testWidgets('no automation, no chip', (tester) async {
    await tester.pumpWidget(_wrap(const CoworkThreadHeader(title: 'Marta')));

    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsNothing);
  });

  testWidgets('every action is a button of its own, and each one fires', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        CoworkThreadHeader(
          title: 'Marta',
          actions: <CoworkThreadAction>[
            _action('Documents', log),
            _action('Agent controls', log),
            _action('Control Rooms', log),
            _action('Copy Debug Chat', log),
          ],
        ),
      ),
    );

    for (final tooltip in <String>[
      'Documents',
      'Agent controls',
      'Control Rooms',
      'Copy Debug Chat',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
      await tester.tap(find.byTooltip(tooltip));
    }
    expect(log, <String>[
      'Documents',
      'Agent controls',
      'Control Rooms',
      'Copy Debug Chat',
    ]);
    // Nothing was pushed off the edge on the way.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow header folds actions into a menu instead of overflowing', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        CoworkThreadHeader(
          title: 'Marta',
          actions: <CoworkThreadAction>[
            _action('Documents', log),
            _action('Agent controls', log),
            _action('Control Rooms', log),
            _action('Copy Debug Chat', log),
          ],
        ),
        width: 220,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('More actions'), findsOneWidget);
    // Folded, not dropped: the menu still reaches the last action.
    expect(find.byTooltip('Copy Debug Chat'), findsNothing);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Debug Chat'));
    await tester.pumpAndSettle();
    expect(log, <String>['Copy Debug Chat']);
  });

  testWidgets('the dense phone header drops the title, keeps the actions', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        CoworkThreadHeader(
          title: 'Marta',
          subtitle: 'release manager',
          dense: true,
          topInset: 60,
          automationLabel: '2 automations',
          onToggleAutomations: () {},
          actions: <CoworkThreadAction>[_action('Documents', log)],
        ),
        width: 380,
      ),
    );

    // The floating chrome above already carries the coworker.
    expect(find.text('Marta'), findsNothing);
    expect(find.text('release manager'), findsNothing);
    expect(find.text('2 automations'), findsOneWidget);
    expect(find.byTooltip('Documents'), findsOneWidget);
    // It starts below the chrome, never behind it.
    expect(
      tester.getTopLeft(find.byTooltip('Documents')).dy,
      greaterThanOrEqualTo(60),
    );
  });
}
