/// Persistent Agents trust — the app side of "pair once, reconnect forever".
///
/// After the first §15 pairing the app persists two things so it never needs the
/// code again:
///
///  * its own **stable** long-term Ed25519 device identity (seed + device id).
///    Today the relay client makes an ephemeral key per instance; the host
///    approves that key at pairing, so it must survive restarts or the host's
///    stored trust would no longer match.
///  * a **trust record**: the host URL, the stable `channel_id`, the established
///    channel key, and the host's `device_id` + approved Ed25519 public key.
///
/// Everything lives in `flutter_secure_storage`. The seed and channel key are
/// key material, so they never leave secure storage. The backend is injectable
/// ([AgentsSecureKeyValueStore]) so tests run against an in-memory map with no
/// platform channel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';

/// The minimal secure key/value surface the store needs. Backed by
/// `flutter_secure_storage` in production, an in-memory map in tests.
abstract interface class AgentsSecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production backend over `flutter_secure_storage`.
class FlutterSecureKeyValueStore implements AgentsSecureKeyValueStore {
  const FlutterSecureKeyValueStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The app's stable long-term device identity.
class AgentsDeviceIdentity {
  const AgentsDeviceIdentity({required this.deviceId, required this.keyPair});

  /// A stable, opaque id the host approves at pairing and sees on every frame.
  final String deviceId;

  /// The long-term Ed25519 signing key pair.
  final SimpleKeyPair keyPair;
}

/// A persisted pairing: everything the app needs to reconnect with no code.
class AgentsStoredPairing {
  const AgentsStoredPairing({
    required this.hostUrl,
    required this.channelId,
    required this.channelKey,
    required this.peerDeviceId,
    required this.peerPublicKey,
  });

  /// Where the host was reached (`ws://…`). Auto-reconnect dials this.
  final Uri hostUrl;

  /// The stable relay channel the host listens on.
  final String channelId;

  /// The established 32-byte channel key, reused verbatim by the frame codec.
  final Uint8List channelKey;

  /// The host's `device_id`.
  final String peerDeviceId;

  /// The host's approved long-term Ed25519 public key.
  final SimplePublicKey peerPublicKey;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'host_url': hostUrl.toString(),
    'channel_id': channelId,
    'channel_key_b64': base64.encode(channelKey),
    'peer': <String, dynamic>{
      'device_id': peerDeviceId,
      'ed25519_pub_b64': base64.encode(peerPublicKey.bytes),
    },
  };

  /// Parses a stored record, or returns null if it is malformed / a future
  /// version — the caller then falls back to a fresh pairing rather than
  /// crashing on a corrupt entry.
  static AgentsStoredPairing? tryParse(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != 1) return null;
      final hostUrl = Uri.parse(decoded['host_url'] as String);
      final channelId = decoded['channel_id'] as String;
      final channelKey = base64.decode(decoded['channel_key_b64'] as String);
      if (channelKey.length != 32) return null;
      final peer = decoded['peer'] as Map<String, dynamic>;
      final peerDeviceId = peer['device_id'] as String;
      if (channelId.isEmpty || peerDeviceId.isEmpty) return null;
      final peerPublicKey = AgentsDeviceKeys.publicKeyFromBase64(
        peer['ed25519_pub_b64'] as String,
      );
      return AgentsStoredPairing(
        hostUrl: hostUrl,
        channelId: channelId,
        channelKey: Uint8List.fromList(channelKey),
        peerDeviceId: peerDeviceId,
        peerPublicKey: peerPublicKey,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Loads and saves the app's stable identity and single trust record.
class AgentsPairingStore {
  AgentsPairingStore({
    AgentsSecureKeyValueStore? backend,
    Uuid? uuid,
    SupabasePairingSync? cloudSync,
  }) : _store = backend ?? const FlutterSecureKeyValueStore(),
       _uuid = uuid ?? const Uuid(),
       _cloudSync = cloudSync ?? const SupabasePairingSync();

  static const String _kDeviceId = 'cowork_device_id';
  static const String _kDeviceSeed = 'cowork_device_seed';
  static const String _kPairing = 'cowork_pairing';

  final AgentsSecureKeyValueStore _store;
  final Uuid _uuid;

  /// Encrypted Supabase mirror. Every local [savePairing] is also pushed here
  /// (best-effort) so a reinstall on a new device can pull the trust record
  /// back after sign-in. Injectable for tests.
  final SupabasePairingSync _cloudSync;

  /// The backend everything is written to. Exposed so a test can assert that the
  /// production default really is the OS keychain / libsecret — both the device
  /// seed and the channel key are key material, and must never fall back to
  /// SharedPreferences.
  AgentsSecureKeyValueStore get backend => _store;

  /// Loads the stable device identity, creating and persisting a fresh one on
  /// first use. The same identity is returned on every later launch.
  Future<AgentsDeviceIdentity> loadOrCreateIdentity() async {
    final storedId = await _store.read(_kDeviceId);
    final storedSeed = await _store.read(_kDeviceSeed);
    if (storedId != null && storedSeed != null) {
      final keyPair = await AgentsDeviceKeys.fromSeedBase64(storedSeed);
      return AgentsDeviceIdentity(deviceId: storedId, keyPair: keyPair);
    }
    final keyPair = await AgentsDeviceKeys.generate();
    final seed = await AgentsDeviceKeys.exportPrivateKeySeedBase64(keyPair);
    final deviceId = _uuid.v4();
    await _store.write(_kDeviceSeed, seed);
    await _store.write(_kDeviceId, deviceId);
    return AgentsDeviceIdentity(deviceId: deviceId, keyPair: keyPair);
  }

  /// The stored trust record, or null when the app has never paired (or the
  /// record was forgotten / is corrupt).
  Future<AgentsStoredPairing?> loadPairing() async {
    final raw = await _store.read(_kPairing);
    if (raw == null) return null;
    return AgentsStoredPairing.tryParse(raw);
  }

  /// Persists the trust record after a successful pairing, then mirrors it to
  /// the encrypted Supabase copy so a reinstall elsewhere can reconnect.
  ///
  /// The local write is authoritative and is awaited first; the cloud mirror is
  /// best-effort and fire-and-forget, so an offline client still pairs and the
  /// caller never waits on the network.
  Future<void> savePairing(AgentsStoredPairing pairing) async {
    await _store.write(_kPairing, jsonEncode(pairing.toJson()));
    // A local address cannot be restored on another device. Wait for the
    // authenticated host_route announcement before publishing the capability.
    if (pairing.hostUrl.path == '/v2/relay/ws' &&
        pairing.hostUrl.queryParameters['cw_device'] != null &&
        pairing.hostUrl.queryParameters['cw_device'] != 'cowork-host') {
      unawaited(_cloudSync.saveEncryptedPairing(pairing));
    }
  }

  /// Loads the trust record from the encrypted Supabase mirror. Returns null
  /// when nothing is stored, no user is signed in, or decryption fails. Used on
  /// a fresh install to recover pairing that no local store has yet.
  Future<AgentsStoredPairing?> loadPairingFromCloud() =>
      _cloudSync.loadEncryptedPairing();

  Future<bool> publishPairing(AgentsStoredPairing pairing) =>
      _cloudSync.publishEncryptedPairing(pairing);

  /// Deletes the trust record — the "un-pair / forget" action. The stable device
  /// identity is kept, so a later fresh pairing reuses the same device key. The
  /// encrypted Supabase mirror is cleared too (best-effort).
  Future<void> clearPairing() async {
    await _store.delete(_kPairing);
    unawaited(_cloudSync.clearEncryptedPairing());
  }
}
