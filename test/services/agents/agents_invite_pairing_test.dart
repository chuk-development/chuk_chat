// The one pairing sequence both ways in share: the scanned or typed code and
// the install command.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';
import 'package:chuk_chat/services/agents/agents_invite_pairing.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';

import '../../support/fake_relay_controller.dart';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// The encrypted mirror, recording what it was asked to store.
class _RecordingMirror extends SupabasePairingSync {
  final List<AgentsStoredPairing> saved = <AgentsStoredPairing>[];

  @override
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {
    saved.add(pairing);
  }

  @override
  Future<void> clearEncryptedPairing() async {}
}

class _Session implements AccountSessionSource {
  const _Session([this._session]);

  final AccountSession? _session;

  @override
  AccountSession? current() => _session;

  @override
  Future<AccountSession?> refresh() async => _session;
}

void main() {
  late AgentsStoredPairing ceremonyTrust;
  late _RecordingMirror mirror;
  late AgentsPairingStore store;

  const AccountSession session = AccountSession(
    accessToken: 'jwt',
    refreshToken: 'r',
    userId: 'user-1',
  );

  setUpAll(() async {
    final hostKey = await AgentsDeviceKeys.generate();
    ceremonyTrust = AgentsStoredPairing(
      // What the ceremony reports: the PAIRING form of the address.
      hostUrl: Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_pair=abc'),
      channelId: 'chan-1',
      channelKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      peerDeviceId: 'ceremony-host-id',
      peerPublicKey: await hostKey.extractPublicKey(),
    );
  });

  setUp(() {
    AgentsCloudRelaySocket.resetClaimCache();
    mirror = _RecordingMirror();
    store = AgentsPairingStore(backend: _MemoryStore(), cloudSync: mirror);
  });

  final AgentsPairingInvite scanned = AgentsPairingInvite.tryParse(
    'cowork://pair?c=k7m2p9q4w8r3t6y1u5i0o2a7s4d9f3g6h1j8k5l2z7x4c9v6b3'
    '&k=428913',
  )!;

  test('the scan path: connect, provision, save the reconnect form', () async {
    final FakeRelayController controller = FakeRelayController()
      ..trustOnConnect = ceremonyTrust;
    int changes = 0;
    store.changes.addListener(() => changes++);

    final AgentsStoredPairing? trust = await pairAgentsFromInvite(
      controller: controller,
      invite: scanned,
      sessionSource: const _Session(session),
      store: store,
    );

    // Dialled the invite's pairing address with the §15 code.
    expect(controller.connects, hasLength(1));
    final (Uri dialled, String code) = controller.connects.single;
    expect(dialled, AgentsCloudRelayAddress.forInvite(scanned).toUri());
    expect(code, scanned.pairingCode);
    expect(controller.provisioned, isTrue);
    // No claim was learned (a fake transport), so the ceremony's id is used.
    expect(
      trust!.hostUrl,
      AgentsCloudRelayAddress.forHost(
        base: scanned.relayBase,
        targetDeviceId: 'ceremony-host-id',
      ).toUri(),
    );
    expect(trust.channelKey, ceremonyTrust.channelKey);
    // Saved locally, the store signalled, and the mirror got it.
    final AgentsStoredPairing? stored = await store.loadPairing();
    expect(stored?.hostUrl, trust.hostUrl);
    expect(changes, 1);
    await pumpEventQueue();
    expect(mirror.saved, hasLength(1));
  });

  test('the install path: the claimed device id wins, same sequence', () async {
    final AgentsInstallTicket ticket = AgentsInstallTicket.mint(
      userId: 'user-1',
      now: DateTime.utc(2026, 9, 29),
    );
    final AgentsPairingInvite invite = ticket.invite;
    AgentsCloudRelaySocket.debugRememberClaim(
      base: invite.relayBase,
      pairingChannel: invite.pairingChannel,
      deviceId: 'relay-host-id',
    );
    final FakeRelayController controller = FakeRelayController()
      ..trustOnConnect = ceremonyTrust;

    final AgentsStoredPairing? trust = await pairAgentsFromInvite(
      controller: controller,
      invite: invite,
      sessionSource: const _Session(session),
      store: store,
    );

    final (Uri dialled, String code) = controller.connects.single;
    expect(code, '${ticket.channel}-${ticket.digits}');
    expect(
      AgentsCloudRelayAddress.tryParse(dialled)?.pairingChannel,
      ticket.channel,
    );
    expect(
      AgentsCloudRelayAddress.tryParse(trust!.hostUrl)?.targetDeviceId,
      'relay-host-id',
    );
    expect(
      AgentsCloudRelayAddress.tryParse(trust.hostUrl)?.pairingChannel,
      isNull,
      reason: 'the single-use channel is never remembered',
    );
  });

  test('no session: paired, not provisioned', () async {
    final FakeRelayController controller = FakeRelayController()
      ..trustOnConnect = ceremonyTrust;
    await pairAgentsFromInvite(
      controller: controller,
      invite: scanned,
      sessionSource: const _Session(),
      store: store,
    );
    expect(controller.provisioned, isFalse);
    expect(await store.loadPairing(), isNotNull);
  });

  test('no trust or no store: nothing saved', () async {
    final FakeRelayController noTrust = FakeRelayController();
    expect(
      await pairAgentsFromInvite(
        controller: noTrust,
        invite: scanned,
        sessionSource: const _Session(session),
        store: store,
      ),
      isNull,
    );
    expect(await store.loadPairing(), isNull);

    final FakeRelayController noStore = FakeRelayController()
      ..trustOnConnect = ceremonyTrust;
    expect(
      await pairAgentsFromInvite(
        controller: noStore,
        invite: scanned,
        sessionSource: const _Session(session),
      ),
      isNull,
    );
  });

  test('a failed ceremony throws and saves nothing', () async {
    final FakeRelayController controller = FakeRelayController()
      ..connectError = const AgentsCloudRelayException('nope', code: 'x');
    await expectLater(
      pairAgentsFromInvite(
        controller: controller,
        invite: scanned,
        sessionSource: const _Session(session),
        store: store,
      ),
      throwsA(isA<AgentsCloudRelayException>()),
    );
    expect(await store.loadPairing(), isNull);
  });

  test(
    'a provisioning failure keeps the trust: the heal path finishes it',
    () async {
      final FakeRelayController controller = FakeRelayController()
        ..trustOnConnect = ceremonyTrust
        ..provisionError = StateError('host went away');
      final AgentsStoredPairing? trust = await pairAgentsFromInvite(
        controller: controller,
        invite: scanned,
        sessionSource: const _Session(session),
        store: store,
      );
      expect(trust, isNotNull);
      expect(controller.provisioned, isFalse);
      expect((await store.loadPairing())?.hostUrl, trust!.hostUrl);
    },
  );
}
