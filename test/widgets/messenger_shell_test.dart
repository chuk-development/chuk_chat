import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/pages/messenger_shell.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/agent_control_source.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/agent_onboarding_sheet.dart';
import 'package:cowork/widgets/agent_roster_view.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

class _MemoryStore implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// A controller the test drives: it can report itself paired, and it records
/// which session key each task went to.
class _FakeRelayController implements CoworkRelayController {
  final ValueNotifier<CoworkRelayState> _state =
      ValueNotifier<CoworkRelayState>(
    const CoworkRelayState(phase: CoworkRelayPhase.idle),
  );
  final StreamController<CoworkRelayInbound> _inbound =
      StreamController<CoworkRelayInbound>.broadcast();

  final List<String> sessionKeys = <String>[];

  @override
  ValueListenable<CoworkRelayState> get state => _state;

  @override
  Stream<CoworkRelayInbound> get inbound => _inbound.stream;

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {}

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required CoworkStoredPairing pairing,
  }) async {
    pair();
  }

  @override
  CoworkStoredPairing? get establishedTrust => null;

  @override
  Future<void> provisionAccount(AccountSession session) async {}

  @override
  Future<void> sendTask(String prompt, {String sessionKey = 'default'}) async =>
      sessionKeys.add(sessionKey);

  @override
  Future<void> requestStop({String sessionKey = 'default'}) async {}

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
    _state.dispose();
  }

  void pair() => _state.value = const CoworkRelayState(
        phase: CoworkRelayPhase.paired,
        peerDeviceId: 'cowork-host',
      );

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
  Future<(_FakeRelayController, LocalAgentRosterSource)> pumpShell(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    CoworkPairingStore? store,
    AgentControlSource? controlSource,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = _FakeRelayController();
    final roster = LocalAgentRosterSource();
    await tester.pumpWidget(
      MaterialApp(
        home: MessengerShell(
          relayControllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          pairingStore: store ?? CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          controlSource: controlSource,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, roster);
  }

  testWidgets('a wide window shows the roster next to the thread', (tester) async {
    await pumpShell(tester);

    expect(find.byType(AgentRosterView), findsOneWidget);
    expect(find.byType(CoworkThreadView), findsOneWidget);
    expect(find.text('Coworkers'), findsOneWidget);
    expect(find.text('No coworkers yet.'), findsOneWidget);
    // Nothing sits on top of the chat: the connection is not the user's job.
    expect(find.textContaining('Connected to'), findsNothing);
    expect(find.byIcon(Icons.link_off), findsNothing);
  });

  testWidgets('pairing lists the agent that really runs on the host',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);

    controller.pair();
    await tester.pumpAndSettle();

    // Named after the host's own device id, and marked as living there.
    expect(find.text('cowork-host'), findsWidgets);
    expect(roster.agents.single.onHost, isTrue);
    expect(roster.agents.single.threads.single.key, 'default');
  });

  testWidgets('onboarding adds a coworker and opens its thread', (tester) async {
    final (controller, roster) = await pumpShell(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    expect(find.byType(AgentOnboardingSheet), findsOneWidget);

    // The suggested name is an adjective-noun; keep it and give it a job. Scope
    // the finder to the sheet: the connect bar behind it has fields too.
    // Target the Job field by its label, not by index — the form gained a Role
    // field, so positional indices are brittle.
    final jobField = find.descendant(
      of: find.byType(AgentOnboardingSheet),
      matching: find.widgetWithText(TextField, 'Job'),
    );
    await tester.enterText(jobField, 'weekly crypto news');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentOnboardingSheet), findsNothing);
    expect(roster.agents, hasLength(1));
    expect(roster.agents.single.brief, 'weekly crypto news');
    // An app-created agent is never claimed to be installed on the host.
    expect(roster.agents.single.onHost, isFalse);
    // Its thread is selected: the app bar carries its name.
    expect(find.widgetWithText(AppBar, roster.agents.single.name), findsOneWidget);
    expect(controller.sessionKeys, isEmpty);
  });

  testWidgets('a second thread is opened from the app bar and gets its own key',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'in the first thread');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    controller.emit(const CoworkRelayDone());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    await tester.pumpAndSettle();

    expect(roster.agents.single.threads, hasLength(2));
    // The fresh thread is empty, and its task rides a different session key.
    expect(find.text('in the first thread'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'in the second thread');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(controller.sessionKeys, hasLength(2));
    expect(controller.sessionKeys.first, 'default');
    expect(controller.sessionKeys.last, isNot('default'));
  });

  testWidgets('a run marks the agent as working and back to waiting',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'do the thing');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.textContaining('working'), findsOneWidget);

    controller.emit(const CoworkRelayDone());
    await tester.pumpAndSettle();

    expect(find.textContaining('working'), findsNothing);
    expect(find.textContaining('waiting'), findsOneWidget);
    expect(roster.agents.single.lastActivity, isNotNull);
  });

  testWidgets('the controls button opens the panel, which reports what is missing',
      (tester) async {
    final (controller, _) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // The default source reports every block as not connected.
    expect(find.text('Not connected yet'), findsNWidgets(6));
    expect(find.text('TOKEN USE'), findsOneWidget);
    expect(find.text('SESSION RUNTIME'), findsOneWidget);
    expect(find.text('SCHEDULE'), findsOneWidget);
    expect(find.text('SKILLS'), findsOneWidget);
    expect(find.text('INTEGRATIONS'), findsOneWidget);
  });

  testWidgets('a schedule set in the panel lands on the agent', (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Schedule'), 'every 6h');
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();

    expect(roster.agents.single.schedule!.source, 'every 6h');
  });

  testWidgets('a narrow window shows the roster first, then the thread',
      (tester) async {
    final (controller, _) = await pumpShell(tester, size: const Size(420, 900));
    controller.pair();
    await tester.pumpAndSettle();

    // The roster is on screen; the thread is stacked behind it.
    expect(find.text('Coworkers'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    await tester.tap(find.text('cowork-host').first);
    await tester.pumpAndSettle();

    // Now the thread is in front, with a way back to the roster.
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });
}
