import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import 'package:chuk_chat/widgets/agents_desktop/desktop_controls.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';

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

AgentsThreadAction _action(String tooltip, List<String> log) =>
    AgentsThreadAction(
      icon: Icons.tune,
      tooltip: tooltip,
      onPressed: () => log.add(tooltip),
    );

void main() {
  testWidgets('the coworker and its role name the thread', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const AgentsThreadHeader(title: 'Marta', subtitle: 'release manager'),
      ),
    );

    expect(find.text('Marta'), findsOneWidget);
    expect(find.text('release manager'), findsOneWidget);
    // A live socket is not news: no state line, only the dot.
    expect(find.text('Connecting…'), findsNothing);
    expect(find.byTooltip('Connected'), findsOneWidget);
  });

  testWidgets('a connection that is down says so on hover', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const AgentsThreadHeader(
          title: 'Marta',
          subtitle: 'release manager',
          connection: AgentsThreadConnection.down,
        ),
      ),
    );

    // Still no status line about the socket: the connection is not the
    // user's job. The subject's tooltip says it.
    expect(find.text('Offline'), findsNothing);
    expect(find.text('release manager'), findsOneWidget);
    expect(find.byTooltip('Offline'), findsOneWidget);
  });

  testWidgets('the automation chip names the run and toggles the cards', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          title: 'Marta',
          automationLabel: 'Wahlradar · Active',
          onToggleAutomations: () => toggles++,
        ),
      ),
    );

    expect(find.text('Wahlradar · Active'), findsOneWidget);
    expect(findIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.text('Wahlradar · Active'));
    expect(toggles, 1);
  });

  testWidgets('no automation, no chip', (tester) async {
    await tester.pumpWidget(_wrap(const AgentsThreadHeader(title: 'Marta')));

    expect(findIcon(Icons.expand_more), findsNothing);
    expect(findIcon(Icons.expand_less), findsNothing);
  });

  testWidgets('every action is a button of its own, and each one fires', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          title: 'Marta',
          actions: <AgentsThreadAction>[
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

  testWidgets(
    'a narrow header folds actions into a menu instead of overflowing',
    (tester) async {
      final log = <String>[];
      await tester.pumpWidget(
        _wrap(
          AgentsThreadHeader(
            title: 'Marta',
            actions: <AgentsThreadAction>[
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
    },
  );

  testWidgets('the dense phone header drops the title, keeps the actions', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          title: 'Marta',
          subtitle: 'release manager',
          dense: true,
          topInset: 60,
          automationLabel: '2 automations',
          onToggleAutomations: () {},
          actions: <AgentsThreadAction>[_action('Documents', log)],
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

  testWidgets('the desktop bar is 48 px, solid, with a hairline under it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const AgentsThreadHeader(title: 'Marta', floating: true)),
    );

    // Part of the frame (docs/DESIGN.md §14.1): no veil, no gradient.
    final Finder veil = find.descendant(
      of: find.byType(AgentsThreadHeader),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient != null,
      ),
    );
    expect(veil, findsNothing);
    expect(
      tester.getSize(find.byType(AgentsThreadHeader)).height,
      kDeskBarHeight,
    );
    expect(
      find.descendant(
        of: find.byType(AgentsThreadHeader),
        matching: find.byType(DeskHairline),
      ),
      findsOneWidget,
    );
  });

  testWidgets('bar buttons are 32 px and a toggle that is on is filled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          title: 'Marta',
          actions: <AgentsThreadAction>[
            AgentsThreadAction(
              icon: Icons.view_sidebar_outlined,
              tooltip: 'Details',
              selected: true,
              onPressed: () {},
            ),
          ],
          menuActions: <AgentsThreadAction>[
            AgentsThreadAction(
              icon: Icons.copy_all_rounded,
              tooltip: 'Copy Debug Chat',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    final DeskIconButton details = tester.widget<DeskIconButton>(
      find.ancestor(
        of: find.byTooltip('Details'),
        matching: find.byType(DeskIconButton),
      ),
    );
    expect(details.selected, isTrue);
    expect(details.size, 32);
    expect(details.glyph, 20);
    // The menu action is not a button of its own: it waits behind "…".
    expect(find.byTooltip('Copy Debug Chat'), findsNothing);
    expect(find.byTooltip('More actions'), findsOneWidget);
  });
}
