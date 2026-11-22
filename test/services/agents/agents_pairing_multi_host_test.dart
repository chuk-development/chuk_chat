// CHAT-177: several computers per account. The store keeps one trust record
// per host id, moves the old single record over once, and the encrypted
// Supabase mirror keeps one row per (user, host).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
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

/// An in-memory `cowork_pairings` table with the multi-host primary key.
/// "Encryption" is a reversible marker, so a test can see what was sealed;
/// a ciphertext that does not carry it does not open.
class _FakeCloud extends AgentsPairingCloud {
  String? userId = 'user-1';
  bool keyUnlocked = true;

  /// `(user, host) -> ciphertext`.
  final Map<(String, String), String> rows = <(String, String), String>{};
  final List<String> deletes = <String>[];

  @override
  String? currentUserId() => userId;

  @override
  Future<bool> ensureKey() async => keyUnlocked;

  @override
  Future<String> encrypt(String plaintext) async =>
      'sealed:${base64.encode(utf8.encode(plaintext))}';

  @override
  Future<String> decrypt(String ciphertext) async {
    if (!ciphertext.startsWith('sealed:')) {
      throw StateError('wrong key');
    }
    return utf8.decode(base64.decode(ciphertext.substring(7)));
  }

  @override
  Future<List<AgentsPairingRow>> selectAll(String userId) async =>
      <AgentsPairingRow>[
        for (final MapEntry<(String, String), String> e in rows.entries)
          if (e.key.$1 == userId)
            AgentsPairingRow(hostId: e.key.$2, ciphertext: e.value),
      ];

  @override
  Future<void> upsert(String userId, String hostId, String ciphertext) async {
    rows[(userId, hostId)] = ciphertext;
  }

  @override
  Future<void> delete(String userId, {String? hostId}) async {
    deletes.add(hostId ?? '*');
    rows.removeWhere(
      ((String, String) k, String _) =>
          k.$1 == userId && (hostId == null || k.$2 == hostId),
    );
  }

  /// What the row of [hostId] holds, decrypted and parsed.
  Future<AgentsStoredPairing?> record(String hostId) async {
    final String? c = rows[(userId!, hostId)];
    if (c == null) return null;
    return AgentsStoredPairing.tryParse(await decrypt(c));
  }
}

/// Records what the store mirrors, without a table.
class _RecordingSync extends SupabasePairingSync {
  final List<String> saved = <String>[];
  final List<String?> cleared = <String?>[];

  @override
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {
    saved.add(pairing.hostId);
  }

  @override
  Future<void> clearEncryptedPairing({String? hostId}) async {
    cleared.add(hostId);
  }
}

void main() {
  late SimplePublicKey hostKey;

  setUpAll(() async {
    hostKey = await (await AgentsDeviceKeys.generate()).extractPublicKey();
  });

  AgentsStoredPairing pairing(
    String device, {
    String? channel,
    String? url,
    AgentsHostKind? kind,
    String? name,
  }) => AgentsStoredPairing(
    hostUrl: Uri.parse(
      url ?? 'wss://api.chuk.chat/v2/relay/ws?cw_device=$device',
    ),
    channelId: channel ?? 'chan-$device',
    channelKey: Uint8List.fromList(List<int>.filled(32, device.length)),
    peerDeviceId: 'cowork-host',
    peerPublicKey: hostKey,
    kind: kind,
    displayName: name,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('AgentsStoredPairing', () {
    test('the host id is the relay device id, else the channel', () {
      expect(pairing('pc-uuid').hostId, 'pc-uuid');
      expect(
        pairing('x', url: 'ws://127.0.0.1:8787', channel: 'c1').hostId,
        'local:c1',
      );
      expect(
        pairing(
          'x',
          url: 'wss://api.chuk.chat/v2/relay/ws?cw_device=cowork-host',
          channel: 'c2',
        ).hostId,
        'local:c2',
      );
    });

    test('name, kind and the legacy mark survive the JSON round trip', () {
      final AgentsStoredPairing p = pairing(
        'box',
        kind: AgentsHostKind.cloud,
        name: 'Cloud-Computer',
      ).asLegacy();
      final AgentsStoredPairing back = AgentsStoredPairing.tryParse(
        jsonEncode(p.toJson()),
      )!;
      expect(back.kind, AgentsHostKind.cloud);
      expect(back.displayName, 'Cloud-Computer');
      expect(back.legacyHostAgent, isTrue);
      expect(back.label, 'Cloud-Computer');
    });

    test('the label falls back to the kind', () {
      expect(pairing('a').label, 'PC');
      expect(pairing('b', kind: AgentsHostKind.cloud).label, 'Cloud');
    });

    test('only the legacy computer keeps the plain host agent id', () {
      expect(pairing('pc').asLegacy().hostAgentId(), 'host:cowork-host');
      expect(pairing('box').hostAgentId(), 'host:cowork-host@box');
    });
  });

  group('AgentsPairingStore', () {
    late _MemoryStore backend;
    late _RecordingSync sync;
    late AgentsPairingStore store;

    setUp(() {
      backend = _MemoryStore();
      sync = _RecordingSync();
      store = AgentsPairingStore(backend: backend, cloudSync: sync);
    });

    test('the old single record moves into the list once', () async {
      backend.map['cowork_pairing'] = jsonEncode(pairing('pc').toJson());

      final List<AgentsStoredPairing> list = await store.listPairings();

      expect(list.map((AgentsStoredPairing p) => p.hostId), <String>['pc']);
      // The computer from before CHAT-177 keeps its agent id.
      expect(list.single.legacyHostAgent, isTrue);
      expect(backend.map.containsKey('cowork_pairing'), isFalse);
      expect(backend.map.containsKey('cowork_pairings_v2'), isTrue);
      // A second read takes the new key and does not migrate again.
      backend.map['cowork_pairing'] = jsonEncode(pairing('other').toJson());
      expect((await store.listPairings()).single.hostId, 'pc');
    });

    test('a corrupt old record migrates to an empty list', () async {
      backend.map['cowork_pairing'] = '{nope';
      expect(await store.listPairings(), isEmpty);
      expect(await store.loadPairing(), isNull);
      expect(backend.map.containsKey('cowork_pairing'), isFalse);
    });

    test('two computers live side by side, keyed by host id', () async {
      await store.savePairing(pairing('pc'));
      await store.savePairing(pairing('box', kind: AgentsHostKind.cloud));

      final List<AgentsStoredPairing> list = await store.listPairings();
      expect(list.map((AgentsStoredPairing p) => p.hostId), <String>[
        'pc',
        'box',
      ]);
      expect(
        (await store.loadPairing(hostId: 'box'))!.kind,
        AgentsHostKind.cloud,
      );
      // Each one is mirrored under its own host id.
      await settle();
      expect(sync.saved, <String>['pc', 'box']);
    });

    test('saving the same host again replaces it', () async {
      await store.savePairing(pairing('pc'));
      await store.savePairing(pairing('pc'));
      expect(await store.listPairings(), hasLength(1));
    });

    test('the computer used last is the default', () async {
      await store.savePairing(pairing('pc'));
      await store.savePairing(pairing('box'));
      expect((await store.loadPairing())!.hostId, 'pc');

      await store.markUsed('box');
      expect((await store.loadPairing())!.hostId, 'box');
      expect(await store.lastUsedHostId(), 'box');

      // An unknown host is not remembered.
      await store.markUsed('ghost');
      expect(await store.lastUsedHostId(), 'box');
    });

    test(
      'a loopback record is replaced by its relay route, name kept',
      () async {
        await store.savePairing(
          pairing('x', url: 'ws://127.0.0.1:8787', channel: 'chan-pc'),
        );
        await store.renamePairing('local:chan-pc', 'Desk');
        final AgentsStoredPairing loopback = (await store.loadPairing())!;

        // The host announced its cloud route (host_route): same channel.
        await store.savePairing(pairing('pc', channel: 'chan-pc'));

        final List<AgentsStoredPairing> list = await store.listPairings();
        expect(list.single.hostId, 'pc');
        expect(list.single.displayName, 'Desk');
        expect((await store.reloadPairing(loopback))!.hostId, 'pc');
        // The loopback record was never mirrored; the relay one is.
        await settle();
        expect(sync.saved, <String>['pc']);
      },
    );

    test('rename and kind are stored and mirrored', () async {
      await store.savePairing(pairing('box'));
      expect(await store.renamePairing('box', '  Big box '), isTrue);
      await store.setHostKind('box', AgentsHostKind.cloud);

      final AgentsStoredPairing box = (await store.loadPairing(hostId: 'box'))!;
      expect(box.displayName, 'Big box');
      expect(box.kind, AgentsHostKind.cloud);

      await store.renamePairing('box', '');
      expect((await store.loadPairing(hostId: 'box'))!.displayName, isNull);
      expect(await store.renamePairing('ghost', 'x'), isFalse);
      await settle();
      expect(sync.saved, everyElement('box'));
    });

    test('remove takes one computer and its mirrored row', () async {
      await store.savePairing(pairing('pc'));
      await store.savePairing(pairing('box'));
      await store.markUsed('box');

      await store.removePairing('box');
      await settle();

      expect((await store.listPairings()).single.hostId, 'pc');
      expect((await store.loadPairing())!.hostId, 'pc');
      expect(sync.cleared, <String?>['box']);
    });

    test(
      'clear forgets every computer but keeps the device identity',
      () async {
        final AgentsDeviceIdentity identity = await store
            .loadOrCreateIdentity();
        await store.savePairing(pairing('pc'));
        await store.savePairing(pairing('box'));

        await store.clear();
        await settle();

        expect(await store.listPairings(), isEmpty);
        expect(sync.cleared, <String?>[null]);
        expect(
          (await store.loadOrCreateIdentity()).deviceId,
          identity.deviceId,
        );
      },
    );

    test('every write rings the change signal', () async {
      var pings = 0;
      void count() => pings++;
      store.changes.addListener(count);
      addTearDown(() => store.changes.removeListener(count));

      await store.savePairing(pairing('pc'));
      await store.renamePairing('pc', 'Desk');
      await store.removePairing('pc');

      expect(pings, 3);
    });

    test('two saves at once both land', () async {
      await Future.wait(<Future<void>>[
        store.savePairing(pairing('a')),
        store.savePairing(pairing('b')),
        store.savePairing(pairing('c')),
      ]);
      expect(await store.listPairings(), hasLength(3));
    });
  });

  group('SupabasePairingSync, one row per computer', () {
    late _FakeCloud cloud;
    late SupabasePairingSync sync;

    setUp(() {
      cloud = _FakeCloud();
      sync = SupabasePairingSync(cloud: cloud);
    });

    test('each computer gets its own row and they all read back', () async {
      expect(await sync.publishEncryptedPairing(pairing('pc')), isTrue);
      expect(
        await sync.publishEncryptedPairing(
          pairing('box', kind: AgentsHostKind.cloud),
        ),
        isTrue,
      );
      // The same computer again replaces its row.
      expect(await sync.publishEncryptedPairing(pairing('pc')), isTrue);

      expect(
        cloud.rows.keys,
        unorderedEquals(<(String, String)>[
          ('user-1', 'pc'),
          ('user-1', 'box'),
        ]),
      );
      // Only ciphertext is stored.
      expect(cloud.rows.values, everyElement(startsWith('sealed:')));

      final AgentsCloudPairingsRead read = await sync.readEncryptedPairings();
      expect(read.outcome, AgentsCloudPairingOutcome.found);
      expect(
        read.pairings.map((AgentsStoredPairing p) => p.hostId),
        unorderedEquals(<String>['pc', 'box']),
      );
    });

    test('a loopback record is never mirrored', () async {
      expect(
        await sync.publishEncryptedPairing(
          pairing('x', url: 'ws://127.0.0.1:8787'),
        ),
        isFalse,
      );
      expect(cloud.rows, isEmpty);
    });

    test('clear deletes one host, or every row without one', () async {
      await sync.publishEncryptedPairing(pairing('pc'));
      await sync.publishEncryptedPairing(pairing('box'));

      await sync.clearEncryptedPairing(hostId: 'box');
      expect(cloud.rows.keys, <(String, String)>[('user-1', 'pc')]);

      await sync.clearEncryptedPairing();
      expect(cloud.rows, isEmpty);
    });

    test('a legacy row is re-keyed to its real host id', () async {
      // What the migration left: the old row under host id `legacy`.
      cloud.rows[('user-1', 'legacy')] = await cloud.encrypt(
        jsonEncode(pairing('pc').toJson()),
      );

      final AgentsCloudPairingsRead read = await sync.readEncryptedPairings();
      expect(read.pairings.single.hostId, 'pc');
      // It is the account's first computer on every device.
      expect(read.pairings.single.legacyHostAgent, isTrue);

      await settle();
      await settle();
      expect(cloud.rows.keys, <(String, String)>[('user-1', 'pc')]);
      expect((await cloud.record('pc'))!.legacyHostAgent, isTrue);
    });

    test('a real row and its legacy copy fold into one record', () async {
      cloud.rows[('user-1', 'legacy')] = await cloud.encrypt(
        jsonEncode(pairing('pc').toJson()),
      );
      cloud.rows[('user-1', 'pc')] = await cloud.encrypt(
        jsonEncode(pairing('pc', name: 'Desk').toJson()),
      );

      final AgentsCloudPairingsRead read = await sync.readEncryptedPairings();
      expect(read.pairings, hasLength(1));
      expect(read.pairings.single.displayName, 'Desk');
      expect(read.pairings.single.legacyHostAgent, isTrue);
    });

    test('rows that do not open are skipped, the others still come', () async {
      await sync.publishEncryptedPairing(pairing('pc'));
      cloud.rows[('user-1', 'foreign')] = 'garbage';

      final AgentsCloudPairingsRead read = await sync.readEncryptedPairings();
      expect(read.outcome, AgentsCloudPairingOutcome.found);
      expect(read.pairings.single.hostId, 'pc');
    });

    test('the reasons when nothing comes back', () async {
      expect(
        (await sync.readEncryptedPairings()).outcome,
        AgentsCloudPairingOutcome.noRecord,
      );

      cloud.rows[('user-1', 'x')] = 'garbage';
      expect(
        (await sync.readEncryptedPairings()).outcome,
        AgentsCloudPairingOutcome.decryptFailed,
      );

      cloud.keyUnlocked = false;
      expect(
        (await sync.readEncryptedPairings()).outcome,
        AgentsCloudPairingOutcome.keyLocked,
      );

      cloud.userId = null;
      expect(
        (await sync.readEncryptedPairings()).outcome,
        AgentsCloudPairingOutcome.noSession,
      );
      expect(await sync.publishEncryptedPairing(pairing('pc')), isFalse);
    });

    test('the store and the mirror together restore both computers', () async {
      final AgentsPairingStore a = AgentsPairingStore(
        backend: _MemoryStore(),
        cloudSync: sync,
      );
      await a.savePairing(pairing('pc'));
      await a.savePairing(pairing('box', kind: AgentsHostKind.cloud));
      await settle();

      final AgentsPairingStore fresh = AgentsPairingStore(
        backend: _MemoryStore(),
        cloudSync: sync,
      );
      final List<AgentsStoredPairing> restored = await fresh
          .loadPairingsFromCloud();
      expect(
        restored.map((AgentsStoredPairing p) => p.hostId),
        unorderedEquals(<String>['pc', 'box']),
      );
    });
  });
}
