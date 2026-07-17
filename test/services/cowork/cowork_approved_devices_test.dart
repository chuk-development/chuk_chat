import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/cowork/cowork_approved_devices.dart';
import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';

void main() {
  late SimpleKeyPair keys;
  late SimplePublicKey publicKey;

  setUp(() async {
    keys = await CoworkDeviceKeys.generate();
    publicKey = await keys.extractPublicKey();
  });

  group('device keys', () {
    test('generates distinct Ed25519 key pairs', () async {
      final other = await CoworkDeviceKeys.generate();
      expect((await other.extractPublicKey()).bytes, isNot(publicKey.bytes));
      expect(publicKey.type, KeyPairType.ed25519);
      expect(publicKey.bytes, hasLength(CoworkDeviceKeys.publicKeyLength));
    });

    test(
      'a key pair restored from its seed produces the same public key',
      () async {
        final seed = await CoworkDeviceKeys.exportPrivateKeySeed(keys);
        expect(seed, hasLength(CoworkDeviceKeys.seedLength));

        final restored = await CoworkDeviceKeys.fromSeed(seed);

        expect((await restored.extractPublicKey()).bytes, publicKey.bytes);
      },
    );

    test(
      'a key pair restored from a base64 seed still signs verifiably',
      () async {
        final encoded = await CoworkDeviceKeys.exportPrivateKeySeedBase64(keys);
        final restored = await CoworkDeviceKeys.fromSeedBase64(encoded);

        final message = utf8.encode('frame bytes');
        final signature = await CoworkDeviceKeys.algorithm.sign(
          message,
          keyPair: restored,
        );

        expect(
          await CoworkDeviceKeys.algorithm.verify(
            message,
            signature: Signature(signature.bytes, publicKey: publicKey),
          ),
          isTrue,
        );
      },
    );

    test('a wrong-length seed is rejected', () {
      expect(
        () => CoworkDeviceKeys.fromSeed(Uint8List(16)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('public keys round-trip through base64', () async {
      final encoded = await CoworkDeviceKeys.exportPublicKeyBase64(keys);
      expect(
        CoworkDeviceKeys.publicKeyFromBase64(encoded).bytes,
        publicKey.bytes,
      );
    });

    test('a wrong-length public key is rejected', () {
      // A hostile cowork_devices row must not become a trusted key.
      expect(
        () => CoworkDeviceKeys.publicKeyFromBase64(base64Encode(Uint8List(16))),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-base64 public key is rejected', () {
      expect(
        () => CoworkDeviceKeys.publicKeyFromBase64('not!base64!'),
        throwsA(isA<FormatException>()),
      );
    });

    test('fingerprints are stable, formatted, and key-specific', () async {
      final other = await CoworkDeviceKeys.generate();

      final fingerprint = CoworkDeviceKeys.fingerprint(publicKey);

      expect(
        fingerprint,
        matches(RegExp(r'^([0-9A-F]{4}-){4}[0-9A-F]{4}$')),
      );
      expect(CoworkDeviceKeys.fingerprint(publicKey), fingerprint);
      expect(
        CoworkDeviceKeys.fingerprint(await other.extractPublicKey()),
        isNot(fingerprint),
      );
    });

    test('fingerprints carry at least 80 bits', () {
      // The approve prompt is the trust ceremony: if a compromised backend can
      // grind a different key that *renders the same string*, the user consents
      // to the attacker's key. 32 bits would fall to a trivial search.
      final fingerprint = CoworkDeviceKeys.fingerprint(publicKey);
      final hexDigits = fingerprint.replaceAll('-', '').length;

      expect(CoworkDeviceKeys.fingerprintBytes, greaterThanOrEqualTo(10));
      expect(hexDigits * 4, greaterThanOrEqualTo(80));
    });
  });

  group('approved devices store', () {
    test('starts empty and denies by default', () {
      final store = CoworkApprovedDevices.empty();

      expect(store.isEmpty, isTrue);
      expect(store.lookup('anything'), isNull);
      expect(store.isApproved('anything'), isFalse);
    });

    test('approve then lookup returns the key', () {
      final store = CoworkApprovedDevices.empty()
        ..approve('phone-1', publicKey);

      expect(store.lookup('phone-1')!.bytes, publicKey.bytes);
      expect(store.isApproved('phone-1'), isTrue);
      expect(store.deviceIds, {'phone-1'});
    });

    test('re-approving the same device with the same key is idempotent', () {
      final store = CoworkApprovedDevices.empty()
        ..approve('phone-1', publicKey)
        ..approve('phone-1', publicKey);

      expect(store.length, 1);
    });

    test('re-approving a device with a DIFFERENT key throws', () async {
      // Silently overwriting would make `approve` a key-substitution
      // primitive: anything that could call it could hijack a device id.
      final other = await CoworkDeviceKeys.generate();
      final otherKey = await other.extractPublicKey();
      final store = CoworkApprovedDevices.empty()
        ..approve('phone-1', publicKey);

      expect(
        () => store.approve('phone-1', otherKey),
        throwsA(isA<StateError>()),
      );
      expect(store.lookup('phone-1')!.bytes, publicKey.bytes);
    });

    test('revoke then re-approve with a new key is allowed', () async {
      final other = await CoworkDeviceKeys.generate();
      final newKey = await other.extractPublicKey();
      final store = CoworkApprovedDevices.empty()
        ..approve('phone-1', publicKey);

      expect(store.revoke('phone-1'), isTrue);
      store.approve('phone-1', newKey);

      expect(store.lookup('phone-1')!.bytes, newKey.bytes);
    });

    test('revoke reports whether the device was approved', () {
      final store = CoworkApprovedDevices.empty()
        ..approve('phone-1', publicKey);

      expect(store.revoke('phone-1'), isTrue);
      expect(store.revoke('phone-1'), isFalse);
      expect(store.isEmpty, isTrue);
    });

    test('revokeAll empties the store', () async {
      final other = await CoworkDeviceKeys.generate();
      final store = CoworkApprovedDevices.empty()
        ..approve('phone-1', publicKey)
        ..approve('tablet-1', await other.extractPublicKey());

      store.revokeAll();

      expect(store.isEmpty, isTrue);
    });

    test('an empty device id is rejected', () {
      expect(
        () => CoworkApprovedDevices.empty().approve('', publicKey),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a non-Ed25519 key is rejected', () {
      expect(
        () => CoworkApprovedDevices.empty().approve(
          'phone-1',
          SimplePublicKey(Uint8List(32), type: KeyPairType.x25519),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a wrong-length key is rejected', () {
      expect(
        () => CoworkApprovedDevices.empty().approve(
          'phone-1',
          SimplePublicKey(Uint8List(16), type: KeyPairType.ed25519),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('round-trips through a persistable base64 map', () async {
      final other = await CoworkDeviceKeys.generate();
      final otherKey = await other.extractPublicKey();
      final store = CoworkApprovedDevices.empty()
        ..approve('phone-1', publicKey)
        ..approve('tablet-1', otherKey);

      final restored = CoworkApprovedDevices.fromBase64Map(store.toBase64Map());

      expect(restored.deviceIds, {'phone-1', 'tablet-1'});
      expect(restored.lookup('phone-1')!.bytes, publicKey.bytes);
      expect(restored.lookup('tablet-1')!.bytes, otherKey.bytes);
    });

    test('a corrupt persisted entry throws rather than silently denying', () {
      // Half-loading the trust store would deny a legitimate device with no
      // explanation — fail loudly instead.
      expect(
        () => CoworkApprovedDevices.fromBase64Map({'phone-1': 'not!base64!'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('the constructor copies its input map', () {
      final seed = <String, SimplePublicKey>{'phone-1': publicKey};
      final store = CoworkApprovedDevices(seed);

      seed.clear();

      expect(store.isApproved('phone-1'), isTrue);
    });
  });
}
