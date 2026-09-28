import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import 'package:chuk_chat/widgets/agents_thread_header.dart';

/// The row only ever gets the width its parent has, so every test states
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
  testWidgets("the row is chuk's floating buttons: no bar, no title", (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          showScreenTarget: true,
          actions: <AgentsThreadAction>[_action('Documents', log)],
        ),
      ),
    );

    // No band behind the buttons: no fill, no gradient, no rule.
    final Finder painted = find.descendant(
      of: find.byType(AgentsThreadHeader),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            ((w.decoration as BoxDecoration).gradient != null ||
                (w.decoration as BoxDecoration).border != null),
      ),
    );
    expect(painted, findsNothing);
    // chuk's icon button: 40 px of ink around a 20 px glyph.
    expect(
      tester.getSize(find.byType(ChromeIconButton).first),
      const Size(40, 40),
    );
    // Floating at the right edge of the chat, not stretched across it.
    expect(tester.getTopRight(find.byTooltip('Documents')).dx, 800);
    expect(tester.getSize(find.byType(AgentsThreadHeader)).height, 40);
  });

  testWidgets('the automation chip names the run and toggles the cards', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
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
    await tester.pumpWidget(_wrap(const AgentsThreadHeader()));

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
          actions: <AgentsThreadAction>[
            _action('Documents', log),
            _action('Control Rooms', log),
            _action('Details', log),
            _action('Copy full chat', log),
          ],
        ),
      ),
    );

    for (final tooltip in <String>[
      'Documents',
      'Control Rooms',
      'Details',
      'Copy full chat',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
      await tester.tap(find.byTooltip(tooltip));
    }
    expect(log, <String>[
      'Documents',
      'Control Rooms',
      'Details',
      'Copy full chat',
    ]);
    // Nothing was pushed off the edge on the way.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow row folds actions into a menu instead of '
      'overflowing', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          actions: <AgentsThreadAction>[
            _action('Documents', log),
            _action('Control Rooms', log),
            _action('Details', log),
            _action('Copy full chat', log),
          ],
        ),
        width: 120,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('More actions'), findsOneWidget);
    // Folded, not dropped: the menu still reaches the last action.
    expect(find.byTooltip('Copy full chat'), findsNothing);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy full chat'));
    await tester.pumpAndSettle();
    expect(log, <String>['Copy full chat']);
  });

  testWidgets('a toggle that is on takes the accent; menu actions wait '
      'behind "…"', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          actions: <AgentsThreadAction>[
            AgentsThreadAction(
              icon: Icons.tune,
              tooltip: 'Details',
              selected: true,
              onPressed: () {},
            ),
          ],
          menuActions: <AgentsThreadAction>[
            AgentsThreadAction(
              icon: Icons.person_outline,
              tooltip: 'Profile',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    final ChromeIconButton details = tester.widget<ChromeIconButton>(
      find.ancestor(
        of: find.byTooltip('Details'),
        matching: find.byType(ChromeIconButton),
      ),
    );
    expect(details.selected, isTrue);
    final Finder glyph = find.descendant(
      of: find.byTooltip('Details'),
      matching: findIcon(Icons.tune),
    );
    expect(
      iconColor(tester, glyph),
      Theme.of(tester.element(glyph)).colorScheme.primary,
    );
    // The menu action is not a button of its own: it waits behind "…".
    expect(find.byTooltip('Profile'), findsNothing);
    expect(find.byTooltip('More actions'), findsOneWidget);
  });

  testWidgets('the screen target is parked until there is a screen, and a '
      'parked tap still answers', (tester) async {
    await tester.pumpWidget(
      _wrap(const AgentsThreadHeader(showScreenTarget: true)),
    );
    expect(find.byTooltip('No screen open right now'), findsOneWidget);
    await tester.tap(find.byTooltip('No screen open right now'));
    await tester.pump();
    expect(
      find.text('The coworker has no screen open right now'),
      findsOneWidget,
    );

    var opened = 0;
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          showScreenTarget: true,
          onOpenScreen: () => opened++,
        ),
      ),
    );
    await tester.tap(find.byTooltip("Agent's screen"));
    expect(opened, 1);
  });

  testWidgets('a relay that is down says so and offers the way back; a live '
      'or returning one says nothing', (tester) async {
    for (final AgentsThreadConnection state in <AgentsThreadConnection>[
      AgentsThreadConnection.live,
      AgentsThreadConnection.connecting,
    ]) {
      await tester.pumpWidget(_wrap(AgentsThreadHeader(connection: state)));
      expect(find.textContaining('Offline'), findsNothing, reason: '$state');
    }

    var reconnects = 0;
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          connection: AgentsThreadConnection.down,
          onReconnect: () => reconnects++,
        ),
      ),
    );
    await tester.tap(find.text('Offline · Reconnect'));
    expect(reconnects, 1);

    await tester.pumpWidget(
      _wrap(const AgentsThreadHeader(connection: AgentsThreadConnection.down)),
    );
    expect(find.text('Offline'), findsOneWidget);
  });
}
