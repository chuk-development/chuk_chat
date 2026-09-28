import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_profile_page.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';

import '../support/test_app.dart';

void main() {
  // The page runs under chuk's floating header. The header band grows by the
  // status bar, so the face must clear the band at every status-bar height,
  // not only at the zero a test gets by default.
  for (final double statusBar in <double>[0, 24, 48]) {
    testWidgets('the floating header does not cover the face with a '
        '${statusBar.toInt()} px status bar', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(top: statusBar);
      tester.view.viewPadding = FakeViewPadding(top: statusBar);
      addTearDown(tester.view.reset);
      final store = AgentProfileStore();
      final source = LocalAgentRosterSource(
        seed: <AgentsAgent>[
          const AgentsAgent(id: 'alex', name: 'Alex', threads: []),
        ],
      );
      addTearDown(store.dispose);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        testApp(
          AgentProfilePage(agentId: 'alex', source: source, profiles: store),
        ),
      );
      await tester.pumpAndSettle();

      final Rect header = tester.getRect(find.byType(AppBar));
      final Rect face = tester.getRect(find.byType(AgentFace));
      expect(header.bottom, 62 + statusBar);
      expect(face.top, greaterThanOrEqualTo(header.bottom));
      expect(tester.takeException(), isNull);
    });
  }
}
