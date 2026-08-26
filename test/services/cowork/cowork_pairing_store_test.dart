import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';
import 'package:chuk_chat/services/cowork/cowork_pairing_store.dart';
import 'package:chuk_chat/services/cowork/cowork_reconnect.dart';

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

  test('the default backend is flutter_secure_storage, never SharedPreferences',
      () async {
    // The channel key and the device seed are key material. They must ride the
    // OS keychain / libsecret, so the production store defaults to it. Anything
    // else here would silently downgrade both secrets to plaintext prefs.
    expect(CoworkPairingStore().backend, isA<FlutterSecureKeyValueStore>());
  });

  test('the device identity survives a restart and still authenticates a '
      'reconnect', () async {
    // The whole "pair once, never again" promise rests on this: if the app's
    // long-term Ed25519 key were regenerated on launch, the host's stored trust
    // would no longer match and a code would be needed forever. Prove it end to
    // end — pair in "run 1", restart, and complete the real handshake in "run 2"
    // against the key the host approved in run 1.
    final backend = _MemoryStore();
    const appDeviceId = 'desktop-01';
    const channelId = 'chan0001deadbeef';
    const hostDeviceId = 'cowork-host';

    // --- run 1: first launch, first pairing -------------------------------
    final run1 = CoworkPairingStore(backend: backend);
    final identity1 = await run1.loadOrCreateIdentity();
    // What the host approves and persists on its side.
    final hostKeyPair = await CoworkDeviceKeys.generate();
    final hostPub = await hostKeyPair.extractPublicKey();
    final appPubAtPairing = await identity1.keyPair.extractPublicKey();
    await run1.savePairing(
      CoworkStoredPairing(
        hostUrl: Uri.parse('ws://127.0.0.1:8787'),
        channelId: channelId,
        channelKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
        peerDeviceId: hostDeviceId,
        peerPublicKey: hostPub,
      ),
    );

    // --- run 2: the app is restarted; only the secure store survives -------
    final run2 = CoworkPairingStore(backend: backend);
    final identity2 = await run2.loadOrCreateIdentity();
    final stored = await run2.loadPairing();
    expect(stored, isNotNull);
    expect(identity2.deviceId, identity1.deviceId);

    // The host, holding ONLY what it stored in run 1, challenges the restarted
    // app. This authenticates iff the private key really came back.
    final host = CoworkReconnect.initiator(
      deviceId: hostDeviceId,
      deviceKeyPair: hostKeyPair,
      peerDeviceId: appDeviceId,
      peerPublicKey: appPubAtPairing,
      channelId: channelId,
    );
    final app = CoworkReconnect.joiner(
      deviceId: appDeviceId,
      deviceKeyPair: identity2.keyPair,
      peerDeviceId: hostDeviceId,
      peerPublicKey: stored!.peerPublicKey,
      channelId: stored.channelId,
    );
    await app.onConfirm(await host.onResponse(await app.onHello(host.createHello())));
    expect(host.authenticated, isTrue, reason: 'host must still trust this app');
    expect(app.authenticated, isTrue, reason: 'app must still trust this host');

    // A fresh key would have failed the same challenge.
    final reinstalled = CoworkPairingStore(backend: _MemoryStore());
    final otherIdentity = await reinstalled.loadOrCreateIdentity();
    final host2 = CoworkReconnect.initiator(
      deviceId: hostDeviceId,
      deviceKeyPair: hostKeyPair,
      peerDeviceId: appDeviceId,
      peerPublicKey: appPubAtPairing,
      channelId: channelId,
    );
    final imposter = CoworkReconnect.joiner(
      deviceId: appDeviceId,
      deviceKeyPair: otherIdentity.keyPair,
      peerDeviceId: hostDeviceId,
      peerPublicKey: hostPub,
      channelId: channelId,
    );
    await expectLater(
      host2.onResponse(await imposter.onHello(host2.createHello())),
      throwsA(isA<CoworkReconnectException>()),
    );
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
