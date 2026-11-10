// "Commands and file changes" (`local_actions`, docs/WIRE_CONTRACT.md,
// "Auto review"): the five modes in the model, and the five choice rows in
// the Approvals section at phone and desktop width.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/widgets/agents_permissions/agent_permissions_section.dart';

import '../support/test_app.dart';
import 'permissions_fakes.dart';

Map<String, dynamic> _reply({String localMode = 'allow'}) => <String, dynamic>{
  ...permissionsReply('a', AgentPermissions.defaults),
  'approvals': <String, dynamic>{
    'classes': <String, String>{
      'send_external': 'ask',
      'local_actions': localMode,
    },
    'defaults': <String, String>{
      'send_external': 'ask',
      'local_actions': 'allow',
    },
    'applies_from': 'next_action',
  },
};

Future<(FakeHost, AgentsPermissionsService)> _open(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final FakeHost host = FakeHost();
  host.capabilities.value = <String>{
    kAgentPermissionsCapability,
    kActionApprovalsCapability,
  };
  final AgentsPermissionsService service = host.service();
  addTearDown(service.dispose);
  await tester.pumpWidget(
    testApp(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AgentPermissionsSection(agentId: 'a', service: service),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (host, service);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('AgentApprovals model', () {
    test('review modes are kept for local_actions and dropped elsewhere', () {
      final AgentApprovals a = AgentApprovals.fromJson(<String, dynamic>{
        'classes': <String, dynamic>{
          'local_actions': 'review_strict',
          'send_external': 'review',
          'browser_act': 'allow',
          'publish': 42,
        },
        'defaults': <String, dynamic>{'local_actions': 'allow'},
      });
      expect(a.modeOf('local_actions'), 'review_strict');
      expect(a.classes.containsKey('send_external'), isFalse);
      expect(a.modeOf('send_external'), 'ask');
      expect(a.classes.containsKey('publish'), isFalse);
      expect(a.modeOf('browser_act'), 'allow');
      expect(a.shownClasses.last, 'local_actions');
    });

    test('valid modes per class', () {
      expect(AgentApprovals.validMode('local_actions', 'review'), isTrue);
      expect(
        AgentApprovals.validMode('local_actions', 'review_strict'),
        isTrue,
      );
      expect(AgentApprovals.validMode('local_actions', 'allow'), isTrue);
      expect(AgentApprovals.validMode('browser_act', 'review'), isFalse);
      expect(AgentApprovals.validMode('publish', 'ask'), isTrue);
      expect(AgentApprovals.modesFor('local_actions'), <String>[
        'allow',
        'ask',
        'review',
        'review_strict',
        'deny',
      ]);
      // The host's default for a host that leaves `defaults` out.
      expect(const AgentApprovals().defaultOf('local_actions'), 'allow');
    });

    test('setApprovalMode refuses review outside local_actions', () async {
      final FakeHost host = FakeHost();
      host.capabilities.value = <String>{
        kAgentPermissionsCapability,
        kActionApprovalsCapability,
      };
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      expect(
        () => service.setApprovalMode('a', 'send_external', 'review'),
        throwsArgumentError,
      );
      expect(
        await service.setApprovalMode('a', 'local_actions', 'review'),
        isTrue,
      );
      expect(host.sent.last['approvals'], <String, dynamic>{
        'classes': <String, String>{'local_actions': 'review'},
      });
    });
  });

  for (final (String name, Size size, double scale) in <(String, Size, double)>[
    ('phone 360 px at 1.3 text', const Size(360, 2400), 1.3),
    ('desktop 1280 px', const Size(1280, 1600), 1),
  ]) {
    testWidgets('$name: five choice rows, picking Review sends it', (
      tester,
    ) async {
      final (FakeHost host, AgentsPermissionsService service) = await _open(
        tester,
        size: size,
        textScale: scale,
      );
      service.handleFrame(_reply());
      await tester.pump();
      expect(find.text('Commands and file changes'), findsOneWidget);
      for (final String mode in AgentApprovals.localActionModes) {
        expect(
          find.byKey(
            ValueKey<String>('agent-approval-choice-local_actions-$mode'),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.text('A small model checks each call; it asks you when in doubt.'),
        findsOneWidget,
      );
      expect(
        find.text('A small model checks each call and refuses what it flags.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      final Finder review = find.byKey(
        const ValueKey<String>('agent-approval-choice-local_actions-review'),
      );
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pump(const Duration(milliseconds: 300));
      expect(host.sent.last['type'], 'agent_permissions_set');
      expect(host.sent.last['approvals'], <String, dynamic>{
        'classes': <String, String>{'local_actions': 'review'},
      });
      expect(service.approvalsOf('a')?.modeOf('local_actions'), 'review');
      final Semantics selected = tester.widget<Semantics>(
        find.descendant(of: review, matching: find.byType(Semantics)).first,
      );
      expect(selected.properties.selected, isTrue);
    });
  }
}
