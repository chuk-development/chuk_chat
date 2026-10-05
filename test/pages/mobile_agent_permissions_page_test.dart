// The phone's way to a coworker's permissions: the Permissions row on the
// coworker page opens the desktop's sections (switches, approvals, weekly
// budget), each behind the host capability it needs. 360 px at 1.3 text
// scale, as every screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/mobile_agent_permissions_page.dart';
import 'package:chuk_chat/pages/mobile_agents_settings_page.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

import '../agents_permissions/permissions_fakes.dart';
import '../support/test_app.dart';

const Size _phone = Size(360, 780);

Map<String, dynamic> _reply({double budget = 25}) => <String, dynamic>{
  ...permissionsReply('alex', AgentPermissions.defaults),
  'budget_weekly': budget,
  'approvals': <String, dynamic>{
    'classes': <String, String>{
      'publish': 'ask',
      'send_external': 'allow',
      'mcp_destructive': 'ask',
      'browser_act': 'ask',
    },
    'sites': <String, dynamic>{
      'browser_act': <String>['github.com'],
    },
    'defaults': <String, String>{
      'publish': 'ask',
      'send_external': 'ask',
      'mcp_destructive': 'ask',
      'browser_act': 'allow',
    },
    'applies_from': 'next_action',
  },
};

/// A localised app whose every route reads 1.3 text scale.
Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: kTestLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(1.3)),
    child: child!,
  ),
  home: home,
);

Future<void> _phoneView(WidgetTester tester) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Drags the list until [finder] can be hit.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  for (
    var attempts = 0;
    finder.hitTestable().evaluate().isEmpty && attempts < 40;
    attempts++
  ) {
    await tester.drag(
      find.byType(SettingsListView).last,
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
  }
  expect(finder.hitTestable(), findsOneWidget);
}

/// Every text on screen sits inside the 360 px window.
void _expectInsideWindow(WidgetTester tester) {
  for (final Element element in find.byType(Text).evaluate()) {
    final RenderBox? box = element.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final Rect rect = box.localToGlobal(Offset.zero) & box.size;
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '${element.widget}');
    expect(rect.right, lessThanOrEqualTo(_phone.width + 0.5));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  (FakeHost, AgentsPermissionsService) host(Set<String> capabilities) {
    final FakeHost fake = FakeHost();
    fake.capabilities.value = capabilities;
    final AgentsPermissionsService service = fake.service();
    addTearDown(service.dispose);
    return (fake, service);
  }

  testWidgets('the coworker page has a Permissions row that opens the '
      'switches, the approvals and the weekly budget', (tester) async {
    await _phoneView(tester);
    final (FakeHost fake, AgentsPermissionsService service) = host(<String>{
      kAgentPermissionsCapability,
      kActionApprovalsCapability,
      kCostBudgetCapability,
    });
    final LocalAgentRosterSource roster = LocalAgentRosterSource(
      seed: const <AgentsAgent>[
        AgentsAgent(id: 'alex', name: 'Alex', threads: []),
      ],
    );
    final AgentProfileStore profiles = AgentProfileStore();
    final MobileChatPreferences preferences = MobileChatPreferences();
    addTearDown(roster.dispose);
    addTearDown(profiles.dispose);
    addTearDown(preferences.dispose);
    void none() {}
    await tester.pumpWidget(
      _app(
        MobileAgentsSettingsPage(
          agentId: 'alex',
          source: roster,
          profiles: profiles,
          preferences: preferences,
          permissions: service,
          onEdit: none,
          onControls: none,
          onModel: none,
          onAutomations: none,
          onSkills: none,
          onConnectors: none,
          onSecrets: none,
          onRooms: none,
          onSettings: none,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder row = find.byKey(const ValueKey('settings_Permissions'));
    await _reveal(tester, row);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('What it may do, approvals and budget'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.byType(MobileAgentPermissionsPage), findsOneWidget);
    // The page asked the host for this coworker.
    expect(
      fake.sent.where(
        (Map<String, dynamic> f) =>
            f['type'] == 'agent_permissions_get' && f['agent_id'] == 'alex',
      ),
      isNotEmpty,
    );
    service.handleFrame(_reply());
    await tester.pumpAndSettle();

    expect(find.text('PERMISSIONS'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agent-approvals-section')),
      findsOneWidget,
    );
    final Finder budget = find.byKey(
      const ValueKey<String>('budget-weekly-field'),
    );
    await _reveal(tester, budget);
    expect(find.text('25.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    _expectInsideWindow(tester);
  });

  testWidgets('a host without approvals and budgets shows only the switches', (
    tester,
  ) async {
    await _phoneView(tester);
    final (_, AgentsPermissionsService service) = host(<String>{
      kAgentPermissionsCapability,
    });
    await tester.pumpWidget(
      _app(MobileAgentPermissionsPage(agentId: 'alex', service: service)),
    );
    await tester.pump();
    service.handleFrame(_reply());
    await tester.pumpAndSettle();

    expect(find.text('PERMISSIONS'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agent-approvals-section')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('mobile-permissions-budget')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    _expectInsideWindow(tester);
  });

  testWidgets('German: the row and the page title', (tester) async {
    await _phoneView(tester);
    final (_, AgentsPermissionsService service) = host(<String>{
      kAgentPermissionsCapability,
      kCostBudgetCapability,
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MobileAgentPermissionsPage(agentId: 'alex', service: service),
      ),
    );
    await tester.pump();
    service.handleFrame(_reply());
    await tester.pumpAndSettle();
    expect(find.text('Berechtigungen'), findsOneWidget);
    expect(find.text('Wochenbudget'), findsWidgets);
  });
}
