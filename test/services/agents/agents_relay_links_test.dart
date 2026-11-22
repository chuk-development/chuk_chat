// CHAT-177: one link per paired computer. The registry routes a host id to
// its link; the supervisor keeps a socket up for every computer that is not
// on screen, and hands it to the thread view on a switch.
import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_host_links.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
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

class _NoMirror extends SupabasePairingSync {
  @override
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {}

  @override
  Future<void> clearEncryptedPairing({String? hostId}) async {}
}

class _Session implements AccountSessionSource {
  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'jwt',
    refreshToken: 'refresh',
    userId: 'user-1',
  );

  @override
  Future<AccountSession?> refresh() async => current();
}

void main() {
  late SimplePublicKey hostKey;
  final AgentsRelayLinks links = AgentsRelayLinks.instance;

  setUpAll(() async {
    hostKey = await (await AgentsDeviceKeys.generate()).extractPublicKey();
  });

  setUp(links.reset);
  tearDown(links.reset);

  AgentsStoredPairing pairing(String device) => AgentsStoredPairing(
    hostUrl: Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=$device'),
    channelId: 'chan-$device',
    channelKey: Uint8List(32),
    peerDeviceId: 'cowork-host',
    peerPublicKey: hostKey,
  );

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('AgentsRelayLinks', () {
    test('no host, the primary host or no primary yet: the primary', () {
      expect(links.linkFor(null), same(links.primary));
      expect(links.linkFor('pc'), same(links.primary)); // no primary yet
      links.setPrimaryHost('pc');
      expect(links.linkFor('pc'), same(links.primary));
      expect(links.linkFor(''), same(links.primary));
    });

    test('another computer gets a link of its own, once', () {
      links.setPrimaryHost('pc');
      final AgentsRelayLink box = links.linkFor('box');
      expect(box, isNot(same(links.primary)));
      expect(box.hostId.value, 'box');
      expect(links.linkFor('box'), same(box));
      expect(links.secondaryHostIds, <String>['box']);
    });

    test('a frame on a secondary link carries its computer', () async {
      links.setPrimaryHost('pc');
      final FakeRelayController box = FakeRelayController();
      final FakeRelayController pc = FakeRelayController();
      links.linkFor('box').bind(box);
      links.primary.bind(pc);
      final List<AgentsHostInbound> tagged = <AgentsHostInbound>[];
      final List<AgentsRelayInbound> primary = <AgentsRelayInbound>[];
      final StreamSubscription<AgentsHostInbound> a = links.secondaryInbound
          .listen(tagged.add);
      final StreamSubscription<AgentsRelayInbound> b = links.primary.inbound
          .listen(primary.add);

      box.emit(const AgentsRelayAgentList(agents: <AgentsHostAgentName>[]));
      pc.emit(const AgentsRelayAgentList(agents: <AgentsHostAgentName>[]));

      expect(tagged.single.hostId, 'box');
      // The box's frame never reaches the primary link, and back.
      expect(primary, hasLength(1));
      await a.cancel();
      await b.cancel();
      await box.dispose();
      await pc.dispose();
    });

    test('online is per computer', () async {
      links.setPrimaryHost('pc');
      final FakeRelayController box = FakeRelayController();
      links.linkFor('box').bind(box);
      expect(links.isOnline('box'), isFalse);
      box.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
      expect(links.isOnline('box'), isTrue);
      expect(links.isOnline('pc'), isFalse);
      await box.dispose();
    });

    test('a computer that becomes primary loses its secondary link', () {
      links.setPrimaryHost('pc');
      final AgentsRelayLink box = links.linkFor('box');
      box.bind(FakeRelayController());
      links.setPrimaryHost('box');
      expect(links.secondaryFor('box'), isNull);
      expect(box.controller.value, isNull);
      expect(links.linkFor('box'), same(links.primary));
    });

    test('drop forgets the link', () {
      links.setPrimaryHost('pc');
      links.linkFor('box');
      links.drop('box');
      expect(links.secondaryHostIds, isEmpty);
    });
  });

  group('AgentsHostLinks', () {
    late AgentsPairingStore store;
    late List<FakeRelayController> built;
    late AgentsHostLinks supervisor;

    setUp(() async {
      store = AgentsPairingStore(
        backend: _MemoryStore(),
        cloudSync: _NoMirror(),
      );
      await store.savePairing(pairing('pc'));
      await store.savePairing(pairing('box'));
      built = <FakeRelayController>[];
      supervisor = AgentsHostLinks(
        store: store,
        build: () async {
          final FakeRelayController c = FakeRelayController();
          built.add(c);
          return c;
        },
        sessionSource: _Session(),
        interval: const Duration(hours: 1),
        backoff: const <Duration>[Duration.zero],
      );
    });

    tearDown(() => supervisor.dispose());

    test('nothing is dialled before the view picked its computer', () async {
      supervisor.start();
      await settle();
      expect(built, isEmpty);
    });

    test('every computer but the primary one gets a socket', () async {
      links.setPrimaryHost('pc');
      supervisor.start();
      await settle();

      expect(supervisor.hostIds, <String>['box']);
      expect(built.single.reconnectCalls, 1);
      expect(built.single.provisioned, isTrue);
      expect(links.secondaryFor('box')!.controller.value, same(built.single));
      expect(links.isOnline('box'), isTrue);
    });

    test(
      'a switch hands the open socket over and takes the old one back',
      () async {
        links.setPrimaryHost('pc');
        supervisor.start();
        await settle();
        final FakeRelayController boxSocket = built.single;

        // The thread view moves to the box: it takes the box's socket ...
        final AgentsRelayController? taken = supervisor.takeController('box');
        expect(taken, same(boxSocket));
        expect(supervisor.controllerFor('box'), isNull);
        links.setPrimaryHost('box');
        // ... and hands back its PC socket, which stays up.
        final FakeRelayController pcSocket = FakeRelayController()
          ..set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
        supervisor.adopt('pc', pcSocket);
        await settle();

        expect(supervisor.controllerFor('pc'), same(pcSocket));
        expect(links.secondaryFor('pc')!.controller.value, same(pcSocket));
        // No new socket was dialled for either computer.
        expect(built, hasLength(1));
      },
    );

    test('a removed computer loses its socket', () async {
      links.setPrimaryHost('pc');
      supervisor.start();
      await settle();
      expect(supervisor.hostIds, <String>['box']);

      await store.removePairing('box');
      await settle();

      expect(supervisor.hostIds, isEmpty);
      expect(links.secondaryFor('box'), isNull);
    });

    test('a dead socket is dialled again', () async {
      links.setPrimaryHost('pc');
      supervisor.start();
      await settle();
      built.single.set(const AgentsRelayState(phase: AgentsRelayPhase.closed));

      await supervisor.sync();
      await settle();

      expect(built, hasLength(2));
      expect(supervisor.controllerFor('box'), same(built.last));
    });

    test('a computer added later is picked up', () async {
      await store.removePairing('box');
      links.setPrimaryHost('pc');
      supervisor.start();
      await settle();
      expect(built, isEmpty);

      await store.savePairing(pairing('box'));
      await settle();

      expect(supervisor.hostIds, <String>['box']);
    });
  });
}
