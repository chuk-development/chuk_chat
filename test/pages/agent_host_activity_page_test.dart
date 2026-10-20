import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_host_activity_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';

void main() {
  const AgentsAgent agent = AgentsAgent(
    id: 'host:mail',
    name: 'Mail',
    onHost: true,
    threads: <AgentsThreadInfo>[
      AgentsThreadInfo(key: 'host:mail', title: 'General'),
    ],
  );

  Future<void> pushPage(WidgetTester tester, AgentControlSource source) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AgentHostActivityPage(agent: agent, source: source),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the page wears the shared header: one back chip, the title '
      'pill, a bar with no fill over a list that runs behind it', (
    tester,
  ) async {
    final FakeAgentControlSource source = FakeAgentControlSource();
    addTearDown(source.dispose);
    await pushPage(tester, source);

    final Scaffold scaffold = tester.widget<Scaffold>(
      find.ancestor(
        of: find.byType(FloatingAppBar),
        matching: find.byType(Scaffold),
      ),
    );
    expect(scaffold.extendBodyBehindAppBar, isTrue);
    final AppBar bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.backgroundColor, Colors.transparent);
    expect(find.text('Host & activity'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    // No messenger channel on the page.
    expect(find.textContaining('Telegram'), findsNothing);
  });

  testWidgets('Refresh asks the host again', (tester) async {
    final FakeAgentControlSource source = FakeAgentControlSource();
    addTearDown(source.dispose);
    await pushPage(tester, source);
    expect(source.refreshed, <String>['host:mail']);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(source.refreshed, <String>['host:mail', 'host:mail']);
  });

  testWidgets('the header chips take a 48 px press', (tester) async {
    final FakeAgentControlSource source = FakeAgentControlSource();
    addTearDown(source.dispose);
    await pushPage(tester, source);
    for (final String tip in <String>['Back', 'Refresh']) {
      final Size size = tester.getSize(
        find.descendant(
          of: find.byTooltip(tip),
          matching: find.byType(InkResponse),
        ),
      );
      expect(size.width, greaterThanOrEqualTo(48), reason: tip);
      expect(size.height, greaterThanOrEqualTo(48), reason: tip);
    }
  });
}
