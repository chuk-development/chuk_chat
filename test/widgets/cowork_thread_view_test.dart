import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

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

/// A controller the test drives directly: set [_state], push [emit] — no socket
/// and no real pairing ceremony. Lets the widget states be exercised in
/// isolation from the transport.
class FakeRelayController implements CoworkRelayController {
  final ValueNotifier<CoworkRelayState> _state =
      ValueNotifier<CoworkRelayState>(
    const CoworkRelayState(phase: CoworkRelayPhase.idle),
  );
  final StreamController<CoworkRelayInbound> _inbound =
      StreamController<CoworkRelayInbound>.broadcast();

  int connectCalls = 0;
  bool provisioned = false;
  final List<String> tasks = <String>[];

  @override
  ValueListenable<CoworkRelayState> get state => _state;

  @override
  Stream<CoworkRelayInbound> get inbound => _inbound.stream;

  int reconnectCalls = 0;

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {
    connectCalls++;
    _state.value = const CoworkRelayState(
      phase: CoworkRelayPhase.paired,
      peerDeviceId: 'host-laptop-1',
      sas: '428913',
    );
  }

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required CoworkStoredPairing pairing,
  }) async {
    reconnectCalls++;
    _state.value = const CoworkRelayState(
      phase: CoworkRelayPhase.paired,
      peerDeviceId: 'host-laptop-1',
      detail: 'Reconnected',
    );
  }

  @override
  CoworkStoredPairing? get establishedTrust => null;

  @override
  Future<void> provisionAccount(AccountSession session) async {
    provisioned = true;
  }

  @override
  Future<void> sendTask(String prompt) async => tasks.add(prompt);

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
    _state.dispose();
  }

  void set(CoworkRelayState next) => _state.value = next;
  void emit(CoworkRelayInbound event) => _inbound.add(event);
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

void main() {
  Future<FakeRelayController> pumpView(WidgetTester tester) async {
    final controller = FakeRelayController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CoworkThreadView(
            controllerBuilder: () async => controller,
            sessionSource: const _FakeSessionSource(),
          ),
        ),
      ),
    );
    // Resolve the builder future.
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('shows the connect affordance when disconnected', (tester) async {
    await pumpView(tester);

    // A compact connect bar, not a dominating form: default host prefilled,
    // a pairing-code field, and a Connect button.
    expect(find.text('ws://127.0.0.1:8787'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.text('Connect to a host to start chatting.'), findsOneWidget);
    // No composer while disconnected.
    expect(find.byIcon(Icons.send), findsNothing);
  });

  testWidgets('connecting phase shows only a hairline progress bar',
      (tester) async {
    final controller = await pumpView(tester);
    controller.set(
      const CoworkRelayState(
        phase: CoworkRelayPhase.connecting,
        detail: 'Connecting…',
      ),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // No status text while connecting: the connection is not the user's job.
    expect(find.text('Connecting…'), findsNothing);
  });

  testWidgets('error phase surfaces the failure detail on the connect bar',
      (tester) async {
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

  testWidgets('paired phase shows the chat: bare thread and composer',
      (tester) async {
    final controller = await pumpView(tester);
    controller.set(
      const CoworkRelayState(
        phase: CoworkRelayPhase.paired,
        peerDeviceId: 'host-laptop-1',
        sas: '428913',
      ),
    );
    await tester.pump();

    expect(find.text('Send a task to the agent'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
    // The connect affordance is gone once connected.
    expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
    // And nothing sits on top of the chat: no status line, no host, no SAS,
    // no disconnect button.
    expect(find.textContaining('Connected to'), findsNothing);
    expect(find.textContaining('SAS'), findsNothing);
    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('received delta / tool / done frames render into the thread',
      (tester) async {
    final controller = await pumpView(tester);
    controller.set(
      const CoworkRelayState(phase: CoworkRelayPhase.paired, sas: '428913'),
    );
    await tester.pump();

    controller.emit(const CoworkRelayDelta('Hel'));
    controller.emit(const CoworkRelayDelta('lo'));
    controller.emit(const CoworkRelayTool('shell', status: 'running'));
    controller.emit(const CoworkRelayDone());
    await tester.pumpAndSettle();

    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('ran shell · running'), findsOneWidget);
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('tapping Connect runs connect, provisions, and shows the chat',
      (tester) async {
    final controller = await pumpView(tester);

    // Fields: host at 0, pairing code at 1.
    await tester.enterText(find.byType(TextField).at(1), 'chan1234-428913');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(controller.connectCalls, 1);
    expect(controller.provisioned, isTrue);
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.textContaining('Connected to'), findsNothing);
  });

  testWidgets('sending a message adds a bubble and calls sendTask',
      (tester) async {
    final controller = await pumpView(tester);
    controller.set(
      const CoworkRelayState(phase: CoworkRelayPhase.paired, sas: '428913'),
    );
    await tester.pump();

    // The composer is the only TextField once paired.
    await tester.enterText(find.byType(TextField).first, 'do the thing');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(controller.tasks, <String>['do the thing']);
    expect(find.text('do the thing'), findsOneWidget);
  });

  group('persistent pairing', () {
    Future<CoworkPairingStore> seededStore() async {
      final store = CoworkPairingStore(backend: _MemoryStore());
      final hostPub = await (await CoworkDeviceKeys.generate()).extractPublicKey();
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

    Future<(List<FakeRelayController>, CoworkPairingStore)> pumpPersistent(
      WidgetTester tester,
    ) async {
      final store = await seededStore();
      final controllers = <FakeRelayController>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoworkThreadView(
              controllerBuilder: () async {
                final c = FakeRelayController();
                controllers.add(c);
                return c;
              },
              sessionSource: const _FakeSessionSource(),
              pairingStore: store,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (controllers, store);
    }

    testWidgets('a stored pairing auto-reconnects with no code form',
        (tester) async {
      final (controllers, _) = await pumpPersistent(tester);

      // No code form; it reconnected on its own and provisioned the account.
      expect(controllers.single.reconnectCalls, 1);
      expect(controllers.single.provisioned, isTrue);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
      // No host / pairing-code inputs; the composer is the only field.
      expect(find.widgetWithText(TextField, 'Host'), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
      // Nothing on top: the connection is not the user's business.
      expect(find.textContaining('Connected to'), findsNothing);
      expect(find.byIcon(Icons.link_off), findsNothing);
    });

    testWidgets('a dropped connection shows the reconnect bar, never a code form',
        (tester) async {
      final (controllers, _) = await pumpPersistent(tester);

      // The socket drops on its own — no user action, and no button to press.
      controllers.single.set(
        const CoworkRelayState(
          phase: CoworkRelayPhase.closed,
          detail: 'Host closed the connection',
        ),
      );
      await tester.pump();

      // Still paired (stored), so the code form stays gone; the bottom bar
      // offers Reconnect and, for the it-is-really-broken case, Forget.
      expect(find.widgetWithText(FilledButton, 'Reconnect'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Forget'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
      expect(find.widgetWithText(TextField, 'Pairing code'), findsNothing);

      // And it comes back by itself after the backoff — a fresh controller
      // reconnects with no code and no tap.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(controllers.length, greaterThan(1));
      expect(controllers.last.reconnectCalls, 1);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
    });

    testWidgets('Forget deletes the pairing and returns to the code form',
        (tester) async {
      final (controllers, store) = await pumpPersistent(tester);
      controllers.single.set(
        const CoworkRelayState(phase: CoworkRelayPhase.closed),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, 'Forget'));
      await tester.pump();
      await tester.pumpAndSettle();

      // The trust is gone and the code connect form is back.
      expect(await store.loadPairing(), isNull);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
      expect(find.text('Connect to a host to start chatting.'), findsOneWidget);
    });
  });
}
