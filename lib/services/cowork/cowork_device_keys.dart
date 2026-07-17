import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Per-device Ed25519 identity helpers.
///
/// Each device generates one long-lived signing key at first launch and signs
/// every frame it sends with it. Per-device keys — rather than one shared
/// account key doing double duty — are what make revocation real: pulling one
/// device's public key out of the executor's local approved set instantly and
/// permanently stops that device, with no server cooperation required.
///
/// This class is pure: it generates, serialises and fingerprints keys. Where
/// the private key is persisted (`FlutterSecureStorage` / the
/// `_usePrefsBackend` fallback) and where public keys are distributed (the
/// `cowork_devices` table) are deliberately somebody else's problem.
class CoworkDeviceKeys {
  const CoworkDeviceKeys._();

  static final Ed25519 _algorithm = Ed25519();

  /// Ed25519 seed length in bytes — what [exportPrivateKeySeed] returns.
  static const int seedLength = 32;

  /// Ed25519 public key length in bytes.
  static const int publicKeyLength = 32;

  static Ed25519 get algorithm => _algorithm;

  /// Generates a fresh device signing key from the platform's secure RNG.
  static Future<SimpleKeyPair> generate() => _algorithm.newKeyPair();

  /// Rebuilds a key pair from a stored 32-byte seed.
  static Future<SimpleKeyPair> fromSeed(List<int> seed) {
    if (seed.length != seedLength) {
      throw ArgumentError.value(
        seed.length,
        'seed',
        'Ed25519 seed must be $seedLength bytes',
      );
    }
    return _algorithm.newKeyPairFromSeed(seed);
  }

  /// Rebuilds a key pair from a base64 seed as written by
  /// [exportPrivateKeySeedBase64].
  static Future<SimpleKeyPair> fromSeedBase64(String seed) =>
      fromSeed(_decodeBase64(seed, 'seed'));

  /// The private seed. Persist this in secure storage and nowhere else — it
  /// must never be logged, synced, or sent to the relay.
  static Future<Uint8List> exportPrivateKeySeed(SimpleKeyPair keyPair) async =>
      Uint8List.fromList(await keyPair.extractPrivateKeyBytes());

  static Future<String> exportPrivateKeySeedBase64(
    SimpleKeyPair keyPair,
  ) async => base64Encode(await exportPrivateKeySeed(keyPair));

  /// The public key, safe to publish to `cowork_devices`.
  static Future<String> exportPublicKeyBase64(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Parses a peer public key received from `cowork_devices`.
  ///
  /// Throws [FormatException] on anything that is not a 32-byte base64 Ed25519
  /// key, so a malformed or hostile row cannot become a trusted key.
  static SimplePublicKey publicKeyFromBase64(String encoded) {
    final bytes = _decodeBase64(encoded, 'public key');
    if (bytes.length != publicKeyLength) {
      throw FormatException(
        'Ed25519 public key must be $publicKeyLength bytes, got ${bytes.length}',
      );
    }
    return SimplePublicKey(bytes, type: KeyPairType.ed25519);
  }

  /// Bytes of the SHA-256 digest shown in a [fingerprint].
  ///
  /// 10 bytes = 80 bits. This is a security parameter, not a cosmetic one: the
  /// fingerprint is what the user actually consents to on the approve prompt,
  /// so it must be infeasible for a compromised backend to grind a substitute
  /// key that *displays the same string*. A 32-bit fingerprint falls to a
  /// ~2^32 search on a laptop; 80 bits needs ~2^40 work for a second preimage
  /// even under a birthday-style attack, which is out of reach for the threat
  /// this ceremony exists to stop.
  static const int fingerprintBytes = 10;

  /// A human-comparable fingerprint of a public key, e.g. `4F2A-9C31-88B0-1D5E-A7C4`.
  ///
  /// Shown on the desktop's approve prompt so the user is consenting to a
  /// specific key rather than to whatever the server claims is on the wire.
  static String fingerprint(SimplePublicKey publicKey) {
    final digest = crypto.sha256.convert(publicKey.bytes).bytes;
    final hex = digest
        .take(fingerprintBytes)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    return RegExp(
      r'.{4}',
    ).allMatches(hex).map((match) => match.group(0)!).join('-');
  }

  static Uint8List _decodeBase64(String value, String label) {
    try {
      return base64Decode(value);
    } on FormatException {
      throw FormatException('Invalid base64 $label');
    }
  }
}
