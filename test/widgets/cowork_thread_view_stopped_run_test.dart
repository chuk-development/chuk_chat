import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/cowork/agent_file_saver.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_replay_loader.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/settings/verbose_service.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

import '../support/fake_relay_controller.dart';

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(CoworkRelayFile file) async => '/dev/null/${file.name}';
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

/// The visible run must end when the host says the run ended, whatever else the
/// app thinks is going on (bead cowork-gnr8). The thread's working dots read
/// `CoworkRunLedger.isRunning`, so that is what these assert.
void main() {
  const threadKey = 'host:cowork-host';
  final ledger = CoworkRunLedger.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    CoworkRelayLink.instance.reset();
    ledger.reset();
    CoworkReplayLoader.instance.reset();
    await ChatStorageService.reset();
  });

  tearDown(() async {
    CoworkRelayLink.instance.reset();
    ledger.reset();
    CoworkReplayLoader.instance.reset();
    await ChatStorageService.reset();
    await VerboseService.instance.setEnabled(false);
  });

  Future<FakeRelayController> pumpView(
    WidgetTester tester, {
    List<bool>? runStates,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = FakeRelayController();
    await tester.pumpWidget(
      _app(
        CoworkThreadView(
          controllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          threadKey: threadKey,
          fileSaver: _NoopSaver(),
          onRunStateChanged: runStates == null
              ? null
              : (_, running) => runStates.add(running),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// Runs the one-second follow-up of a closed run, then drops the ledger so
  /// its ceiling timer does not outlive the widget tree.
  Future<void> settle(WidgetTester tester) async {
    // The one-second follow-up, then the chat store's notify debounce behind
    // the line it writes.
    await tester.pump(const Duration(seconds: 2));
    ledger.reset();
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('a stop terminal ends the visible run', (tester) async {
    final runStates = <bool>[];
    final controller = await pumpView(tester, runStates: runStates);
    controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
    await tester.pump();

    ledger.begin(threadKey);
    // A token arrived, so the run left a trace in the thread and needs no
    // line of its own — the line itself is pinned in the loader's own tests.
    ledger.touch(threadKey);
    await tester.pump();
    expect(ledger.isRunning(threadKey), isTrue);
    expect(runStates.last, isTrue);

    // The terminal the executor sends after a stop: finished, interrupted, no
    // answer. This is run d1d4ede1.
    controller.emit(
      const CoworkRelayDone(
        sessionKey: threadKey,
        reason: 'interrupted',
        runId: 'd1d4ede1f1e94565b863276fb15b17d3',
      ),
    );
    await tester.pump();

    expect(ledger.isRunning(threadKey), isFalse);
    expect(runStates.last, isFalse);
    expect(ledger.runFor(threadKey)!.outcome, CoworkRunOutcome.stopped);
    await settle(tester);
  });

  testWidgets('an idle run_state on reconnect takes the dots away', (
    tester,
  ) async {
    final grace = CoworkRunLedger.idleHeaderGrace;
    CoworkRunLedger.idleHeaderGrace = Duration.zero;
    addTearDown(() => CoworkRunLedger.idleHeaderGrace = grace);

    final runStates = <bool>[];
    final controller = await pumpView(tester, runStates: runStates);
    controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
    await tester.pump();

    ledger.begin(threadKey);
    ledger.touch(threadKey);
    await tester.pump();
    expect(ledger.isRunning(threadKey), isTrue);

    // The header of the replay the view asks for after a reconnect.
    controller.emit(
      const CoworkRelayRunState(sessionKey: threadKey, state: 'idle'),
    );
    await tester.pumpAndSettle();

    expect(ledger.isRunning(threadKey), isFalse);
    expect(runStates.last, isFalse);
    await settle(tester);
  });
}
