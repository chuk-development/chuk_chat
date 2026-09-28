import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/ui/expressive/staggered.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

Widget _host({required List<Widget> children}) {
  return MaterialApp(
    home: Scaffold(body: SettingsListView(children: children)),
  );
}

void main() {
  List<Widget> rows(int count) => <Widget>[
    for (var i = 0; i < count; i++)
      SizedBox(height: 40, child: Text('row $i')),
  ];

  // One list for both builds: upstream chuk_chat's rows stand still, whatever
  // the Agents flag says.
  for (final bool agents in <bool>[false, true]) {
    final String build = agents ? ' (Agents)' : '';

    testWidgets('renders every child$build', (WidgetTester tester) async {
      debugAgentsChatCoreOverride = agents;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await tester.pumpWidget(_host(children: rows(12)));
      await tester.pumpAndSettle();

      for (var i = 0; i < 12; i++) {
        expect(find.text('row $i'), findsOneWidget);
      }
    });

    testWidgets('the rows do not cascade in$build', (
      WidgetTester tester,
    ) async {
      debugAgentsChatCoreOverride = agents;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await tester.pumpWidget(_host(children: rows(6)));

      // The very first frame already shows every row in place.
      expect(find.byType(StaggeredItem), findsNothing);
      for (var i = 0; i < 6; i++) {
        expect(find.text('row $i'), findsOneWidget);
      }
    });
  }
}
