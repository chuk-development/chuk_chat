import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

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

  testWidgets('paired phase shows the chat: bare thread and composer, no status strip',
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
    // Nothing sits on top of the chat: no status line, no host, no SAS, and
    // no disconnect button — the socket is not something the user manages.
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
}
