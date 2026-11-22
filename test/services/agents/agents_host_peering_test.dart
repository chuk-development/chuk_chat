// CHAT-177 phase 2: the app introduces the paired computers to each other,
// repairs a lost link, undoes half a link, and tells the others to forget a
// computer that is removed.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_host_peering.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _RecordingSync extends SupabasePairingSync {
  final List<String?> cleared = <String?>[];

  @override
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {}

  @override
  Future<void> clearEncryptedPairing({String? hostId}) async {
    cleared.add(hostId);
  }
}

/// One computer as the app sees it: its peer list and every frame it got.
class _FakeHost implements AgentsHostPeersControl {
  _FakeHost(this.id, {bool capable = true})
    : _caps = ValueNotifier<Set<String>>(
        capable
            ? const <String>{AgentsRelayClient.hostPeersCapability}
            : const <String>{},
      );

  final String id;
  final ValueNotifier<Set<String>> _caps;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  /// `peer id -> pair key`.
  final Map<String, String> peers = <String, String>{};

  /// Refuse every introduce (a bad key, too many peers).
  bool refuseIntroduce = false;

  /// The link is gone: every request throws.
  bool down = false;

  @override
  ValueListenable<Set<String>> get capabilities => _caps;

  @override
  Future<Map<String, dynamic>> hostPeerRequest(
    Map<String, dynamic> frame, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (down) throw StateError('Not paired');
    frames.add(Map<String, dynamic>.of(frame));
    final String type = frame['type'] as String;
    bool ok = true;
    String? error;
    if (type == 'host_peer_introduce') {
      if (refuseIntroduce) {
        ok = false;
        error = 'pair_key is not 32 bytes';
      } else {
        peers[frame['peer_host_id'] as String] = frame['pair_key'] as String;
      }
    } else if (type == 'host_peer_forget') {
      peers.remove(frame['peer_host_id']);
    }
    return <String, dynamic>{
      'type': 'host_peer_list',
      'request': type,
      'ok': ok,
      'error': ?error,
      'host_id': id,
      'peers': <Map<String, Object?>>[
        for (final String p in peers.keys)
          <String, Object?>{'peer_host_id': p, 'online': null},
      ],
    };
  }

  List<Map<String, dynamic>> of(String type) => <Map<String, dynamic>>[
    for (final Map<String, dynamic> f in frames)
      if (f['type'] == type) f,
  ];
}

void main() {
  late SimplePublicKey keyA;
  late SimplePublicKey keyB;
  late SimplePublicKey keyC;

  setUpAll(() async {
    keyA = await (await AgentsDeviceKeys.generate()).extractPublicKey();
    keyB = await (await AgentsDeviceKeys.generate()).extractPublicKey();
    keyC = await (await AgentsDeviceKeys.generate()).extractPublicKey();
  });

  AgentsStoredPairing pairing(
    String device,
    SimplePublicKey key, {
    AgentsHostKind? kind,
    String? name,
  }) => AgentsStoredPairing(
    hostUrl: Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=$device'),
    channelId: 'chan-$device',
    channelKey: Uint8List.fromList(List<int>.filled(32, 7)),
    peerDeviceId: 'cowork-host',
    peerPublicKey: key,
    kind: kind,
    displayName: name,
  );

  late AgentsPairingStore store;
  late _RecordingSync sync;
  late Map<String, _FakeHost> hosts;
  late DateTime clock;

  AgentsHostPeering peering() => AgentsHostPeering(
    store: store,
    controlFor: (String id) {
      final _FakeHost? h = hosts[id];
      return h == null || h.down ? null : h;
    },
    random: Random(42),
    listMaxAge: const Duration(minutes: 2),
    retryAfterFailure: const Duration(minutes: 1),
    now: () => clock,
  );

  setUp(() async {
    sync = _RecordingSync();
    store = AgentsPairingStore(backend: _MemoryStore(), cloudSync: sync);
    hosts = <String, _FakeHost>{};
    clock = DateTime.utc(2026, 11, 22, 12);
  });

  Future<void> pair(
    String id,
    SimplePublicKey key, {
    bool capable = true,
  }) async {
    await store.savePairing(
      pairing(
        id,
        key,
        kind: id == 'box' ? AgentsHostKind.cloud : null,
        name: id == 'box' ? 'Cloud-Computer' : null,
      ),
    );
    hosts[id] = _FakeHost(id, capable: capable);
  }

  test(
    'two computers that name host_peers are introduced with one key',
    () async {
      await pair('pc', keyA);
      await pair('box', keyB);
      final AgentsHostPeering p = peering();
      await p.sync();

      final Map<String, dynamic> toPc = hosts['pc']!
          .of('host_peer_introduce')
          .single;
      final Map<String, dynamic> toBox = hosts['box']!
          .of('host_peer_introduce')
          .single;
      // Each side gets the OTHER computer's id, key, name and kind.
      expect(toPc['peer_host_id'], 'box');
      expect(toPc['peer_public_key'], base64.encode(keyB.bytes));
      expect(toPc['name'], 'Cloud-Computer');
      expect(toPc['kind'], 'cloud');
      expect(toBox['peer_host_id'], 'pc');
      expect(toBox['peer_public_key'], base64.encode(keyA.bytes));
      expect(toBox['name'], 'PC');
      expect(toBox['kind'], 'pc');
      // The same fresh 32-byte key on both sides.
      expect(toPc['pair_key'], toBox['pair_key']);
      expect(base64.decode(toPc['pair_key'] as String), hasLength(32));
      expect(p.linkedCount('pc'), 1);
      expect(p.linkedCount('box'), 1);
      p.dispose();
    },
  );

  test('a linked pair is not introduced again (idempotent)', () async {
    await pair('pc', keyA);
    await pair('box', keyB);
    final AgentsHostPeering p = peering();
    await p.sync();
    await p.sync();
    // Even after the lists went stale and were read again.
    clock = clock.add(const Duration(minutes: 5));
    await p.sync();
    expect(hosts['pc']!.of('host_peer_introduce'), hasLength(1));
    expect(hosts['box']!.of('host_peer_introduce'), hasLength(1));
    expect(hosts['pc']!.of('host_peer_list'), hasLength(2));
    p.dispose();
  });

  test('three computers make three pairs, each with its own key', () async {
    await pair('pc', keyA);
    await pair('box', keyB);
    await pair('lap', keyC);
    final AgentsHostPeering p = peering();
    await p.sync();
    final Set<String> keys = <String>{
      for (final _FakeHost h in hosts.values)
        for (final Map<String, dynamic> f in h.of('host_peer_introduce'))
          f['pair_key'] as String,
    };
    expect(keys, hasLength(3));
    for (final _FakeHost h in hosts.values) {
      expect(h.peers.keys.toSet(), hosts.keys.toSet()..remove(h.id));
    }
    p.dispose();
  });

  test('a computer without host_peers, or offline, is left out', () async {
    await pair('pc', keyA);
    await pair('old', keyB, capable: false);
    await pair('box', keyC);
    hosts['box']!.down = true;
    final AgentsHostPeering p = peering();
    await p.sync();
    for (final _FakeHost h in hosts.values) {
      expect(h.of('host_peer_introduce'), isEmpty);
    }
    expect(hosts['old']!.frames, isEmpty);

    // The cloud computer comes up: now it is introduced to the PC only.
    hosts['box']!.down = false;
    await p.sync();
    expect(hosts['pc']!.peers.keys, <String>['box']);
    expect(hosts['box']!.peers.keys, <String>['pc']);
    expect(hosts['old']!.frames, isEmpty);
    p.dispose();
  });

  test('repair: a computer that lost its peer is introduced again', () async {
    await pair('pc', keyA);
    await pair('box', keyB);
    final AgentsHostPeering p = peering();
    await p.sync();
    // The cloud computer was rebuilt and lost peers.json.
    hosts['box']!.peers.clear();
    clock = clock.add(const Duration(minutes: 3));
    await p.sync();
    expect(hosts['box']!.of('host_peer_introduce'), hasLength(2));
    expect(hosts['pc']!.of('host_peer_introduce'), hasLength(2));
    expect(hosts['pc']!.peers['box'], hosts['box']!.peers['pc']);
    p.dispose();
  });

  test('when the second side refuses, the first side forgets', () async {
    await pair('pc', keyA);
    await pair('box', keyB);
    hosts['box']!.refuseIntroduce = true;
    final AgentsHostPeering p = peering();
    await p.sync();
    expect(hosts['pc']!.of('host_peer_introduce'), hasLength(1));
    expect(hosts['pc']!.of('host_peer_forget').single['peer_host_id'], 'box');
    expect(hosts['pc']!.peers, isEmpty);
    expect(p.linkedCount('pc'), 0);

    // No retry storm: the pair waits, then tries again and links.
    await p.sync();
    expect(hosts['pc']!.of('host_peer_introduce'), hasLength(1));
    hosts['box']!.refuseIntroduce = false;
    clock = clock.add(const Duration(minutes: 2));
    await p.sync();
    expect(hosts['pc']!.peers.keys, <String>['box']);
    expect(hosts['box']!.peers.keys, <String>['pc']);
    p.dispose();
  });

  test('when the first side refuses, the second hears nothing', () async {
    await pair('pc', keyA);
    await pair('box', keyB);
    hosts['pc']!.refuseIntroduce = true;
    final AgentsHostPeering p = peering();
    await p.sync();
    expect(hosts['box']!.of('host_peer_introduce'), isEmpty);
    expect(hosts['box']!.of('host_peer_forget'), isEmpty);
    p.dispose();
  });

  test(
    'unlink: every other computer forgets it, then the pairing goes',
    () async {
      await pair('pc', keyA);
      await pair('box', keyB);
      await pair('lap', keyC);
      final AgentsHostPeering p = peering();
      await p.sync();
      // The laptop is offline when the user removes the cloud computer.
      hosts['lap']!.down = true;
      await p.unlink('box');

      expect(hosts['pc']!.of('host_peer_forget').single['peer_host_id'], 'box');
      expect(hosts['pc']!.peers.containsKey('box'), isFalse);
      expect(await store.loadPairing(hostId: 'box'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(sync.cleared, <String?>['box']);
      expect(p.pendingForgets, <String, Set<String>>{
        'lap': <String>{'box'},
      });

      // The laptop comes back: it gets its forget, and nobody re-introduces
      // the removed computer.
      hosts['lap']!.down = false;
      await p.sync();
      expect(
        hosts['lap']!.of('host_peer_forget').single['peer_host_id'],
        'box',
      );
      expect(hosts['lap']!.peers.containsKey('box'), isFalse);
      expect(p.pendingForgets, isEmpty);
      expect(hosts['box']!.of('host_peer_introduce'), hasLength(2));
      p.dispose();
    },
  );
}
