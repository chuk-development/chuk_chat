// Every state of the Agents shell renders something a person can read and act
// on — never the empty window the "blank Agents" bug showed (a signed-in user
// with no computer saw a chat area with nothing in it).
//
// (a) not paired            -> "Add your computer" (and "Looking for your
//                              computer…" while a restore can still land)
// (b) paired, connecting    -> "Connecting to your computer…"
// (c) paired, host away     -> "Your computer is offline" + Reconnect, and a
//                              short neutral line while a heal is running
// (d) connected, no agents  -> "No agents yet" + Add an agent
//
// Each is checked on the desktop layout and on the phone layout.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agents_pairing_page.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_pairing_restore.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';
import 'package:chuk_chat/widgets/agents_status_panel.dart';

import '../support/fake_relay_controller.dart';
import '../support/test_app.dart';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// The encrypted mirror, answering one scripted outcome.
class _Mirror extends SupabasePairingSync {
  _Mirror(this.outcome);

  final AgentsCloudPairingOutcome outcome;

  @override
  Future<AgentsCloudPairingRead> readEncryptedPairing() async =>
      AgentsCloudPairingRead(outcome);

  @override
  Future<bool> publishEncryptedPairing(AgentsStoredPairing pairing) async =>
      true;

  @override
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {}

  @override
  Future<void> clearEncryptedPairing() async {}
}

class _Session implements AccountSessionSource {
  const _Session({this.signedIn = true});

  final bool signedIn;

  @override
  AccountSession? current() => signedIn
      ? const AccountSession(
          accessToken: 'access-1',
          refreshToken: 'refresh-1',
          userId: 'user-1',
        )
      : null;

  @override
  Future<AccountSession?> refresh() async => current();
}

/// A reconnect that never finishes: the link stays "connecting".
class _HangingController extends FakeRelayController {
  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required AgentsStoredPairing pairing,
  }) => Completer<void>().future;
}

/// A host that lists no agents: pairing does not bring a host coworker.
class _EmptyHostRoster extends LocalAgentRosterSource {
  @override
  AgentsAgent ensureHostAgent(String peerDeviceId) => AgentsAgent(
    id: 'host:$peerDeviceId',
    name: peerDeviceId,
    onHost: true,
    threads: const <AgentsThreadInfo>[],
  );
}

const Size kDesktop = Size(1340, 818);
const Size kPhone = Size(412, 915);

void main() {
  late AgentsStoredPairing record;

  setUpAll(() async {
    final hostKey = await AgentsDeviceKeys.generate();
    record = AgentsStoredPairing(
      hostUrl: Uri.parse(
        'wss://api.chuk.chat/v2/relay/ws?cw_device=host-device-uuid',
      ),
      channelId: 'chan-1',
      channelKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      peerDeviceId: 'host-device-uuid',
      peerPublicKey: await hostKey.extractPublicKey(),
    );
  });

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(() => AgentsCloudRelaySocket.debugHealInProgress = false);

  /// Pumps the shell with a scripted restore: the key is unlocked, the mirror
  /// answers [mirror], and the supervisor never sleeps its way into a timer.
  Future<List<FakeRelayController>> pumpShell(
    WidgetTester tester, {
    required Size size,
    AgentsCloudPairingOutcome mirror = AgentsCloudPairingOutcome.noRecord,
    bool signedIn = true,
    bool paired = false,
    FakeRelayController Function()? controller,
    AgentRosterSource? roster,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = AgentsPairingStore(
      backend: _MemoryStore(),
      cloudSync: _Mirror(mirror),
    );
    if (paired) await store.savePairing(record);
    final built = <FakeRelayController>[];
    await tester.pumpWidget(
      testApp(
        MessengerShell(
          relayControllerBuilder: () async {
            final c = (controller ?? FakeRelayController.new)();
            built.add(c);
            return c;
          },
          sessionSource: _Session(signedIn: signedIn),
          pairingStore: store,
          rosterSource: roster ?? LocalAgentRosterSource(),
          roomSource: LocalRoomSource(),
          onSignOut: () {},
          pairingRestoreBuilder: (store, session, onRestored) =>
              AgentsPairingRestore(
                store: store,
                sessionSource: session,
                onRestored: onRestored,
                authChanges: const Stream<Never>.empty(),
                hasEncryptionKey: () => true,
                sleep: (_) => Completer<void>().future,
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return built;
  }

  Finder title(String text) => find.descendant(
    of: find.byType(AgentsStatusPanel),
    matching: find.text(text),
  );

  /// Nothing on screen names the transport.
  void expectNoTransportWords() {
    for (final String word in <String>['WebSocket', 'ws://', 'wss://', '8787']) {
      expect(find.textContaining(word), findsNothing, reason: word);
    }
  }

  for (final (String layout, Size size) in <(String, Size)>[
    ('desktop', kDesktop),
    ('phone', kPhone),
  ]) {
    group(layout, () {
      testWidgets('(a) no computer: "Add your computer" opens the pairing', (
        tester,
      ) async {
        await pumpShell(tester, size: size);

        expect(find.byType(AgentsStatusPanel), findsOneWidget);
        expect(title('Add your computer'), findsWidgets);
        final Finder add = find.byKey(AgentsStatusPanel.addComputerKey);
        expect(add, findsOneWidget);
        expectNoTransportWords();

        await tester.tap(add);
        await tester.pumpAndSettle();
        // The QR flow is up.
        expect(find.byType(AgentsPairingPage), findsOneWidget);
      });

      testWidgets('(a) a restore that can still land says "Looking for your '
          'computer…" and still offers to add one', (tester) async {
        await pumpShell(tester, size: size, signedIn: false);

        expect(title('Looking for your computer…'), findsOneWidget);
        expect(find.byKey(AgentsStatusPanel.addComputerKey), findsOneWidget);
        expect(find.text('Add a computer'), findsOneWidget);
      });

      testWidgets('(a) a mirror that is offline is a search, not a dead end', (
        tester,
      ) async {
        await pumpShell(
          tester,
          size: size,
          mirror: AgentsCloudPairingOutcome.network,
        );
        expect(title('Looking for your computer…'), findsOneWidget);
      });

      testWidgets('(b) paired, connecting: a calm connecting line', (
        tester,
      ) async {
        await pumpShell(
          tester,
          size: size,
          paired: true,
          controller: _HangingController.new,
        );

        expect(title('Connecting to your computer…'), findsOneWidget);
        expect(find.byKey(AgentsStatusPanel.addComputerKey), findsNothing);
        expectNoTransportWords();
      });

      testWidgets('(c) a heal in progress shows a short neutral line', (
        tester,
      ) async {
        await pumpShell(
          tester,
          size: size,
          paired: true,
          controller: _HangingController.new,
        );
        AgentsCloudRelaySocket.debugHealInProgress = true;
        await tester.pumpAndSettle();

        expect(title('Renewing your computer’s sign-in…'), findsOneWidget);
        AgentsCloudRelaySocket.debugHealInProgress = false;
        await tester.pumpAndSettle();
        expect(title('Connecting to your computer…'), findsOneWidget);
      });

      testWidgets('(c) host away after retries: offline + Reconnect', (
        tester,
      ) async {
        final built = await pumpShell(
          tester,
          size: size,
          paired: true,
          controller: () => FakeRelayController()..reconnectFails = true,
        );
        // Still trying: that is "connecting", not an alarm.
        expect(title('Your computer is offline'), findsNothing);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 10));
        }
        await tester.pumpAndSettle();

        expect(title('Your computer is offline'), findsOneWidget);
        final Finder reconnect = find.byKey(AgentsStatusPanel.reconnectKey);
        expect(reconnect, findsOneWidget);
        expectNoTransportWords();

        final before = built.length;
        await tester.tap(reconnect);
        await tester.pumpAndSettle();
        expect(built.length, greaterThan(before));
        expect(built.last.reconnectCalls, greaterThan(0));
      });

      testWidgets('(d) connected with no agents: "No agents yet" + Add', (
        tester,
      ) async {
        await pumpShell(
          tester,
          size: size,
          paired: true,
          roster: _EmptyHostRoster(),
        );

        expect(title('No agents yet'), findsOneWidget);
        final Finder add = find.byKey(AgentsStatusPanel.addAgentKey);
        expect(add, findsOneWidget);
        await tester.tap(add);
        await tester.pumpAndSettle();
        // The New agent dialog.
        expect(find.text('New agent'), findsWidgets);
        expect(find.text('Create'), findsOneWidget);
      });

      testWidgets('a connected shell with agents shows the chat, no panel', (
        tester,
      ) async {
        await pumpShell(tester, size: size, paired: true);
        // The host coworker is selected on desktop; the phone lists it.
        expect(find.byType(AgentsStatusPanel), findsNothing);
      });
    });
  }
}
