import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_approval_grants.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/widgets/agents_approval_row.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

import '../agents_permissions/permissions_fakes.dart';

/// bead chuk_chat-aupy: an answered approval stays in the thread as one
/// small row, and Undo takes a lasting answer back out of the host's policy.
void main() {
  const String thread = 'amber-otter-2';
  const String agent = 'agent-7';

  late FakeHost host;
  late AgentsPermissionsService service;
  late AgentsApprovalGrants grants;
  late String prefsKey;
  int testIndex = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    host = FakeHost();
    host.capabilities.value = const <String>{
      kAgentPermissionsCapability,
      kActionApprovalsCapability,
    };
    service = host.service();
    // One preferences key per test: the plugin keeps its cache across
    // tests, so a revoke from one test would leak into the next.
    prefsKey = 'agents_revoked_approvals_test_${++testIndex}';
    grants = AgentsApprovalGrants(
      permissions: service,
      prefsKey: prefsKey,
      replyTimeout: const Duration(milliseconds: 50),
    )..registerThread(thread, agent);
  });

  /// The transcript line of a decided approval, as the live ledger and the
  /// replay loader build it.
  ToolCall decided({
    String id = 'ap-1',
    String scope = AgentsRelayApprovalRequest.scopeAlwaysAgent,
    String actionClass = AgentApprovals.classMcpDestructive,
    String? site,
    bool approved = true,
  }) {
    final AgentsRelayApprovalRequest request = AgentsRelayApprovalRequest(
      approvalId: id,
      action: AgentsRelayApprovalRequest.actionApprovalAction,
      path: '',
      name: '',
      fileCount: 0,
      totalBytes: 0,
      baseUrl: '',
      public: false,
      actionClass: actionClass,
      options: const <String>['once', 'always_this_agent', 'deny'],
      summary: 'Use Fastmail to send a mail?',
      site: site,
      decision: approved ? 'approved' : 'denied',
      decisionReason: 'user',
      decisionScope: scope,
    );
    return actionApprovalCallFromRelay(request);
  }

  Widget app(Widget child, {double width = 400, double textScale = 1}) =>
      MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: MaterialApp(
          localizationsDelegates: const <LocalizationsDelegate<Object>>[
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      );

  group('AgentsApprovalGrant.fromArguments', () {
    test('reads a lasting connector approval', () {
      final AgentsApprovalGrant? grant = AgentsApprovalGrant.fromArguments(
        decided().arguments,
      );
      expect(grant, isNotNull);
      expect(grant!.approved, isTrue);
      expect(grant.isLasting, isTrue);
      expect(grant.what, 'Use Fastmail to send a mail');
      expect(grant.actionClass, AgentApprovals.classMcpDestructive);
    });

    test('a once answer is approved but not lasting', () {
      final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
        decided(scope: AgentsRelayApprovalRequest.scopeOnce).arguments,
      )!;
      expect(grant.approved, isTrue);
      expect(grant.isLasting, isFalse);
    });

    test('an open card, a takeover and a model question are no rows', () {
      expect(
        AgentsApprovalGrant.fromArguments(<String, dynamic>{
          'question': 'Which one?',
          'options': <String>['A', 'B'],
        }),
        isNull,
      );
      expect(
        AgentsApprovalGrant.fromArguments(<String, dynamic>{
          'approvalId': 'x',
          'decision': 'Done',
          'action': AgentsRelayApprovalRequest.takeoverAction,
        }),
        isNull,
      );
      expect(
        AgentsApprovalGrant.fromArguments(<String, dynamic>{
          'approvalId': 'x',
          'decision': 'Expired',
        }),
        isNull,
      );
    });
  });

  testWidgets('the row: check, "Approved: what", Undo; Undo revokes', (
    tester,
  ) async {
    final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
      decided().arguments,
    )!;
    await tester.pumpWidget(
      app(AgentsApprovalRow(grant: grant, threadKey: thread, grants: grants)),
    );
    await tester.pump();

    expect(
      find.textContaining('Approved: Use Fastmail to send a mail'),
      findsOneWidget,
    );
    final Finder undo = find.byKey(
      const ValueKey<String>('agents-approval-row-undo'),
    );
    expect(undo, findsOneWidget);

    // The check is an icon, centred on the text line.
    final Rect icon = tester.getRect(
      find.byKey(const ValueKey<String>('agents-approval-row-icon')),
    );
    final Rect text = tester.getRect(
      find.byKey(const ValueKey<String>('agents-approval-row-text')),
    );
    expect((icon.center.dy - text.center.dy).abs(), lessThan(1.0));

    await tester.tap(undo);
    await tester.pump();
    await tester.pump();

    // The class goes back to asking, on the agent of this thread.
    expect(host.sent, hasLength(1));
    expect(host.sent.single['type'], 'agent_permissions_set');
    expect(host.sent.single['agent_id'], agent);
    expect(host.sent.single['approvals'], <String, dynamic>{
      'classes': <String, String>{AgentApprovals.classMcpDestructive: 'ask'},
    });
    expect(
      find.textContaining('Revoked: Use Fastmail to send a mail'),
      findsOneWidget,
    );
    expect(undo, findsNothing);
  });

  testWidgets('a revoke survives a reload', (tester) async {
    final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
      decided().arguments,
    )!;
    await tester.runAsync(() async {
      expect(await grants.revoke(grant, threadKey: thread), isTrue);
    });

    // A fresh process: a new store reading the same preferences.
    final AgentsApprovalGrants reloaded = AgentsApprovalGrants(
      permissions: service,
      prefsKey: prefsKey,
    );
    await tester.pumpWidget(
      app(AgentsApprovalRow(grant: grant, threadKey: thread, grants: reloaded)),
    );
    await tester.runAsync(reloaded.load);
    await tester.pump();
    expect(find.textContaining('Revoked:'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agents-approval-row-undo')),
      findsNothing,
    );
  });

  test('a site answer takes only that site off the list', () async {
    service.handleFrame(<String, dynamic>{
      'type': 'agent_permissions',
      'agent_id': agent,
      'permissions': AgentPermissions.defaults.toJson(),
      'approvals': <String, dynamic>{
        'classes': <String, String>{'browser_act': 'ask'},
        'sites': <String, List<String>>{
          'browser_act': <String>['github.com', 'x.com'],
        },
      },
    });
    final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
      decided(
        scope: AgentsRelayApprovalRequest.scopeAlwaysSite,
        actionClass: AgentApprovals.classBrowserAct,
        site: 'x.com',
      ).arguments,
    )!;
    expect(grant.isLasting, isTrue);
    expect(await grants.revoke(grant, threadKey: thread), isTrue);
    expect(host.sent.single['approvals'], <String, dynamic>{
      'sites': <String, List<String>>{
        'browser_act': <String>['github.com'],
      },
    });
  });

  test('a site answer never sends a guessed list', () async {
    // The policy was never read and the host does not answer in time: the
    // other sites must not be wiped by a list built from nothing.
    final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
      decided(
        scope: AgentsRelayApprovalRequest.scopeAlwaysSite,
        actionClass: AgentApprovals.classBrowserAct,
        site: 'x.com',
      ).arguments,
    )!;
    expect(await grants.revoke(grant, threadKey: thread), isFalse);
    expect(host.sent.single['type'], 'agent_permissions_get');
    expect(grants.isRevoked(grant.approvalId), isFalse);
  });

  testWidgets('no host to ask: the row keeps its Undo', (tester) async {
    host.fail = true;
    final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
      decided().arguments,
    )!;
    await tester.pumpWidget(
      app(AgentsApprovalRow(grant: grant, threadKey: thread, grants: grants)),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('agents-approval-row-undo')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Approved:'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agents-approval-row-undo')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a once answer shows the row without Undo', (tester) async {
    final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
      decided(scope: AgentsRelayApprovalRequest.scopeOnce).arguments,
    )!;
    await tester.pumpWidget(
      app(AgentsApprovalRow(grant: grant, threadKey: thread, grants: grants)),
    );
    await tester.pump();
    expect(find.textContaining('Approved:'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agents-approval-row-undo')),
      findsNothing,
    );
  });

  testWidgets('the row fits 360 px at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final AgentsApprovalGrant grant = AgentsApprovalGrant.fromArguments(
      decided().arguments,
    )!;
    await tester.pumpWidget(
      app(
        AgentsApprovalRow(grant: grant, threadKey: thread, grants: grants),
        width: 344,
        textScale: 1.3,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('in the transcript', () {
    setUp(() {
      debugAgentsChatCoreOverride = true;
      ChatOrigin.claimAgentsThread(thread);
    });
    tearDown(ChatOrigin.reset);

    testWidgets('a settled turn keeps the row with Activity off', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          MessageBubble(
            message: '',
            isUser: false,
            chatId: thread,
            messengerMode: true,
            showToolCalls: false,
            contentBlocks: <ContentBlock>[
              ContentBlock.toolCalls(<ToolCall>[decided()]),
              const ContentBlock.text('Mail sent.'),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AgentsApprovalRow), findsOneWidget);
      expect(find.textContaining('Approved: Use Fastmail'), findsOneWidget);
      expect(find.text('Mail sent.'), findsOneWidget);
    });

    testWidgets('a plain chuk chat draws no approval row', (tester) async {
      await tester.pumpWidget(
        app(
          MessageBubble(
            message: '',
            isUser: false,
            chatId: '7d4f2c1a-3b5e-4c6d-8e9f-0a1b2c3d4e5f',
            showToolCalls: false,
            contentBlocks: <ContentBlock>[
              ContentBlock.toolCalls(<ToolCall>[decided()]),
              const ContentBlock.text('Mail sent.'),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AgentsApprovalRow), findsNothing);
    });
  });
}
