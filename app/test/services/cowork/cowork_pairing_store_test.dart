import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';

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

void main() {
  test('loadOrCreateIdentity persists a STABLE device id + key across calls',
      () async {
    final backend = _MemoryStore();
    final store = CoworkPairingStore(backend: backend);

    final first = await store.loadOrCreateIdentity();
    final second = await store.loadOrCreateIdentity();

    expect(second.deviceId, first.deviceId, reason: 'device id must be stable');
    final firstSeed = await CoworkDeviceKeys.exportPrivateKeySeedBase64(first.keyPair);
    final secondSeed =
        await CoworkDeviceKeys.exportPrivateKeySeedBase64(second.keyPair);
    expect(secondSeed, firstSeed, reason: 'signing key must be stable');

    // A brand-new store over the same backend rebuilds the same identity.
    final reopened =
        await CoworkPairingStore(backend: backend).loadOrCreateIdentity();
    expect(reopened.deviceId, first.deviceId);
  });

  test('savePairing / loadPairing round-trips every field', () async {
    final store = CoworkPairingStore(backend: _MemoryStore());
    final hostKey = await CoworkDeviceKeys.generate();
    final hostPub = await hostKey.extractPublicKey();
    final channelKey =
        Uint8List.fromList(List<int>.generate(32, (i) => (i * 7) & 0xff));

    final pairing = CoworkStoredPairing(
      hostUrl: Uri.parse('ws://192.168.0.5:8787'),
      channelId: 'cowork00deadbeef',
      channelKey: channelKey,
      peerDeviceId: 'cowork-host',
      peerPublicKey: hostPub,
    );
    await store.savePairing(pairing);

    final loaded = await store.loadPairing();
    expect(loaded, isNotNull);
    expect(loaded!.hostUrl.toString(), 'ws://192.168.0.5:8787');
    expect(loaded.channelId, 'cowork00deadbeef');
    expect(loaded.channelKey, channelKey);
    expect(loaded.peerDeviceId, 'cowork-host');
    expect(loaded.peerPublicKey.bytes, hostPub.bytes);
  });

  test('clearPairing forgets the trust but keeps the device identity', () async {
    final backend = _MemoryStore();
    final store = CoworkPairingStore(backend: backend);
    final identity = await store.loadOrCreateIdentity();
    final hostPub = await (await CoworkDeviceKeys.generate()).extractPublicKey();

    await store.savePairing(
      CoworkStoredPairing(
        hostUrl: Uri.parse('ws://127.0.0.1:8787'),
        channelId: 'chan',
        channelKey: Uint8List(32),
        peerDeviceId: 'host',
        peerPublicKey: hostPub,
      ),
    );
    expect(await store.loadPairing(), isNotNull);

    await store.clearPairing();
    expect(await store.loadPairing(), isNull);
    // The stable identity is untouched.
    final again = await store.loadOrCreateIdentity();
    expect(again.deviceId, identity.deviceId);
  });

  test('a corrupt or future-version record parses as no pairing', () async {
    expect(CoworkStoredPairing.tryParse('not json'), isNull);
    expect(CoworkStoredPairing.tryParse('{"version":2}'), isNull);
    expect(
      CoworkStoredPairing.tryParse(
        '{"version":1,"host_url":"ws://h","channel_id":"c",'
        '"channel_key_b64":"AAAA","peer":{"device_id":"h",'
        '"ed25519_pub_b64":"AAAA"}}',
      ),
      isNull,
      reason: 'a 3-byte channel key is not 32 bytes',
    );
  });
}
