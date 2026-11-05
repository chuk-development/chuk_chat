// The main agent in the phone inbox (bead chuk_chat-lgq2.13.3): one agent on
// top, in its own "Your assistant" section and a larger row; "Make main
// agent" in the row menu moves it; a search folds it back into the list.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/roster_pins.dart';

import 'mobile_support.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RosterPins.instance.reset();
  });
  tearDown(RosterPins.instance.reset);

  final DateTime now = DateTime(2026, 1, 5, 15);

  LocalAgentRosterSource roster() => rosterWith(<AgentsAgent>[
    agent(id: 'host', name: 'Your computer', onHost: true),
    agent(id: 'amber', name: 'Amber', lastActivity: DateTime(2026, 1, 5, 14)),
    agent(id: 'jade', name: 'Jade', lastActivity: DateTime(2026, 1, 5, 9)),
  ]);

  Future<LocalAgentRosterSource> pumpList(
    WidgetTester tester, {
    bool section = true,
  }) async {
    final LocalAgentRosterSource source = roster();
    addTearDown(source.dispose);
    await pumpPhone(
      tester,
      MobileAgentList(
        source: source,
        onSelect: (_, _) {},
        onAddAgent: () {},
        onDeleteAgent: (_) {},
        now: () => now,
        mainAgentSection: section,
      ),
    );
    await tester.pumpAndSettle();
    return source;
  }

  double top(WidgetTester tester, String id) =>
      tester.getRect(find.byKey(ValueKey<String>('mobile-agent-$id'))).top;

  testWidgets('the first agent is the main agent, on top, under "Your '
      'assistant", in a larger row', (tester) async {
    await pumpList(tester);
    expect(find.text('Your assistant'), findsOneWidget);
    final double label = tester
        .getRect(find.byKey(const ValueKey<String>('mobile-main-label')))
        .top;
    expect(label, lessThan(top(tester, 'host')));
    expect(top(tester, 'host'), lessThan(top(tester, 'amber')));
    expect(top(tester, 'amber'), lessThan(top(tester, 'jade')));
    // The rest sits under a label of its own.
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('mobile-rest-label')))
          .top,
      lessThan(top(tester, 'amber')),
    );
    final double mainHeight = tester
        .getSize(find.byKey(const ValueKey<String>('mobile-agent-host')))
        .height;
    final double rowHeight = tester
        .getSize(find.byKey(const ValueKey<String>('mobile-agent-amber')))
        .height;
    expect(mainHeight, greaterThan(rowHeight));
  });

  testWidgets('"Make main agent" in the row menu moves the agent to the top',
      (tester) async {
    await pumpList(tester);
    await tester.longPress(find.byKey(const ValueKey<String>('mobile-agent-jade')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make main agent'));
    await tester.pumpAndSettle();

    expect(RosterPins.instance.mainAgentId, 'jade');
    expect(top(tester, 'jade'), lessThan(top(tester, 'host')));

    // The main agent's own menu does not offer it again.
    await tester.longPress(find.byKey(const ValueKey<String>('mobile-agent-jade')));
    await tester.pumpAndSettle();
    expect(find.text('Make main agent'), findsNothing);
  });

  testWidgets('a hidden main agent falls back to the first one shown', (
    tester,
  ) async {
    RosterPins.instance.setMainAgent('amber');
    final LocalAgentRosterSource source = await pumpList(tester);
    expect(top(tester, 'amber'), lessThan(top(tester, 'host')));
    source.hideAgent('amber');
    await tester.pumpAndSettle();
    expect(find.text('Your assistant'), findsOneWidget);
    expect(top(tester, 'host'), lessThan(top(tester, 'jade')));
  });

  testWidgets('a search folds the section back into the list', (tester) async {
    await pumpList(tester);
    await tester.tap(findId('mobile_home_search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'e');
    await tester.pumpAndSettle();
    expect(find.text('Your assistant'), findsNothing);
    // All three match "e"; the main agent (Your computer) comes first.
    expect(top(tester, 'host'), lessThan(top(tester, 'amber')));
  });

  testWidgets('without the flag the list is as it was', (tester) async {
    await pumpList(tester, section: false);
    expect(find.text('Your assistant'), findsNothing);
    expect(find.text('Make main agent'), findsNothing);
  });
}
