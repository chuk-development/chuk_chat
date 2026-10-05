import 'dart:async';
import 'dart:convert';

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
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_takeover_card.dart';
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

AgentsRelayApprovalRequest _takeover({
  String id = 'tk-1',
  String? kind = 'login',
  String? site = 'accounts.google.com',
  String? reason,
  String? decision,
  bool replay = false,
  String? sessionKey = 'thread-1',
  String? url,
}) => AgentsRelayApprovalRequest(
  approvalId: id,
  action: AgentsRelayApprovalRequest.takeoverAction,
  path: '',
  name: '',
  fileCount: 0,
  totalBytes: 0,
  baseUrl: '',
  public: false,
  takeoverKind: kind,
  site: site,
  reason: reason,
  decision: decision,
  replay: replay,
  sessionKey: sessionKey,
  url: url,
);

/// The takeover card (research item 6): a login, 2FA code or CAPTCHA in the
/// agent's browser becomes ONE card, "Coworker needs you in the browser",
/// whose button opens the live view; the card resolves when the agent
/// continues.
void main() {
  group('the wire', () {
    test('a browser_takeover approval_request carries kind, site, reason', () {
      final request = AgentsRelayApprovalRequest.fromPayload(<String, dynamic>{
        'type': 'approval_request',
        'approval_id': 'tk-9',
        'action': 'browser_takeover',
        'session_key': 'thread-1',
        'kind': 'two_factor',
        'site': 'github.com',
        'reason': 'GitHub asks for the 2FA code',
        'url': 'https://github.com/sessions/two-factor',
      })!;
      expect(request.isTakeover, isTrue);
      expect(request.takeoverKind, 'two_factor');
      expect(request.site, 'github.com');
      expect(request.reason, 'GitHub asks for the 2FA code');
      expect(request.url, 'https://github.com/sessions/two-factor');
    });

    test('the page URL never reaches the stored transcript line', () {
      // An OAuth callback or a magic link carries a secret in the query.
      const url =
          'https://accounts.google.com/o/oauth2/callback?code=SECRET-CODE#t=1';
      for (final call in [
        approvalCallFromRelay(_takeover(url: url)),
        approvalCallFromRelay(_takeover(url: url, decision: 'approved')),
      ]) {
        final encoded = jsonEncode(call.arguments) + (call.result ?? '');
        expect(encoded.contains('SECRET-CODE'), isFalse);
        expect(encoded.contains('oauth2/callback'), isFalse);
        expect(call.arguments['site'], 'accounts.google.com');
      }
    });

    test('a publish is not a takeover', () {
      final request = AgentsRelayApprovalRequest.fromPayload(<String, dynamic>{
        'approval_id': 'ap-1',
        'action': 'herenow_publish',
      })!;
      expect(request.isTakeover, isFalse);
      expect(request.takeoverKind, isNull);
    });

    test('the transcript line never offers tappable options', () {
      final open = approvalCallFromRelay(_takeover());
      expect(open.name, 'ask_user');
      expect(open.arguments.containsKey('options'), isFalse);
      expect(open.arguments['offered_options'], <String>['Done', 'Skip']);
      expect(
        open.arguments['question'],
        'Needs you in the browser on accounts.google.com',
      );
      final done = approvalCallFromRelay(_takeover(decision: 'approved'));
      expect(open.arguments.containsKey('url'), isFalse);
      expect(
        (jsonDecode(done.result!) as Map<String, dynamic>)['decision'],
        'Done',
      );
    });
  });

  group('the card', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      AgentsRelayApprovalRequest? request,
      AgentsTakeoverStage stage = AgentsTakeoverStage.waiting,
      bool visited = false,
      VoidCallback? onOpen,
      VoidCallback? onDone,
      VoidCallback? onSkip,
      Locale locale = const Locale('en'),
      double width = 400,
    }) async {
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: width,
              child: AgentsTakeoverCard(
                request: request ?? _takeover(),
                coworkerName: 'Ada',
                stage: stage,
                visited: visited,
                onOpenBrowser: onOpen ?? () {},
                onDone: onDone ?? () {},
                onSkip: onSkip ?? () {},
              ),
            ),
          ),
          locale: locale,
        ),
      );
      await tester.pump();
    }

    testWidgets('names the coworker, the step and the site', (tester) async {
      await pumpCard(tester);
      expect(find.text('Ada needs you in the browser'), findsOneWidget);
      expect(
        find.text('Sign in to accounts.google.com, then tap Done.'),
        findsOneWidget,
      );
      expect(find.text('Open browser'), findsOneWidget);
      // Before the view was opened there is one way forward, not two.
      expect(find.text('Done'), findsNothing);
      // Skip is always there: the user can always end the wait.
      expect(
        find.byKey(const ValueKey<String>('agents-takeover-skip')),
        findsOneWidget,
      );
      expect(find.text('Skip'), findsOneWidget);
    });

    testWidgets('Skip answers before and after a visit', (tester) async {
      var skipped = 0;
      await pumpCard(tester, onSkip: () => skipped++);
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-takeover-skip')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(skipped, 1);
      await pumpCard(tester, visited: true, onSkip: () => skipped++);
      await tester.tap(find.text('Skip'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(skipped, 2);
    });

    testWidgets('Skip stays when no transport can open the view', (
      tester,
    ) async {
      var skipped = 0;
      await tester.pumpWidget(
        _app(
          AgentsTakeoverCard(
            request: _takeover(),
            coworkerName: 'Ada',
            stage: AgentsTakeoverStage.waiting,
            visited: false,
            onOpenBrowser: null,
            onDone: () {},
            onSkip: () => skipped++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Skip'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(skipped, 1);
    });

    testWidgets('each kind says its own step', (tester) async {
      await pumpCard(tester, request: _takeover(kind: 'captcha', site: null));
      expect(
        find.text('Solve the check on this site, then tap Done.'),
        findsOneWidget,
      );
      await pumpCard(tester, request: _takeover(kind: 'two_factor'));
      expect(
        find.text(
          'Enter the security code for accounts.google.com, then tap Done.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('German', (tester) async {
      await pumpCard(tester, locale: const Locale('de'), visited: true);
      expect(find.text('Ada braucht dich im Browser'), findsOneWidget);
      expect(find.text('Browser öffnen'), findsOneWidget);
      expect(find.text('Fertig'), findsOneWidget);
      expect(find.text('Überspringen'), findsOneWidget);
    });

    testWidgets('after a visit it offers Done as well', (tester) async {
      var done = 0;
      await pumpCard(tester, visited: true, onDone: () => done++);
      await tester.tap(find.text('Done'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(done, 1);
    });

    testWidgets('the continuing stage says the coworker continues', (
      tester,
    ) async {
      await pumpCard(tester, stage: AgentsTakeoverStage.continuing);
      expect(find.text('Ada continues'), findsOneWidget);
      expect(find.text('Open browser'), findsNothing);
    });

    testWidgets('fits 360 px at 1.3 text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 700),
            textScaler: TextScaler.linear(1.3),
          ),
          child: _app(
            Padding(
              padding: const EdgeInsets.all(12),
              child: AgentsTakeoverCard(
                request: _takeover(
                  reason: 'The bank asks for a one-time code by SMS',
                ),
                coworkerName: 'A coworker with a long name',
                stage: AgentsTakeoverStage.waiting,
                visited: true,
                onOpenBrowser: () {},
                onDone: () {},
                onSkip: () {},
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
      await ChatStorageService.reset();
    });

    tearDown(() async {
      debugAgentsChatCoreOverride = null;
      AgentsRelayLink.instance.reset();
      AgentsRunLedger.instance.reset();
      AgentsReplayLoader.instance.reset();
      await ChatStorageService.reset();
    });

    Future<FakeRelayController> pumpPaired(
      WidgetTester tester, {
      required List<String> opened,
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
            openBrowserView: (context, c, sessionKey) async {
              opened.add(sessionKey);
            },
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

      testWidgets('$layout: open the browser, say done, the card resolves '
          'when the agent continues', (tester) async {
        final opened = <String>[];
        final controller = await pumpPaired(
          tester,
          opened: opened,
          phone: phone,
        );
        final ledger = AgentsRunLedger.instance;
        ledger.begin('thread-1');

        controller.emit(_takeover());
        await tester.pump();
        expect(find.text('Ada needs you in the browser'), findsOneWidget);
        // The status line above the answer waits on the user, not the agent.
        expect(ledger.runFor('thread-1')!.waitingForUser, isTrue);

        await tester.tap(find.text('Open browser'));
        await tester.pump(const Duration(milliseconds: 400));
        // A second frame: the card grows to its new size on a short spring.
        await tester.pump(const Duration(milliseconds: 400));
        expect(opened, <String>['thread-1']);
        expect(find.text('Done'), findsOneWidget);

        await tester.tap(find.text('Done'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.approvalDecisions, <(String, bool)>[('tk-1', true)]);
        expect(find.text('Ada continues'), findsOneWidget);
        expect(ledger.runFor('thread-1')!.waitingForUser, isFalse);

        // The agent's next frame: the card has said enough.
        controller.emit(
          const AgentsRelayTool('browser_snapshot', result: 'ok'),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const ValueKey<String>('agents-takeover-card')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('Skip tells the host no and the card goes', (tester) async {
      final controller = await pumpPaired(tester, opened: <String>[]);
      final ledger = AgentsRunLedger.instance;
      ledger.begin('thread-1');
      controller.emit(_takeover());
      await tester.pump();
      expect(find.text('Ada needs you in the browser'), findsOneWidget);
      expect(ledger.runFor('thread-1')!.waitingForUser, isTrue);

      // No visit needed: Skip is there from the start.
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-takeover-skip')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.approvalDecisions, <(String, bool)>[('tk-1', false)]);
      expect(ledger.runFor('thread-1')!.waitingForUser, isFalse);
      expect(
        find.byKey(const ValueKey<String>('agents-takeover-card')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Skip with no connection keeps the card and says why', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // The view's own controller never arrives; the card still comes in on
      // the app-wide link from another controller.
      final Completer<AgentsRelayController> never =
          Completer<AgentsRelayController>();
      await tester.pumpWidget(
        _app(
          AgentsThreadView(
            controllerBuilder: () => never.future,
            sessionSource: const _FakeSessionSource(),
            threadKey: 'thread-1',
            title: 'Ada',
            fileSaver: _NoopSaver(),
          ),
        ),
      );
      await tester.pump();
      final FakeRelayController upstream = FakeRelayController();
      AgentsRelayLink.instance.bind(upstream);
      final ledger = AgentsRunLedger.instance;
      ledger.begin('thread-1');
      upstream.emit(_takeover());
      await tester.pump();
      expect(find.text('Ada needs you in the browser'), findsOneWidget);
      expect(ledger.runFor('thread-1')!.waitingForUser, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('agents-takeover-skip')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // Nothing could reach the host: the card and the wait both stay.
      expect(upstream.approvalDecisions, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('agents-takeover-card')),
        findsOneWidget,
      );
      expect(ledger.runFor('thread-1')!.waitingForUser, isTrue);
      expect(
        find.text('Not connected to your computer — try again when it is back'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the host resolving it by itself closes the wait', (
      tester,
    ) async {
      final controller = await pumpPaired(tester, opened: <String>[]);
      AgentsRunLedger.instance.begin('thread-1');
      controller.emit(_takeover());
      await tester.pump();
      expect(find.text('Ada needs you in the browser'), findsOneWidget);

      // The host saw the login go through and re-sent the request decided.
      controller.emit(_takeover(decision: 'approved'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Ada continues'), findsOneWidget);
      expect(controller.approvalDecisions, isEmpty);

      // The run ends: nothing is left on screen.
      AgentsRunLedger.instance.finish(
        'thread-1',
        finalAnswer: 'Signed in.',
        reason: 'finished',
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey<String>('agents-takeover-card')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a takeover for another thread is left to that view', (
      tester,
    ) async {
      final controller = await pumpPaired(tester, opened: <String>[]);
      controller.emit(_takeover(sessionKey: 'other-thread'));
      await tester.pump();
      expect(find.text('Ada needs you in the browser'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a replayed takeover whose run is over is history', (
      tester,
    ) async {
      final controller = await pumpPaired(tester, opened: <String>[]);
      controller.emit(_takeover(replay: true));
      await tester.pump();
      expect(find.text('Ada needs you in the browser'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
