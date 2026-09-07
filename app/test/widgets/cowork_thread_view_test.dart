import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/platform_specific/chat/chat_ui_desktop.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/cowork/agent_file_saver.dart';
import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_replay_loader.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/multiplex_session.dart';
import 'package:cowork/services/app_theme_service.dart';
import 'package:cowork/services/settings/verbose_service.dart';
import 'package:cowork/widgets/ask_user_card.dart';
import 'package:cowork/widgets/message_bubble.dart' show MessageBubble;
import 'package:cowork/widgets/cowork_thread_view.dart';

import '../support/fake_relay_controller.dart';

/// In-memory secure backend so the store round-trips with no platform channel.
class _MemoryStore implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// A saver that never touches a filesystem.
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

/// The app shell the imported chat screen expects around it: localisations and
/// a desktop-sized window.
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
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
    CoworkReplayLoader.instance.reset();
    await ChatStorageService.reset();
  });

  tearDown(() async {
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
    CoworkReplayLoader.instance.reset();
    await ChatStorageService.reset();
    await VerboseService.instance.setEnabled(false);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<FakeRelayController> pumpView(
    WidgetTester tester, {
    String threadKey = 'default',
    Size size = const Size(1400, 900),
    List<bool>? runStates,
    VoidCallback? onOpenModelScreen,
  }) async {
    tester.view.physicalSize = size;
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
          onOpenModelScreen: onOpenModelScreen,
          onRunStateChanged: runStates == null
              ? null
              : (threadKey, running) => runStates.add(running),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  // ==========================================================================
  // Pairing / connect / reconnect — the transport half.
  // ==========================================================================

  testWidgets('chat mounts before controller initialization finishes', (
    tester,
  ) async {
    final ready = Completer<CoworkRelayController>();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        CoworkThreadView(
          controllerBuilder: () => ready.future,
          sessionSource: const _FakeSessionSource(),
        ),
      ),
    );
    // Two pumps, not one: the chat area waits for the local chat cache to be
    // read once before it mounts the screen, or the screen would look its
    // thread up, miss, and drop the history for good (bead cowork-8yb). What
    // the test is about is unchanged — that is still well before the
    // controller is ready.
    await tester.pump();
    await tester.pump();
    expect(find.byType(ChukChatUIDesktop), findsOneWidget);
    final chatState = tester.state(find.byType(ChukChatUIDesktop));
    ready.complete(FakeRelayController());
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ChukChatUIDesktop)), same(chatState));
  });

  testWidgets('shows the connect affordance when disconnected', (tester) async {
    await pumpView(tester);

    // A compact connect bar, not a dominating form: default host prefilled,
    // a pairing-code field, and a Connect button.
    expect(find.text('ws://127.0.0.1:8787'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.text('Connect to a host to start chatting.'), findsOneWidget);
    // Local history remains readable before a host is available.
    expect(find.byType(ChukChatUIDesktop), findsOneWidget);
  });

  testWidgets('connecting shows nothing but the header dot', (tester) async {
    final controller = await pumpView(tester);
    controller.set(
      const CoworkRelayState(
        phase: CoworkRelayPhase.connecting,
        detail: 'Connecting…',
      ),
    );
    await tester.pump();

    // The app always reconnects on its own, so a connect in flight is not news:
    // no progress bar, no status line. The whole state is the dot in the
    // header (bead cowork-y6q).
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Connecting…'), findsNothing);
  });

  testWidgets('error phase surfaces the failure detail on the connect bar', (
    tester,
  ) async {
    final controller = await pumpView(tester);
    controller.set(
      const CoworkRelayState(
        phase: CoworkRelayPhase.error,
        detail: 'Pairing failed (macMismatch)',
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.text('Pairing failed (macMismatch)'), findsOneWidget);
  });

  testWidgets('tapping Connect runs connect, provisions, and shows the chat', (
    tester,
  ) async {
    final controller = await pumpView(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'chan1234-428913',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(controller.connectCalls, 1);
    expect(controller.provisioned, isTrue);
    expect(find.byType(ChukChatUIDesktop), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
    // Nothing sits on top of the chat.
    expect(find.textContaining('Connected to'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a paired transport reports the host device id once', (
    tester,
  ) async {
    final peers = <String>[];
    final controller = FakeRelayController();
    await tester.pumpWidget(
      _app(
        CoworkThreadView(
          controllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          fileSaver: _NoopSaver(),
          onPaired: peers.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.set(
      const CoworkRelayState(
        phase: CoworkRelayPhase.paired,
        peerDeviceId: 'cowork-host',
      ),
    );
    await tester.pumpAndSettle();

    expect(peers, <String>['cowork-host']);
  });

  group('persistent pairing', () {
    Future<CoworkPairingStore> seededStore() async {
      final store = CoworkPairingStore(backend: _MemoryStore());
      final hostPub = await (await CoworkDeviceKeys.generate())
          .extractPublicKey();
      await store.savePairing(
        CoworkStoredPairing(
          hostUrl: Uri.parse('ws://10.0.0.9:8787'),
          channelId: 'cowork00deadbeef',
          channelKey: Uint8List(32),
          peerDeviceId: 'cowork-host',
          peerPublicKey: hostPub,
        ),
      );
      return store;
    }

    /// [hostAway] makes every reconnect fail, so the view keeps trying and
    /// keeps missing — the only way the reconnect bar is supposed to come back.
    Future<(List<FakeRelayController>, CoworkPairingStore)> pumpPersistent(
      WidgetTester tester, {
      bool hostAway = false,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = await seededStore();
      final controllers = <FakeRelayController>[];
      await tester.pumpWidget(
        _app(
          CoworkThreadView(
            controllerBuilder: () async {
              final c = FakeRelayController()..reconnectFails = hostAway;
              controllers.add(c);
              return c;
            },
            sessionSource: const _FakeSessionSource(),
            pairingStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (controllers, store);
    }

    /// Lets the view's own reconnect loop run against a host that is not
    /// answering, long enough for it to give up and put the way out back on
    /// screen. The bar counts failures, not drops: one drop is a hiccup the
    /// app fixes by itself.
    Future<void> letTheReconnectsFail(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 10));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a stored pairing auto-reconnects with no code form', (
      tester,
    ) async {
      final (controllers, _) = await pumpPersistent(tester);

      // No code form; it reconnected on its own and provisioned the account.
      expect(controllers.single.reconnectCalls, 1);
      expect(controllers.single.provisioned, isTrue);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
      expect(find.widgetWithText(TextField, 'Host'), findsNothing);
      expect(find.byType(ChukChatUIDesktop), findsOneWidget);
      // Nothing on top: the connection is not the user's business.
      expect(find.textContaining('Connected to'), findsNothing);
    });

    testWidgets(
      'one dropped connection says nothing and comes back by itself',
      (tester) async {
        final (controllers, _) = await pumpPersistent(tester);

        // The socket drops on its own — no user action, and no button to press.
        final chatState = tester.state(find.byType(ChukChatUIDesktop));
        controllers.single.set(
          const CoworkRelayState(
            phase: CoworkRelayPhase.closed,
            detail: 'Host closed the connection',
          ),
        );
        await tester.pump();

        // Nothing appears. A bar that shows up for a second on every hiccup
        // reads as breakage in an app that is already fixing itself
        // (bead cowork-y6q); the header dot carries the state.
        expect(find.widgetWithText(FilledButton, 'Reconnect'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Forget'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
        expect(find.widgetWithText(TextField, 'Pairing code'), findsNothing);
        expect(tester.state(find.byType(ChukChatUIDesktop)), same(chatState));

        // And it comes back by itself after the backoff — a fresh controller
        // reconnects with no code and no tap.
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(controllers.length, greaterThan(1));
        expect(controllers.last.reconnectCalls, 1);
        expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
        expect(tester.state(find.byType(ChukChatUIDesktop)), same(chatState));
      },
    );

    testWidgets(
      'a host that stays away brings the reconnect bar back, never a code form',
      (tester) async {
        final (_, _) = await pumpPersistent(tester, hostAway: true);
        final chatState = tester.state(find.byType(ChukChatUIDesktop));

        // Nothing while it is still trying.
        expect(find.widgetWithText(FilledButton, 'Reconnect'), findsNothing);

        // It keeps missing: this is no longer a hiccup, so the user gets the
        // way out again.
        await letTheReconnectsFail(tester);

        // Still paired (stored), so the code form stays gone; the bottom bar
        // offers Reconnect and, for the it-is-really-broken case, Forget.
        expect(find.widgetWithText(FilledButton, 'Reconnect'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Forget'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
        expect(find.widgetWithText(TextField, 'Pairing code'), findsNothing);
        // The conversation was never disturbed by any of it.
        expect(tester.state(find.byType(ChukChatUIDesktop)), same(chatState));
      },
    );

    testWidgets(
      'a view disposed while its reconnect rebuilds the transport stays quiet '
      '(F6)',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final store = await seededStore();
        final first = FakeRelayController();
        // The rebuilt transport takes a while (a real client generates a key).
        final gate = Completer<CoworkRelayController>();
        var builds = 0;
        await tester.pumpWidget(
          _app(
            CoworkThreadView(
              controllerBuilder: () => ++builds == 1
                  ? Future<CoworkRelayController>.value(first)
                  : gate.future,
              sessionSource: const _FakeSessionSource(),
              pairingStore: store,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(first.reconnectCalls, 1);

        // The socket drops; the backoff timer fires and the rebuild starts.
        first.set(
          const CoworkRelayState(
            phase: CoworkRelayPhase.closed,
            detail: 'Host closed the connection',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(builds, 2);

        // The view goes away mid-await (the user navigated on). When the
        // transport finally arrives, no setState may land on a disposed state —
        // that would fail this test with a FlutterError.
        await tester.pumpWidget(const SizedBox.shrink());
        gate.complete(FakeRelayController());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('a dropped connection does NOT end a run on the host', (
      tester,
    ) async {
      final (controllers, _) = await pumpPersistent(tester);
      // A run is in flight on the host, adopted or started by this client.
      CoworkRunLedger.instance.begin('default');

      controllers.single.set(
        const CoworkRelayState(phase: CoworkRelayPhase.closed),
      );
      await tester.pump();

      // A run belongs to the host process, not to the socket.
      expect(CoworkRunLedger.instance.isRunning('default'), isTrue);
    });

    testWidgets('Forget deletes the pairing and returns to the code form', (
      tester,
    ) async {
      final (_, store) = await pumpPersistent(tester, hostAway: true);
      // Forget lives on the bar, and the bar only comes back once the app has
      // tried and failed to reconnect on its own.
      await letTheReconnectsFail(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Forget'));
      await tester.pump();
      await tester.pumpAndSettle();

      // The trust is gone and the code connect form is back.
      expect(await store.loadPairing(), isNull);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
      expect(find.text('Connect to a host to start chatting.'), findsOneWidget);
    });
  });

  // ==========================================================================
  // The window: the imported chat UI, live on the relay.
  // ==========================================================================

  group('the imported chat, live', () {
    Future<FakeRelayController> pumpPaired(
      WidgetTester tester, {
      String threadKey = 'thread-1',
      List<bool>? runStates,
    }) async {
      final controller = await pumpView(
        tester,
        threadKey: threadKey,
        runStates: runStates,
      );
      controller.set(
        const CoworkRelayState(
          phase: CoworkRelayPhase.paired,
          peerDeviceId: 'cowork-host',
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('the paired body IS the imported chat screen, on this thread', (
      tester,
    ) async {
      await pumpPaired(tester);

      final screen = tester.widget<ChukChatUIDesktop>(
        find.byType(ChukChatUIDesktop),
      );
      // One id: the screen's chat id, the executor's session key, the cache row.
      expect(screen.selectedChatId, 'thread-1');
      // The host runs every tool; the client must never dispatch one.
      expect(screen.toolCallingEnabled, isFalse);
      expect(screen.toolDiscoveryMode, isFalse);
      // Quiet by default (§ "quiet by default, full log on demand").
      expect(screen.showToolCalls, isFalse);
      expect(screen.showTps, isFalse);
      // The thinking block is not part of verbose: it follows the user's own
      // "show reasoning" setting, on by default like chuk (bead cowork-0ia).
      expect(screen.showReasoningTokens, isTrue);
      // And the link now points at this thread, for a caller with no chat id.
      expect(CoworkRelayLink.instance.sessionKey.value, 'thread-1');
      expect(CoworkRelayLink.instance.controller.value, isNotNull);
    });

    testWidgets('the verbose toggle turns the full log on live', (
      tester,
    ) async {
      await pumpPaired(tester);
      await VerboseService.instance.setEnabled(true);
      await tester.pumpAndSettle();

      final screen = tester.widget<ChukChatUIDesktop>(
        find.byType(ChukChatUIDesktop),
      );
      expect(screen.showToolCalls, isTrue);
      expect(screen.showReasoningTokens, isTrue);
      expect(screen.showTps, isTrue);
    });

    testWidgets(
      'the thinking block follows the "show reasoning" setting, not verbose',
      (tester) async {
        // Bead cowork-0ia: a thinking model's reasoning is visible in the quiet
        // view (the setting is on by default, like chuk) and hidden only when the
        // user turns that setting off — verbose does not touch it either way.
        // The setting is flipped through the persisted preference (what the
        // Customization page writes), not the setter: the setter debounces a
        // Supabase sync on a timer the test harness would have to wait out. The
        // service caches the preferences instance it first sees, so the test
        // writes through that same instance.
        final prefs = await SharedPreferences.getInstance();
        Future<void> setShowReasoning(bool show) async {
          await prefs.setBool('showReasoningTokens', show);
          await AppThemeService.instance.loadFromPrefs();
          await tester.pumpAndSettle();
        }

        addTearDown(() async {
          await prefs.setBool('showReasoningTokens', true);
          await AppThemeService.instance.loadFromPrefs();
        });
        await pumpPaired(tester);

        ChukChatUIDesktop screen() =>
            tester.widget<ChukChatUIDesktop>(find.byType(ChukChatUIDesktop));

        expect(screen().showReasoningTokens, isTrue);
        expect(screen().showToolCalls, isFalse);

        await setShowReasoning(false);
        expect(screen().showReasoningTokens, isFalse);

        await VerboseService.instance.setEnabled(true);
        await tester.pumpAndSettle();
        expect(screen().showToolCalls, isTrue);
        expect(screen().showReasoningTokens, isFalse);

        await setShowReasoning(true);
        expect(screen().showReasoningTokens, isTrue);
      },
    );

    testWidgets('"More models" is wired to the shell', (tester) async {
      var opened = 0;
      final controller = await pumpView(
        tester,
        threadKey: 'thread-1',
        onOpenModelScreen: () => opened++,
      );
      controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
      await tester.pumpAndSettle();

      final screen = tester.widget<ChukChatUIDesktop>(
        find.byType(ChukChatUIDesktop),
      );
      expect(screen.onOpenModelSettings, isNotNull);
      await screen.onOpenModelSettings!();
      expect(opened, 1);
    });

    testWidgets('pairing asks the host to replay this thread from the cursor', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);

      expect(controller.replayRequests, <(String, int)>[('thread-1', 0)]);
    });

    testWidgets('a stored cursor rides the replay request', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        '${kReplayCursorPrefix}thread-1': 42,
      });
      await CoworkReplayLoader.instance.load();

      final controller = await pumpPaired(tester);
      expect(controller.replayRequests, <(String, int)>[('thread-1', 42)]);
    });

    testWidgets(
      'switching agent repoints the link and replays the new thread',
      (tester) async {
        final controller = FakeRelayController();
        Widget build(String threadKey) => _app(
          CoworkThreadView(
            controllerBuilder: () async => controller,
            sessionSource: const _FakeSessionSource(),
            threadKey: threadKey,
            fileSaver: _NoopSaver(),
          ),
        );
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(build('amber-otter-1'));
        await tester.pumpAndSettle();
        controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
        await tester.pumpAndSettle();

        await tester.pumpWidget(build('amber-otter-2'));
        await tester.pumpAndSettle();

        expect(controller.replaySessionKeys, <String>[
          'amber-otter-1',
          'amber-otter-2',
        ]);
        expect(CoworkRelayLink.instance.sessionKey.value, 'amber-otter-2');
        final screen = tester.widget<ChukChatUIDesktop>(
          find.byType(ChukChatUIDesktop),
        );
        expect(screen.selectedChatId, 'amber-otter-2');

        await _flushIdleTimers(tester);
      },
    );

    testWidgets('the replayed transcript paints in the imported message list', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);
      expect(controller.replayRequests, isNotEmpty);

      // The host answers the replay with the stored thread.
      controller.emit(
        const CoworkRelayRunState(sessionKey: 'thread-1', state: 'idle'),
      );
      controller.emit(const CoworkRelayUser('do the thing', mid: 1));
      controller.emit(const CoworkRelayDelta('all ', replay: true, mid: 2));
      controller.emit(const CoworkRelayDelta('set', replay: true, mid: 3));
      controller.emit(const CoworkRelayDone(reason: 'replay', replay: true));
      await tester.pumpAndSettle();

      // Server truth -> local cache -> the imported renderer, with no edit to
      // a single imported file.
      expect(find.byType(MessageBubble), findsWidgets);
      expect(find.textContaining('do the thing'), findsWidgets);
      expect(find.textContaining('all set'), findsWidgets);
      // And the cursor advanced, so the next replay is a delta.
      expect(CoworkReplayLoader.instance.cursorFor('thread-1'), 3);

      // The remount left the imported screen's own idle-close timer behind.
      await _flushIdleTimers(tester);
    });

    testWidgets('a replay that lands mid-run does not tear the screen down', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);
      // A run is in flight for this thread.
      CoworkRunLedger.instance.begin('thread-1');
      await tester.pump();

      controller.emit(
        const CoworkRelayRunState(sessionKey: 'thread-1', state: 'idle'),
      );
      controller.emit(const CoworkRelayUser('older turn', mid: 1));
      controller.emit(const CoworkRelayDone(reason: 'replay', replay: true));
      await tester.pumpAndSettle();

      // Nothing repainted yet: remounting would throw away the answer that is
      // streaming into the screen right now.
      expect(find.textContaining('older turn'), findsNothing);

      // The run ends, and the pending replay is adopted.
      CoworkRunLedger.instance.finish('thread-1', reason: 'finished');
      await tester.pumpAndSettle();
      expect(find.textContaining('older turn'), findsWidgets);

      await _flushIdleTimers(tester);
    });

    testWidgets('a here.now approval is answered through the AskUserCard', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);

      controller.emit(
        const CoworkRelayApprovalRequest(
          approvalId: 'ap-1',
          action: 'herenow_publish',
          path: 'site',
          name: 'My Page',
          fileCount: 2,
          totalBytes: 2048,
          baseUrl: 'https://here.now',
          public: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Publish to the web?'), findsOneWidget);
      expect(find.textContaining('My Page · 2 files · 2.0 KB'), findsOneWidget);
      expect(find.byType(AskUserCard), findsOneWidget);

      await tester.tap(find.text('1. Publish'));
      await tester.pumpAndSettle();

      expect(controller.approvalDecisions, <(String, bool)>[('ap-1', true)]);
      // The card resolves: the answer is sent exactly once.
      expect(find.text('Published'), findsOneWidget);
      expect(find.byType(AskUserCard), findsNothing);
    });

    testWidgets(
      'an approval that names another thread is left to that thread\'s view '
      '(F9)',
      (tester) async {
        final controller = await pumpPaired(tester);

        controller.emit(
          const CoworkRelayApprovalRequest(
            approvalId: 'ap-other',
            action: 'herenow_publish',
            path: 'site',
            name: 'Elsewhere',
            fileCount: 1,
            totalBytes: 10,
            baseUrl: 'https://here.now',
            public: true,
            sessionKey: 'other-thread',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Publish to the web?'), findsNothing);

        // Named for this thread: prompted as before.
        controller.emit(
          const CoworkRelayApprovalRequest(
            approvalId: 'ap-mine',
            action: 'herenow_publish',
            path: 'site',
            name: 'Mine',
            fileCount: 1,
            totalBytes: 10,
            baseUrl: 'https://here.now',
            public: true,
            sessionKey: 'thread-1',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Publish to the web?'), findsOneWidget);
        expect(find.textContaining('Mine'), findsWidgets);
      },
    );

    testWidgets('denying an approval sends deny and marks it denied', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);

      controller.emit(
        const CoworkRelayApprovalRequest(
          approvalId: 'ap-2',
          action: 'herenow_publish',
          path: 'site',
          name: 'Draft',
          fileCount: 1,
          totalBytes: 10,
          baseUrl: 'https://here.now',
          public: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('2. Deny'));
      await tester.pumpAndSettle();

      expect(controller.approvalDecisions, <(String, bool)>[('ap-2', false)]);
      expect(find.text('Denied'), findsOneWidget);
    });

    testWidgets('a live done is acknowledged to the host, exactly once', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);

      controller.emit(
        const CoworkRelayDone(reason: 'finished', runId: 'run-9'),
      );
      controller.emit(
        const CoworkRelayDone(reason: 'finished', runId: 'run-9'),
      );
      await tester.pumpAndSettle();

      expect(controller.ackedRunIds, <String>['run-9']);
    });

    testWidgets('automatic completion replays only its own thread', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);
      final before = controller.replayRequests.length;
      controller.emit(
        const CoworkRelayDone(
          reason: 'finished',
          runId: 'other-auto',
          sessionKey: 'other-thread',
          hostNotified: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.replayRequests.length, before);
      controller.emit(
        const CoworkRelayDone(
          reason: 'finished',
          runId: 'own-auto',
          sessionKey: 'thread-1',
          hostNotified: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.replayRequests.length, before + 1);
      expect(controller.ackedRunIds, isEmpty);
    });

    testWidgets('a replayed done is never acknowledged', (tester) async {
      final controller = await pumpPaired(tester);

      controller.emit(
        const CoworkRelayDone(
          reason: 'finished',
          replay: true,
          whileAway: true,
          runId: 'run-old',
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.ackedRunIds, isEmpty);
    });

    testWidgets('the roster follows the run off the ledger', (tester) async {
      final runStates = <bool>[];
      await pumpPaired(tester, runStates: runStates);

      CoworkRunLedger.instance.begin('thread-1');
      await tester.pump();
      expect(runStates, <bool>[true]);

      CoworkRunLedger.instance.finish('thread-1', reason: 'finished');
      await tester.pump();
      expect(runStates, <bool>[true, false]);
    });
  });
}

/// The imported chat screen schedules a 60 s idle-close timer for its
/// multiplex socket when it is disposed. A test that replaces the screen while
/// it runs (a replay remount, an agent switch) has to clear it, or the harness
/// fails the test for a pending timer that is not its business.
Future<void> _flushIdleTimers(WidgetTester tester) async {
  await MultiplexSession.shutdown();
  await tester.pumpAndSettle();
}
