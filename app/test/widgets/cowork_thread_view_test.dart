import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/agent_file_saver.dart';
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
  final List<String> taskSessionKeys = <String>[];
  int stopCalls = 0;
  final List<String> stopSessionKeys = <String>[];

  /// When set, [requestStop] throws it — the "the stop never left" path.
  Object? stopError;

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
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members,
  ) async {}

  @override
  Future<void> sendRoomTask(String roomId, String message) async {}

  @override
  Future<void> requestRoomHistory(String roomId) async {}

  @override
  Future<void> deleteRoom(String roomId) async {}

  @override
  Future<void> renameRoom(String roomId, String name) async {}

  @override
  Future<void> sendTask(String prompt, {String sessionKey = 'default'}) async {
    tasks.add(prompt);
    taskSessionKeys.add(sessionKey);
  }

  @override
  Future<void> requestStop({String sessionKey = 'default'}) async {
    stopCalls++;
    stopSessionKeys.add(sessionKey);
    final error = stopError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
    _state.dispose();
  }

  void set(CoworkRelayState next) => _state.value = next;
  void emit(CoworkRelayInbound event) => _inbound.add(event);
}

/// A saver that never touches a filesystem — the thread tests only care that a
/// card renders, not where it would land.
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
    expect(find.text('shell · running'), findsOneWidget);
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

  group('streaming a run', () {
    Future<FakeRelayController> pumpPaired(
      WidgetTester tester, {
      String threadKey = 'default',
      AgentFileSaver? saver,
      List<bool>? runStates,
    }) async {
      final controller = FakeRelayController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoworkThreadView(
              controllerBuilder: () async => controller,
              sessionSource: const _FakeSessionSource(),
              threadKey: threadKey,
              fileSaver: saver ?? _NoopSaver(),
              onRunStateChanged: runStates == null
                  ? null
                  : (threadKey, running) => runStates.add(running),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
      await tester.pump();
      return controller;
    }

    testWidgets('a tool line opens on tap and marks a failure differently',
        (tester) async {
      final controller = await pumpPaired(tester);

      controller.emit(
        const CoworkRelayTool(
          'run_command',
          arguments: 'ls /nope',
          result: 'No such file or directory',
          detail: 'ls: /nope: No such file or directory',
          exitCode: 2,
          failed: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(find.textContaining('ls: /nope'), findsNothing);

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.textContaining('ls: /nope'), findsOneWidget);
      expect(find.textContaining('exit 2'), findsWidgets);
    });

    testWidgets('reasoning renders in its own folded block, not as the answer',
        (tester) async {
      final controller = await pumpPaired(tester);

      controller.emit(const CoworkRelayReasoning('I will read the log first'));
      controller.emit(const CoworkRelayDelta('Here is the summary.'));
      await tester.pumpAndSettle();

      // The answer is visible; the thinking is behind its own toggle.
      expect(find.text('Here is the summary.'), findsOneWidget);
      expect(find.text('Reasoning'), findsOneWidget);
      expect(find.text('I will read the log first'), findsNothing);

      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();
      expect(find.text('I will read the log first'), findsOneWidget);
    });

    testWidgets('a file event becomes a card; a broken one becomes an error card',
        (tester) async {
      final controller = await pumpPaired(tester);

      controller.emit(
        CoworkRelayFile(
          name: 'report.csv',
          mimeType: 'text/csv',
          declaredSize: 3,
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      );
      controller.emit(
        const CoworkRelayFile(
          name: 'shot.png',
          mimeType: 'image/png',
          declaredSize: 9,
          error: 'The file body is not valid base64.',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('report.csv'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('shot.png'), findsOneWidget);
      expect(find.text('The file body is not valid base64.'), findsOneWidget);
    });

    testWidgets('Stop calls the abort action and shows the in-between state',
        (tester) async {
      final runStates = <bool>[];
      final controller = await pumpPaired(tester, runStates: runStates);

      await tester.enterText(find.byType(TextField).first, 'do the thing');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // A run is in flight: the send button became Stop.
      expect(find.widgetWithText(FilledButton, 'Stop'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
      expect(runStates, <bool>[true]);

      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await tester.pump();

      // Stopping is a request, not a fact: the button says so and is disabled.
      expect(controller.stopCalls, 1);
      expect(find.widgetWithText(FilledButton, 'Stopping…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Stopping…'),
      );
      expect(button.onPressed, isNull);
      // Still running until the executor closes the stream.
      expect(runStates, <bool>[true]);

      // The stop names the thread the run belongs to, which is the session key
      // the task was sent with — without it the executor has nothing to match.
      expect(controller.stopSessionKeys, controller.taskSessionKeys);

      // The run is only over when the executor says so.
      controller.emit(const CoworkRelayDone(reason: 'interrupted', iterations: 2));
      await tester.pumpAndSettle();

      expect(find.text('stopped · 2 rounds'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(runStates, <bool>[true, false]);
    });

    testWidgets('a subagent line appears and updates in place, not duplicated',
        (tester) async {
      final controller = await pumpView(tester);
      controller.set(
        const CoworkRelayState(
          phase: CoworkRelayPhase.paired,
          peerDeviceId: 'host-1',
        ),
      );

      controller.emit(
        const CoworkRelaySubagent(
          subagentId: 'sa_1',
          title: 'writer',
          state: 'running',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('writer · running'), findsOneWidget);

      // Same child transitions: the one line updates, it does not stack, and
      // the child's token spend shows once reported.
      controller.emit(
        const CoworkRelaySubagent(
          subagentId: 'sa_1',
          title: 'writer',
          state: 'succeeded',
          result: 'the summary',
          tokensSpent: 4321,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('writer · running'), findsNothing);
      expect(find.text('writer · succeeded · 4,321 tokens'), findsOneWidget);
    });

    testWidgets('a failed subagent shows its error; a second child is its own line',
        (tester) async {
      final controller = await pumpView(tester);
      controller.set(
        const CoworkRelayState(
          phase: CoworkRelayPhase.paired,
          peerDeviceId: 'host-1',
        ),
      );
      controller.emit(
        const CoworkRelaySubagent(
          subagentId: 'sa_1',
          title: 'writer',
          state: 'running',
        ),
      );
      controller.emit(
        const CoworkRelaySubagent(
          subagentId: 'sa_2',
          title: 'checker',
          state: 'running',
        ),
      );
      controller.emit(
        const CoworkRelaySubagent(
          subagentId: 'sa_1',
          title: 'writer',
          state: 'failed',
          error: 'boom',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('writer · failed — boom'), findsOneWidget);
      expect(find.text('checker · running'), findsOneWidget);
    });

    testWidgets('the done card shows the run token spend when reported',
        (tester) async {
      final controller = await pumpView(tester);
      controller.set(
        const CoworkRelayState(
          phase: CoworkRelayPhase.paired,
          peerDeviceId: 'host-1',
        ),
      );
      controller.emit(
        const CoworkRelayDone(reason: 'finished', iterations: 3, tokensSpent: 1234),
      );
      await tester.pumpAndSettle();

      expect(find.text('done · 3 rounds · 1,234 tokens'), findsOneWidget);
    });

    testWidgets('a zero or absent token count is not shown', (tester) async {
      final controller = await pumpView(tester);
      controller.set(
        const CoworkRelayState(
          phase: CoworkRelayPhase.paired,
          peerDeviceId: 'host-1',
        ),
      );
      // Old host: no tokensSpent field at all.
      controller.emit(const CoworkRelayDone(reason: 'finished', iterations: 1));
      await tester.pumpAndSettle();
      expect(find.text('done · 1 rounds'), findsOneWidget);
      expect(find.textContaining('tokens'), findsNothing);
    });

    testWidgets('a stop that never leaves goes back to Stop and says why',
        (tester) async {
      final controller = await pumpPaired(tester);
      controller.stopError = StateError('socket gone');

      await tester.enterText(find.byType(TextField).first, 'do the thing');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not stop the run'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Stop'), findsOneWidget);
    });

    testWidgets('a run error ends the run and shows the message', (tester) async {
      final controller = await pumpPaired(tester);

      await tester.enterText(find.byType(TextField).first, 'do the thing');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      controller.emit(const CoworkRelayRunError('loop failed: ValueError'));
      await tester.pumpAndSettle();

      expect(find.text('loop failed: ValueError'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('the task carries the thread key, and each thread keeps its log',
        (tester) async {
      final controller = FakeRelayController();
      Widget build(String threadKey) => MaterialApp(
            home: Scaffold(
              body: CoworkThreadView(
                controllerBuilder: () async => controller,
                sessionSource: const _FakeSessionSource(),
                threadKey: threadKey,
                fileSaver: _NoopSaver(),
              ),
            ),
          );

      await tester.pumpWidget(build('amber-otter-1'));
      await tester.pumpAndSettle();
      controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'first thread');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(controller.taskSessionKeys, <String>['amber-otter-1']);
      // The executor serves one task at a time, so let this run finish first.
      controller.emit(const CoworkRelayDone());
      await tester.pumpAndSettle();

      // Switch thread: the other conversation is empty, not merged.
      await tester.pumpWidget(build('amber-otter-2'));
      await tester.pumpAndSettle();
      expect(find.text('first thread'), findsNothing);
      expect(find.text('Send a task to the agent'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'second thread');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(controller.taskSessionKeys,
          <String>['amber-otter-1', 'amber-otter-2']);

      // And switching back brings the first log home.
      await tester.pumpWidget(build('amber-otter-1'));
      await tester.pumpAndSettle();
      expect(find.text('first thread'), findsOneWidget);
      expect(find.text('second thread'), findsNothing);
    });

    testWidgets('a paired transport reports the host device id once',
        (tester) async {
      final peers = <String>[];
      final controller = FakeRelayController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoworkThreadView(
              controllerBuilder: () async => controller,
              sessionSource: const _FakeSessionSource(),
              fileSaver: _NoopSaver(),
              onPaired: peers.add,
            ),
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
      await tester.pump();

      expect(peers, <String>['cowork-host']);
    });
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
