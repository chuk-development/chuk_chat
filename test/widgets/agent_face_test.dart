import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import '../support/test_app.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'shape geometry distinguishes oval, round, square and rounded square',
    () {
      const bounds = Rect.fromLTWH(0, 0, 100, 100);
      final oval = agentAvatarShape(
        'alex',
        AgentAvatarShape.oval,
        100,
      ).getOuterPath(bounds).getBounds();
      expect(oval.width, closeTo(78, 0.01));
      expect(oval.height, 100);
      expect(
        agentAvatarShape('alex', AgentAvatarShape.round, 100),
        isA<CircleBorder>(),
      );
      final square =
          agentAvatarShape('alex', AgentAvatarShape.square, 100)
              as RoundedRectangleBorder;
      final rounded =
          agentAvatarShape('alex', AgentAvatarShape.roundedSquare, 100)
              as RoundedRectangleBorder;
      expect(square.borderRadius, BorderRadius.zero);
      expect(rounded.borderRadius, BorderRadius.circular(24));
    },
  );

  testWidgets(
    'all avatar sizes and identity faces react to saved shapes including photos',
    (tester) async {
      final store = AgentProfileStore();
      addTearDown(store.dispose);
      const agent = CoworkAgent(id: 'alex', name: 'Alex', threads: []);
      await store.update(
        'alex',
        shape: AgentAvatarShape.square,
        colorValue: 0xFF00BFA5,
      );
      await tester.pumpWidget(
        testApp(
          Column(
            children: [
              for (final size in [38.0, 56.0, 96.0])
                AgentFace(agent: agent, size: size, store: store),
              ExpressiveFace(id: 'alex', label: 'Alex', store: store),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      List<ShapeDecoration> surfaces() => tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<ShapeDecoration>()
          .toList();
      expect(surfaces(), hasLength(4));
      expect(
        surfaces().every(
          (d) =>
              d.shape is RoundedRectangleBorder &&
              d.color == const Color(0xFF00BFA5),
        ),
        isTrue,
      );
      await store.update(
        'alex',
        shape: AgentAvatarShape.round,
        photoPath: File('assets/icons/app_icon.png').absolute.path,
      );
      await tester.pump();
      expect(
        surfaces().every(
          (d) => d.shape is CircleBorder && d.image?.image is FileImage,
        ),
        isTrue,
      );
    },
  );
}
