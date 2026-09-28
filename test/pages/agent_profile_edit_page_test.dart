import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_profile_edit_page.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import '../support/test_app.dart';

void main() {
  testWidgets(
    'shape and colour preview before Save and persist together at320px',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AgentProfileStore();
      final source = LocalAgentRosterSource(
        seed: [const AgentsAgent(id: 'alex', name: 'Alex', threads: [])],
      );
      addTearDown(store.dispose);
      addTearDown(source.dispose);
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await store.update('alex', colorValue: 0xFF123456);
      await tester.pumpWidget(
        testApp(
          AgentProfileEditPage(
            agent: source.agents.single,
            source: source,
            profiles: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('avatar_shape_oval')));
      await tester.pumpAndSettle();
      expect(store.profileOf('alex').shape, isNull);
      expect(
        tester.widget<AgentFace>(find.byType(AgentFace)).profileOverride!.shape,
        AgentAvatarShape.oval,
      );
      final colour = find.byKey(
        ValueKey('avatar_color_${kAgentAccents.first.toARGB32()}'),
      );
      await tester.ensureVisible(colour);
      await tester.tap(colour);
      await tester.pumpAndSettle();
      // Preview may be outside the lazy list viewport, so scroll back first.
      // The page body and the horizontal shape row are both ListViews; drag
      // the page, which is the first one.
      await tester.drag(find.byType(ListView).first, const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AgentFace>(find.byType(AgentFace))
            .profileOverride!
            .colorValue,
        kAgentAccents.first.toARGB32(),
      );
      expect(store.profileOf('alex').colorValue, 0xFF123456);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(store.profileOf('alex').shape, AgentAvatarShape.oval);
      expect(
        store.profileOf('alex').colorValue,
        kAgentAccents.first.toARGB32(),
      );
      final restored = AgentProfileStore();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.profileOf('alex').shape, AgentAvatarShape.oval);
      expect(tester.takeException(), isNull);
    },
  );

  // The page runs under chuk's floating header. The header band grows by the
  // status bar, so the preview must clear the band at every status-bar
  // height, not only at the zero a test gets by default.
  for (final double statusBar in <double>[0, 24, 48]) {
    testWidgets('the floating header does not cover the preview with a '
        '${statusBar.toInt()} px status bar', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(top: statusBar);
      tester.view.viewPadding = FakeViewPadding(top: statusBar);
      addTearDown(tester.view.reset);
      final store = AgentProfileStore();
      final source = LocalAgentRosterSource(
        seed: [const AgentsAgent(id: 'alex', name: 'Alex', threads: [])],
      );
      addTearDown(store.dispose);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        testApp(
          AgentProfileEditPage(
            agent: source.agents.single,
            source: source,
            profiles: store,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Rect header = tester.getRect(find.byType(AppBar));
      final Rect face = tester.getRect(find.byType(AgentFace).first);
      expect(header.bottom, 62 + statusBar);
      expect(face.top, greaterThanOrEqualTo(header.bottom));
      expect(tester.takeException(), isNull);
    });
  }
}
