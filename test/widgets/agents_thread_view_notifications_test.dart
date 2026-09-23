// WS-7, app side: the thread view feeds the notification layer.
//
//  * a LIVE done while the app is in the background → one local toast;
//  * a live done in the foreground → nothing (the user is watching);
//  * a REPLAYED done with `while_away` → the host's row is consumed and the
//    OS toast for the thread is cleared.
//
// The plugin and Supabase are faked through the services' seams; nothing
// here touches a platform channel.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/notifications/local_notifications.dart';
import 'package:chuk_chat/services/notifications/run_notifications.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

import '../services/notifications/local_notifications_test.dart' show FakeBackend;
import '../support/fake_relay_controller.dart';

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

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
}

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  // The Agents chat core (host-run tools, relay transport), selected for this
  // flag-off test process.
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
  late FakeBackend backend;
  late List<String?> consumedSessions;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();

    AgentsNotifications.instance.reset();
    LocalNotifications.instance.reset();
    backend = FakeBackend();
    consumedSessions = <String?>[];
    RunNotifications.instance.configure(
      userId: () => 'user-1',
      writer: ({
        required String userId,
        String? sessionKey,
        String? runId,
        required String consumedAt,
      }) async =>
          consumedSessions.add(sessionKey),
    );
    await AgentsNotifications.instance.initialize(
      localBackend: backend,
      startPush: false,
    );
    AgentsNotifications.instance.threadLabel = (String key) => 'Chief of Staff';
  });

  tearDown(() async {
    RunNotifications.instance.configure();
    AgentsNotifications.instance.reset();
    LocalNotifications.instance.reset();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
    await VerboseService.instance.setEnabled(false);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<FakeRelayController> pumpPaired(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
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

  testWidgets('a live done while backgrounded shows one generic toast',
      (tester) async {
    final controller = await pumpPaired(tester);
    AgentsNotifications.instance.lifecycleOverride = AppLifecycleState.paused;

    controller.emit(const AgentsRelayDone(reason: 'finished', runId: 'run-1'));
    await tester.pumpAndSettle();

    expect(backend.shown, hasLength(1));
    expect(backend.shown.single['title'], 'Chief of Staff');
    expect(backend.shown.single['body'], 'Your answer is ready.');
    expect(backend.shown.single['tag'], 'thread-1');
    expect(controller.ackedRunIds, <String>['run-1'], reason: 'ack still sent');
  });

  testWidgets('a live done in the foreground shows nothing', (tester) async {
    final controller = await pumpPaired(tester);
    AgentsNotifications.instance.lifecycleOverride = AppLifecycleState.resumed;

    controller.emit(const AgentsRelayDone(reason: 'finished', runId: 'run-2'));
    await tester.pumpAndSettle();

    expect(backend.shown, isEmpty);
  });

  testWidgets(
      'a replayed while_away done consumes the row and clears the toast',
      (tester) async {
    final controller = await pumpPaired(tester);
    AgentsNotifications.instance.lifecycleOverride = AppLifecycleState.paused;

    controller.emit(const AgentsRelayDone(
      reason: 'finished',
      replay: true,
      whileAway: true,
      runId: 'run-old',
    ));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    await tester.pumpAndSettle();

    expect(backend.shown, isEmpty, reason: 'a replay is never toasted');
    expect(consumedSessions, <String?>['thread-1']);
    expect(backend.cancelled.map((c) => c.$2), contains('thread-1'));
    final cancelledBefore = backend.cancelled.length;

    // Acted on once (review F8): a later loader change — here the host's
    // run_state — must not consume or cancel again, or a fresh toast for the
    // NEXT run would be cancelled on sight.
    controller.emit(
      const AgentsRelayRunState(sessionKey: 'thread-1', state: 'idle'),
    );
    await tester.pumpAndSettle();
    expect(consumedSessions, <String?>['thread-1']);
    expect(backend.cancelled, hasLength(cancelledBefore));
  });
}
