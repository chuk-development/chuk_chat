import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../platform_specific/mobile/mobile_support.dart' show agent, findId;
import '../support/icon_finder.dart';

import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';

/// The header only ever gets the width its parent has, so every test states
/// one: what folds and what fits is part of the widget.
Widget _wrap(Widget child, {double width = 700}) => MaterialApp(
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
  testWidgets("the header is the phone's top bar: the coworker on the left, "
      'Documents, Screen and "…" on the right', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
          showScreenTarget: true,
          onOpenDocuments: () => log.add('Documents'),
          menuActions: <AgentsThreadAction>[_action('Copy full chat', log)],
        ),
      ),
    );

    // The coworker pill: its name and its status line.
    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('Active now'), findsOneWidget);
    expect(find.byType(AgentChromePill), findsOneWidget);
    final double pillLeft = tester.getTopLeft(find.byType(AgentChromePill)).dx;
    expect(pillLeft, 50 + AgentsThreadHeader.edge);

    // The phone's chips, in the phone's order, at the right edge.
    final double docs = tester.getCenter(findId('thread_header_documents')).dx;
    final double screen = tester.getCenter(findId('thread_header_screen')).dx;
    final double more = tester.getCenter(findId('thread_header_more')).dx;
    expect(docs, lessThan(screen));
    expect(screen, lessThan(more));
    expect(find.byType(ChromeChip), findsNWidgets(3));
    for (final Element chip in find.byType(ChromeChip).evaluate()) {
      expect(tester.getSize(find.byWidget(chip.widget)), const Size(48, 48));
    }
    // 12 px from the pane's edge to the painted chip (48 box, 42 painted).
    expect(
      tester.getTopRight(find.byType(ChromeChip).last).dx,
      750 - AgentsThreadHeader.edge + 3,
    );

    // The extra actions are not buttons of their own: they wait behind "…".
    expect(find.byTooltip('Copy full chat'), findsNothing);
    await tester.tap(find.byTooltip('Documents'));
    expect(log, <String>['Documents']);
  });

  testWidgets('the row sits on the page colour and fades out below it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
          showScreenTarget: true,
        ),
      ),
    );
    final Finder header = find.byType(AgentsThreadHeader);
    final Color page = Theme.of(tester.element(header)).scaffoldBackgroundColor;

    expect(tester.getSize(header).height, AgentsThreadHeader.height);
    // Solid behind the row, so no message runs into a chip.
    final ColoredBox solid = tester.widget<ColoredBox>(
      find.descendant(of: header, matching: find.byType(ColoredBox)).first,
    );
    expect(solid.color, page);
    // The fade under it: page colour to nothing, and only paint.
    final Finder fade = find.byKey(
      const ValueKey<String>('agents-header-fade'),
    );
    expect(tester.getSize(fade).height, AgentsThreadHeader.fade);
    final DecoratedBox fadeBox = tester.widget<DecoratedBox>(
      find.descendant(of: fade, matching: find.byType(DecoratedBox)),
    );
    final LinearGradient gradient =
        (fadeBox.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, <Color>[page, page.withValues(alpha: 0)]);
    expect(
      find.ancestor(of: fade, matching: find.byType(IgnorePointer)),
      findsWidgets,
    );
    // The row is on the line of the desktop's chrome buttons.
    expect(
      tester.getCenter(findId('thread_header_screen')).dy,
      AgentsThreadHeader.rowTop + AgentsThreadHeader.chipBox / 2,
    );
  });

  testWidgets('a tap on the coworker opens what the caller wired', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
          onOpenAgent: () => opened++,
        ),
      ),
    );
    await tester.tap(find.text('Alex'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('no thread open, nothing to show: no pill, no chips', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const AgentsThreadHeader()));

    expect(find.byType(AgentChromePill), findsNothing);
    expect(find.byType(ChromeChip), findsNothing);
  });

  testWidgets('the automation chip names the run and toggles the cards', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
          automationLabel: 'Wahlradar · Active',
          onToggleAutomations: () => toggles++,
        ),
      ),
    );

    expect(find.text('Wahlradar · Active'), findsOneWidget);
    expect(findIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.text('Wahlradar · Active'));
    expect(toggles, 1);
    // It stays inside the left side the shell keeps the switch clear of.
    final double right = tester.getTopRight(find.text('Wahlradar · Active')).dx;
    expect(
      right,
      lessThanOrEqualTo(
        50 + AgentsThreadHeader.edge + AgentsThreadHeader.leadingMaxWidth,
      ),
    );
  });

  testWidgets('no automation, no chip', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
        ),
      ),
    );

    expect(findIcon(Icons.expand_more), findsNothing);
    expect(findIcon(Icons.expand_less), findsNothing);
  });

  testWidgets('"…" holds the menu actions, and each one fires', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
          menuActions: <AgentsThreadAction>[
            _action('Details', log),
            _action('Copy full chat', log),
          ],
        ),
      ),
    );

    for (final String label in <String>['Details', 'Copy full chat']) {
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(log, <String>['Details', 'Copy full chat']);
  });

  testWidgets('a narrow pane folds Documents into "…" instead of '
      'overflowing', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alexandra the long-named'),
          showScreenTarget: true,
          onOpenDocuments: () => log.add('Documents'),
        ),
        width: 260,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(findId('thread_header_documents'), findsNothing);
    // Folded, not dropped.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(log, <String>['Documents']);
  });

  testWidgets('a toggle that is on takes the accent in the menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
          menuActions: <AgentsThreadAction>[
            AgentsThreadAction(
              icon: Icons.tune,
              tooltip: 'Details',
              selected: true,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    final Finder glyph = findIcon(Icons.tune);
    expect(
      iconColor(tester, glyph),
      Theme.of(tester.element(glyph)).colorScheme.primary,
    );
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

  testWidgets('a relay that is down says so in the pill and offers the way '
      'back; a live or returning one says nothing', (tester) async {
    for (final AgentsThreadConnection state in <AgentsThreadConnection>[
      AgentsThreadConnection.live,
      AgentsThreadConnection.connecting,
    ]) {
      await tester.pumpWidget(
        _wrap(
          AgentsThreadHeader(
            agent: agent(id: 'a1', name: 'Alex'),
            connection: state,
          ),
        ),
      );
      expect(find.textContaining('Offline'), findsNothing, reason: '$state');
    }

    var reconnects = 0;
    await tester.pumpWidget(
      _wrap(
        AgentsThreadHeader(
          agent: agent(id: 'a1', name: 'Alex'),
          connection: AgentsThreadConnection.down,
          onReconnect: () => reconnects++,
        ),
      ),
    );
    await tester.tap(find.text('Offline · Reconnect'));
    expect(reconnects, 1);

    // No coworker to carry it: a chip of its own.
    await tester.pumpWidget(
      _wrap(const AgentsThreadHeader(connection: AgentsThreadConnection.down)),
    );
    expect(find.text('Offline'), findsOneWidget);
  });
}
