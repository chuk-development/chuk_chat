import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_thread_composer.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_action_approval_card.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';

import '../support/fake_relay_controller.dart';

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
}

class _FakeSessionSource implements AccountSessionSource {
  const _FakeSessionSource();

  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    userId: 'user-1',
  );

  @override
  Future<AccountSession?> refresh() async => current();
}

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

const List<String> _allOptions = <String>[
  'once',
  'always_this_agent',
  'always_this_site',
  'deny',
];

AgentsRelayApprovalRequest _request({
  String id = 'ap-1',
  String actionClass = 'browser_act',
  List<String> options = _allOptions,
  String? summary = 'Click "Buy now" on shop.example',
  String? site = 'shop.example',
  Map<String, dynamic>? details = const <String, dynamic>{
    'browser_tool': 'browser_click',
    'element': 'Buy now',
  },
}) => AgentsRelayApprovalRequest(
  approvalId: id,
  action: 'action_approval',
  path: '',
  name: '',
  fileCount: 0,
  totalBytes: 0,
  baseUrl: '',
  public: false,
  sessionKey: 'thread-1',
  actionClass: actionClass,
  options: options,
  summary: summary,
  site: site,
  details: details,
);

void main() {
  group('the card', () {
    Future<void> pumpCard(
      WidgetTester tester,
      AgentsRelayApprovalRequest request, {
      ValueChanged<String>? onSelect,
      String? decision,
      Locale locale = const Locale('en'),
    }) async {
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: AgentsActionApprovalCard(
              request: request,
              coworkerName: 'Ada',
              decision: decision,
              onSelect: onSelect ?? (_) {},
            ),
          ),
          locale: locale,
        ),
      );
      await tester.pump();
    }

    testWidgets('one button per option, in order, with the contract words', (
      tester,
    ) async {
      final picked = <String>[];
      await pumpCard(tester, _request(), onSelect: picked.add);
      expect(find.text('Click "Buy now" on shop.example'), findsOneWidget);
      final labels = <String>[
        'Allow once',
        'Always for Ada',
        'Always on shop.example',
        'Deny',
      ];
      double lastX = -1;
      double lastY = -1;
      for (final String label in labels) {
        final Offset at = tester.getTopLeft(find.text(label));
        // Reading order: left to right, then the next row.
        expect(at.dy > lastY || (at.dy == lastY && at.dx > lastX), isTrue);
        lastX = at.dx;
        lastY = at.dy;
      }
      // The browser target is named; a submit would say so.
      expect(find.textContaining('Buy now'), findsWidgets);
      await tester.tap(find.text('Always on shop.example'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(picked, <String>['always_this_site']);
    });

    testWidgets('a connector card says what "always" covers and shows the '
        'arguments in a monospace block', (tester) async {
      await pumpCard(
        tester,
        _request(
          actionClass: 'mcp_destructive',
          options: const <String>['once', 'always_this_agent', 'deny'],
          summary: 'Delete an issue in Linear',
          site: null,
          details: const <String, dynamic>{
            'server': 'Linear',
            'remote_tool': 'delete_issue',
            'arguments': '{"id":"LIN-42"}',
          },
        ),
      );
      expect(
        find.text('Always allow connector actions for Ada'),
        findsOneWidget,
      );
      expect(find.text('Always on shop.example'), findsNothing);
      final Text args = tester.widget<Text>(
        find.byKey(const ValueKey<String>('agents-approval-args')),
      );
      expect(args.data, contains('"id": "LIN-42"'));
      expect(args.style?.fontFamily, 'monospace');
    });

    testWidgets('a mail card names the recipients and the subject', (
      tester,
    ) async {
      await pumpCard(
        tester,
        _request(
          actionClass: 'send_external',
          options: const <String>['once', 'always_this_agent', 'deny'],
          summary: 'Send a mail to bob@example.com',
          site: null,
          details: const <String, dynamic>{
            'to': <String>['bob@example.com'],
            'subject': 'Invoice',
            'preview': 'Hi Bob, here is the invoice.',
          },
        ),
      );
      expect(find.textContaining('bob@example.com'), findsWidgets);
      expect(find.textContaining('Invoice'), findsOneWidget);
      expect(find.text('Hi Bob, here is the invoice.'), findsOneWidget);
    });

    testWidgets('decided: the buttons go and the card says what it covered', (
      tester,
    ) async {
      await pumpCard(tester, _request(), decision: 'always_this_agent');
      expect(find.text('Allow once'), findsNothing);
      expect(find.text('Allowed always for Ada'), findsOneWidget);
    });

    testWidgets('German', (tester) async {
      await pumpCard(tester, _request(), locale: const Locale('de'));
      expect(find.text('Einmal erlauben'), findsOneWidget);
      expect(find.text('Immer für Ada'), findsOneWidget);
      expect(find.text('Immer auf shop.example'), findsOneWidget);
      expect(find.text('Ablehnen'), findsOneWidget);
    });

    testWidgets('fits 360 px at 1.3 text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(1.3),
          ),
          child: _app(
            Padding(
              padding: const EdgeInsets.all(12),
              child: AgentsActionApprovalCard(
                request: _request(
                  site: 'a-very-long-subdomain.shop.example.com',
                ),
                coworkerName: 'A coworker with a long name',
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('in the thread', () {
    setUp(() async {
      debugAgentsChatCoreOverride = true;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await VerboseService.instance.setEnabled(false);
      AgentsRelayLink.instance.reset();
      AgentsRunLedger.instance.reset();
      AgentsReplayLoader.instance.reset();
      AgentsBudgetNotices.instance.reset();
      AgentsBudgetOverride.reset();
      await ChatStorageService.reset();
    });

    tearDown(() async {
      debugAgentsChatCoreOverride = null;
      AgentsRelayLink.instance.reset();
      AgentsRunLedger.instance.reset();
      AgentsReplayLoader.instance.reset();
      AgentsBudgetNotices.instance.reset();
      AgentsBudgetOverride.reset();
      await ChatStorageService.reset();
    });

    Future<FakeRelayController> pumpPaired(
      WidgetTester tester, {
      bool phone = false,
    }) async {
      final Size size = phone ? const Size(390, 844) : const Size(1400, 900);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FakeRelayController();
      await tester.pumpWidget(
        _app(
          AgentsThreadView(
            controllerBuilder: () async => controller,
            sessionSource: const _FakeSessionSource(),
            threadKey: 'thread-1',
            title: 'Ada',
            phoneLayout: phone,
            fileSaver: _NoopSaver(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.set(
        const AgentsRelayState(
          phase: AgentsRelayPhase.paired,
          peerDeviceId: 'cowork-host',
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    for (final bool phone in <bool>[false, true]) {
      final String layout = phone ? 'phone' : 'desktop';

      testWidgets('$layout: the card sits in the transcript; an answer sends '
          'its scope and the card goes when the agent moves on', (
        tester,
      ) async {
        final controller = await pumpPaired(tester, phone: phone);
        final ledger = AgentsRunLedger.instance;
        ledger.begin('thread-1');
        controller.emit(_request());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final Finder card = find.byKey(
          const ValueKey<String>('agents-approval-card'),
        );
        expect(card, findsOneWidget);
        expect(
          find.ancestor(of: card, matching: find.byType(CustomScrollView)),
          findsOneWidget,
        );
        expect(ledger.runFor('thread-1')!.waitingForUser, isTrue);

        await tester.tap(find.text('Always on shop.example'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.approvalDecisions, <(String, bool)>[('ap-1', true)]);
        expect(controller.approvalScopes, <String?>['always_this_site']);
        expect(find.text('Allowed always on shop.example'), findsOneWidget);
        expect(ledger.runFor('thread-1')!.waitingForUser, isFalse);

        controller.emit(const AgentsRelayTool('browser_click', result: 'ok'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(card, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(minutes: 2));
      });
    }

    testWidgets('Deny says no with scope deny', (tester) async {
      final controller = await pumpPaired(tester);
      AgentsRunLedger.instance.begin('thread-1');
      controller.emit(_request(id: 'ap-2'));
      await tester.pump();
      await tester.tap(find.text('Deny'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.approvalDecisions, <(String, bool)>[('ap-2', false)]);
      expect(controller.approvalScopes, <String?>['deny']);
      expect(find.text('Denied'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    });

    testWidgets('an old publish keeps its bar and sends no scope', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);
      AgentsRunLedger.instance.begin('thread-1');
      controller.emit(
        const AgentsRelayApprovalRequest(
          approvalId: 'ap-3',
          action: 'herenow_publish',
          path: 'site',
          name: 'site',
          fileCount: 1,
          totalBytes: 10,
          baseUrl: 'here.now',
          public: true,
          sessionKey: 'thread-1',
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('agents-approval-card')),
        findsNothing,
      );
      expect(find.text('Publish to the web?'), findsOneWidget);
      await tester.tap(find.textContaining('Publish').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.approvalScopes, <String?>[null]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    });

    testWidgets('a budget refusal of the user\'s task is a notice with Run '
        'anyway, which sends the same prompt over the budget', (tester) async {
      final controller = await pumpPaired(tester);
      final sent = <(String, String)>[];
      bool fake(String chatId, String text) {
        sent.add((chatId, text));
        return true;
      }

      AgentsThreadComposer.attach(fake);
      addTearDown(() => AgentsThreadComposer.detach(fake));
      final ledger = AgentsRunLedger.instance;
      ledger.begin('thread-1');
      ledger.taskSent('thread-1', 'task-1');
      ChatRuntimeRegistry.instance.get('thread-1').setMessages(
        <Map<String, String>>[
          <String, String>{'sender': 'user', 'text': 'Summarise my inbox'},
        ],
      );
      controller.emit(
        const AgentsRelayDone(
          reason: 'budget_exceeded',
          finalAnswer: 'This coworker reached its weekly budget.',
          sessionKey: 'thread-1',
          iterations: 0,
          tokensSpent: 0,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey<String>('agents-budget-refusal')),
        findsOneWidget,
      );
      expect(find.text('Weekly budget reached'), findsOneWidget);

      await tester.tap(find.text('Run anyway'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(sent, <(String, String)>[('thread-1', 'Summarise my inbox')]);
      expect(AgentsBudgetOverride.isArmed('thread-1'), isTrue);
      expect(
        find.byKey(const ValueKey<String>('agents-budget-refusal')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    });

    testWidgets('a refused schedule offers no Run anyway; Change budget opens '
        'the budget field', (tester) async {
      final controller = await pumpPaired(tester);
      controller.emit(
        const AgentsRelayDone(
          reason: 'budget_exceeded',
          finalAnswer: 'This run was skipped.',
          sessionKey: 'thread-1',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Run anyway'), findsNothing);
      await tester.tap(find.text('Change budget'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('agents-budget-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('budget-weekly-field')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    });

    testWidgets('a budget warning shows once in its thread and can be closed', (
      tester,
    ) async {
      await pumpPaired(tester);
      final warning = AgentsBudgetWarning.fromPayload(<String, dynamic>{
        'agent_id': 'host:pc',
        'session_key': 'thread-1',
        'level': 'warning',
        'spent_eur': 4.02,
        'budget_eur': 5.0,
        'week_starts_at': 1759701600.0,
      })!;
      AgentsBudgetNotices.instance.add(warning);
      await tester.pump();
      expect(
        find.text('Weekly budget: 80 % used (€4.02 of €5.00)'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-budget-warning-dismiss')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey<String>('agents-budget-warning')),
        findsNothing,
      );
      // The same frame again is the same notice: it does not come back.
      expect(AgentsBudgetNotices.instance.add(warning), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    });
  });
}
