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
import 'package:flutter/foundation.dart' show ChangeNotifier, Listenable;
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

/// What kind of computer a host is. Shown as a short label ("PC" / "Cloud")
/// when more than one host is paired.
enum AgentsHostKind {
  /// The user's own computer.
  pc,

  /// The cloud computer the app set up (CHAT-164).
  cloud;

  static AgentsHostKind? tryParse(Object? value) => switch (value) {
    'pc' => AgentsHostKind.pc,
    'cloud' => AgentsHostKind.cloud,
    _ => null,
  };
}

/// A persisted pairing: everything the app needs to reconnect with no code.
class AgentsStoredPairing {
  const AgentsStoredPairing({
    required this.hostUrl,
    required this.channelId,
    required this.channelKey,
    required this.peerDeviceId,
    required this.peerPublicKey,
    this.displayName,
    this.kind,
    this.legacyHostAgent = false,
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

  /// The name the user gave this computer, or null for the default
  /// ([AgentsStoredPairing.label]).
  final String? displayName;

  /// What kind of computer this is, or null when nobody said (an old record):
  /// then it counts as a PC.
  final AgentsHostKind? kind;

  /// True for the computer the app had before CHAT-177 (the old single
  /// record, or a mirrored row with host id `legacy`). Its own agent keeps
  /// the old id `host:<peerDeviceId>`, so its conversation stays where it
  /// was; every later computer's agent gets an id with its host id in it
  /// ([hostAgentId]). The flag rides in the encrypted record, so every
  /// device of the account picks the same ids.
  final bool legacyHostAgent;

  /// The roster id of this computer's own agent. Every host signs as the
  /// same peer id, so only the [legacyHostAgent] computer may use the plain
  /// `host:<peer>` id.
  String hostAgentId([String? peer]) {
    final String id = 'host:${peer ?? peerDeviceId}';
    return legacyHostAgent ? id : '$id@$hostId';
  }

  /// The prefix of a host id for a record that has no relay device id yet
  /// (a same-machine `ws://` address, or the old `cowork-host` placeholder).
  static const String localHostPrefix = 'local:';

  /// The host's identity in the app: its relay device id (the uuid4 in
  /// `cw_device`). A record without one (a loopback address during local
  /// development, before the host announced its cloud route) is keyed by its
  /// channel instead, which is stable per host.
  String get hostId => relayDeviceId ?? '$localHostPrefix$channelId';

  /// The relay device id in [hostUrl], or null when the address has none.
  String? get relayDeviceId {
    if (hostUrl.path != '/v2/relay/ws') return null;
    final String? device = hostUrl.queryParameters['cw_device'];
    if (device == null || device.isEmpty || device == 'cowork-host') {
      return null;
    }
    return device;
  }

  /// The kind, with an old record counted as a PC.
  AgentsHostKind get effectiveKind => kind ?? AgentsHostKind.pc;

  /// What the app calls this computer: the user's name for it, or "Cloud" /
  /// "PC" by kind.
  String get label {
    final String? name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return effectiveKind == AgentsHostKind.cloud ? 'Cloud' : 'PC';
  }

  AgentsStoredPairing copyWith({
    Uri? hostUrl,
    String? displayName,
    AgentsHostKind? kind,
    bool clearDisplayName = false,
  }) => AgentsStoredPairing(
    hostUrl: hostUrl ?? this.hostUrl,
    channelId: channelId,
    channelKey: channelKey,
    peerDeviceId: peerDeviceId,
    peerPublicKey: peerPublicKey,
    displayName: clearDisplayName ? null : (displayName ?? this.displayName),
    kind: kind ?? this.kind,
    legacyHostAgent: legacyHostAgent,
  );

  /// This record marked as the computer from before CHAT-177.
  AgentsStoredPairing asLegacy() => legacyHostAgent
      ? this
      : AgentsStoredPairing(
          hostUrl: hostUrl,
          channelId: channelId,
          channelKey: channelKey,
          peerDeviceId: peerDeviceId,
          peerPublicKey: peerPublicKey,
          displayName: displayName,
          kind: kind,
          legacyHostAgent: true,
        );

  /// This record with the name and kind of [older] where it has none. A trust
  /// update from the host (a new route) knows nothing about either.
  AgentsStoredPairing inheritInfo(AgentsStoredPairing? older) {
    if (older == null) return this;
    return AgentsStoredPairing(
      hostUrl: hostUrl,
      channelId: channelId,
      channelKey: channelKey,
      peerDeviceId: peerDeviceId,
      peerPublicKey: peerPublicKey,
      displayName: displayName ?? older.displayName,
      kind: kind ?? older.kind,
      legacyHostAgent: legacyHostAgent || older.legacyHostAgent,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'host_url': hostUrl.toString(),
    'channel_id': channelId,
    'channel_key_b64': base64.encode(channelKey),
    'peer': <String, dynamic>{
      'device_id': peerDeviceId,
      'ed25519_pub_b64': base64.encode(peerPublicKey.bytes),
    },
    // Optional and additive: an older app reads the record and ignores them.
    'name': ?displayName,
    'kind': ?kind?.name,
    if (legacyHostAgent) 'legacy_host_agent': true,
  };

  /// Parses a stored record, or returns null if it is malformed / a future
  /// version — the caller then falls back to a fresh pairing rather than
  /// crashing on a corrupt entry.
  static AgentsStoredPairing? tryParse(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// [tryParse] for a record that is already decoded.
  static AgentsStoredPairing? fromJson(Map<String, dynamic> decoded) {
    try {
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
      final Object? name = decoded['name'];
      return AgentsStoredPairing(
        hostUrl: hostUrl,
        channelId: channelId,
        channelKey: Uint8List.fromList(channelKey),
        peerDeviceId: peerDeviceId,
        peerPublicKey: peerPublicKey,
        displayName: name is String && name.trim().isNotEmpty
            ? name.trim()
            : null,
        kind: AgentsHostKind.tryParse(decoded['kind']),
        legacyHostAgent: decoded['legacy_host_agent'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Loads and saves the app's stable identity and its trust records, one per
/// paired computer (CHAT-177, docs/agents/MULTI_HOST.md).
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

  /// The single trust record of the app before CHAT-177. Read once and moved
  /// into [_kPairings].
  static const String _kLegacyPairing = 'cowork_pairing';

  /// All trust records: `{"version": 2, "hosts": {hostId: record},
  /// "last_used": hostId}`.
  static const String _kPairings = 'cowork_pairings_v2';

  final AgentsSecureKeyValueStore _store;
  final Uuid _uuid;

  /// Encrypted Supabase mirror. Every local [savePairing] is also pushed here
  /// (best-effort) so a reinstall on a new device can pull the trust records
  /// back after sign-in. Injectable for tests.
  final SupabasePairingSync _cloudSync;

  /// One write at a time per backend: two stores over the same secure
  /// storage (the production one is a single const instance) must not read,
  /// change and write the list in an interleaved way and lose a host. Keyed
  /// by the backend, so a test's in-memory store never waits on another's.
  static final Expando<Future<void>> _locks = Expando<Future<void>>();

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final Future<void> previous = _locks[_store] ?? Future<void>.value();
    final Completer<void> done = Completer<void>();
    _locks[_store] = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  /// The backend everything is written to. Exposed so a test can assert that the
  /// production default really is the OS keychain / libsecret — both the device
  /// seed and the channel key are key material, and must never fall back to
  /// SharedPreferences.
  AgentsSecureKeyValueStore get backend => _store;

  /// Notifies after every write to or delete of a trust record (a new
  /// pairing, a restored one, a trust update from the host, a rename,
  /// "Remove this computer"). Listeners read the records again; the
  /// notification itself carries no data. The shell listens here to show or
  /// hide the Agents half, so it never has to poll the secure store.
  ///
  /// One signal for the whole process: every store writes the same secure
  /// storage, so a rename on the Computers page must reach the shell's store.
  Listenable get changes => _changes;
  static final _PairingChanges _changes = _PairingChanges();

  void _notifyChanged() => _changes.ping();

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

  // --- the list ---------------------------------------------------------------

  /// Reads the list. The first read after an update moves the old single
  /// record into the list and deletes the old key.
  Future<_PairingList> _read() async {
    final String? raw = await _store.read(_kPairings);
    if (raw != null) return _PairingList.parse(raw);
    final String? legacy = await _store.read(_kLegacyPairing);
    if (legacy == null) return _PairingList.empty();
    final AgentsStoredPairing? record = AgentsStoredPairing.tryParse(legacy);
    final _PairingList list = _PairingList.empty();
    if (record != null) list.put(record.asLegacy());
    // Written first, deleted second: a crash in between leaves both, and the
    // next read takes the new key.
    await _store.write(_kPairings, list.encode());
    await _store.delete(_kLegacyPairing);
    return list;
  }

  Future<void> _write(_PairingList list) =>
      _store.write(_kPairings, list.encode());

  /// Every paired computer, in the order they were added.
  Future<List<AgentsStoredPairing>> listPairings() async =>
      (await _read()).records;

  /// The trust record of [hostId], or — without a host id — of the computer
  /// used last (the first one when none was used yet). Null when the app has
  /// never paired (or the record was forgotten / is corrupt).
  Future<AgentsStoredPairing?> loadPairing({String? hostId}) async {
    final _PairingList list = await _read();
    if (hostId != null) return list.byId(hostId);
    return list.primary;
  }

  /// The newest stored record of the computer [stored] belongs to: by its
  /// host id, or by its channel when the host id changed since (a loopback
  /// record that moved to its relay route). Null when it was removed.
  Future<AgentsStoredPairing?> reloadPairing(AgentsStoredPairing stored) async {
    final _PairingList list = await _read();
    final AgentsStoredPairing? byId = list.byId(stored.hostId);
    if (byId != null) return byId;
    for (final AgentsStoredPairing p in list.records) {
      if (p.channelId == stored.channelId) return p;
    }
    return null;
  }

  /// The host id of the computer the user used last, or null.
  Future<String?> lastUsedHostId() async => (await _read()).primary?.hostId;

  /// Remembers [hostId] as the computer used last: the default for a new
  /// agent and for a view that has no host yet. Does not notify: nothing
  /// about the list changed.
  Future<void> markUsed(String hostId) => _exclusive(() async {
    final _PairingList list = await _read();
    if (list.byId(hostId) == null || list.lastUsed == hostId) return;
    list.lastUsed = hostId;
    await _write(list);
  });

  /// Adds the trust record of a computer, or replaces the one with the same
  /// host id, then mirrors it to the encrypted Supabase copy so a reinstall
  /// elsewhere can reconnect.
  ///
  /// A record for the same host under an older id (the loopback form before
  /// the host announced its relay route) is replaced, not kept next to it.
  /// The user's name and kind of the computer survive a trust update that
  /// does not carry them.
  ///
  /// The local write is authoritative and is awaited first; the cloud mirror is
  /// best-effort and fire-and-forget, so an offline client still pairs and the
  /// caller never waits on the network.
  Future<void> savePairing(AgentsStoredPairing pairing) async {
    final AgentsStoredPairing saved = await _exclusive(() async {
      final _PairingList list = await _read();
      final AgentsStoredPairing merged = list.put(pairing);
      await _write(list);
      return merged;
    });
    _notifyChanged();
    // A local address cannot be restored on another device. Wait for the
    // authenticated host_route announcement before publishing the capability.
    if (saved.relayDeviceId != null) {
      unawaited(_cloudSync.saveEncryptedPairing(saved));
    }
  }

  /// Sets the user's name for a computer (null or empty: back to the
  /// default) and mirrors it. Returns false when the host is not paired.
  Future<bool> renamePairing(String hostId, String? name) async {
    final String? trimmed = name?.trim();
    final AgentsStoredPairing? renamed = await _exclusive(() async {
      final _PairingList list = await _read();
      final AgentsStoredPairing? current = list.byId(hostId);
      if (current == null) return null;
      final AgentsStoredPairing next = (trimmed == null || trimmed.isEmpty)
          ? current.copyWith(clearDisplayName: true)
          : current.copyWith(displayName: trimmed);
      list.replace(next);
      await _write(list);
      return next;
    });
    if (renamed == null) return false;
    _notifyChanged();
    if (renamed.relayDeviceId != null) {
      unawaited(_cloudSync.saveEncryptedPairing(renamed));
    }
    return true;
  }

  /// Sets what kind of computer [hostId] is (and its name when given and the
  /// user has not named it). Used by the cloud box setup.
  Future<void> setHostKind(
    String hostId,
    AgentsHostKind kind, {
    String? defaultName,
  }) async {
    final AgentsStoredPairing? next = await _exclusive(() async {
      final _PairingList list = await _read();
      final AgentsStoredPairing? current = list.byId(hostId);
      if (current == null) return null;
      final AgentsStoredPairing updated = current.copyWith(
        kind: kind,
        displayName: current.displayName ?? defaultName,
      );
      list.replace(updated);
      await _write(list);
      return updated;
    });
    if (next == null) return;
    _notifyChanged();
    if (next.relayDeviceId != null) {
      unawaited(_cloudSync.saveEncryptedPairing(next));
    }
  }

  /// Loads the trust records from the encrypted Supabase mirror. Used on a
  /// fresh install to recover pairings that no local store has yet.
  Future<List<AgentsStoredPairing>> loadPairingsFromCloud() async =>
      (await _cloudSync.readEncryptedPairings()).pairings;

  /// The first mirrored record (the old single-host read). Kept for callers
  /// that only ask "is there any".
  Future<AgentsStoredPairing?> loadPairingFromCloud() async {
    final List<AgentsStoredPairing> all = await loadPairingsFromCloud();
    return all.isEmpty ? null : all.first;
  }

  /// [loadPairingsFromCloud] with the reason when there is no record.
  Future<AgentsCloudPairingsRead> readPairingsFromCloud() =>
      _cloudSync.readEncryptedPairings();

  Future<bool> publishPairing(AgentsStoredPairing pairing) =>
      _cloudSync.publishEncryptedPairing(pairing);

  /// Removes one computer — "Remove this computer". The stable device
  /// identity and the other computers are kept. Its encrypted Supabase row
  /// is deleted too (best-effort).
  Future<void> removePairing(String hostId) async {
    final bool removed = await _exclusive(() async {
      final _PairingList list = await _read();
      if (!list.remove(hostId)) return false;
      await _write(list);
      return true;
    });
    if (!removed) return;
    _notifyChanged();
    unawaited(_cloudSync.clearEncryptedPairing(hostId: hostId));
  }

  /// Deletes every trust record — the full "un-pair / forget". The stable
  /// device identity is kept, so a later fresh pairing reuses the same device
  /// key. The encrypted Supabase mirror is cleared too (best-effort).
  Future<void> clear() async {
    await _exclusive(() async {
      await _store.delete(_kPairings);
      await _store.delete(_kLegacyPairing);
    });
    _notifyChanged();
    unawaited(_cloudSync.clearEncryptedPairing());
  }

  /// The old name of [clear].
  Future<void> clearPairing() => clear();
}

/// The decoded list behind [AgentsPairingStore]. Keeps insertion order.
class _PairingList {
  _PairingList(this._hosts, this.lastUsed);

  factory _PairingList.empty() =>
      _PairingList(<String, AgentsStoredPairing>{}, null);

  /// A list that cannot be read is an empty one: the user adds the computer
  /// again (or the restore brings it back) instead of a crash.
  factory _PairingList.parse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 2) {
        return _PairingList.empty();
      }
      final Map<String, AgentsStoredPairing> hosts =
          <String, AgentsStoredPairing>{};
      final Object? rows = decoded['hosts'];
      if (rows is Map) {
        for (final Object? row in rows.values) {
          if (row is! Map) continue;
          final AgentsStoredPairing? record = AgentsStoredPairing.fromJson(
            Map<String, dynamic>.from(row),
          );
          if (record != null) hosts[record.hostId] = record;
        }
      }
      final Object? last = decoded['last_used'];
      return _PairingList(hosts, last is String ? last : null);
    } catch (_) {
      return _PairingList.empty();
    }
  }

  final Map<String, AgentsStoredPairing> _hosts;
  String? lastUsed;

  List<AgentsStoredPairing> get records =>
      List<AgentsStoredPairing>.unmodifiable(_hosts.values);

  AgentsStoredPairing? byId(String hostId) => _hosts[hostId];

  /// The computer used last, else the first one.
  AgentsStoredPairing? get primary {
    final String? last = lastUsed;
    if (last != null && _hosts.containsKey(last)) return _hosts[last];
    return _hosts.isEmpty ? null : _hosts.values.first;
  }

  /// Adds or replaces [record]; returns what was stored (with the name and
  /// kind carried over from the record it replaced).
  AgentsStoredPairing put(AgentsStoredPairing record) {
    final String id = record.hostId;
    AgentsStoredPairing? older = _hosts[id];
    // The same host under an older id: same channel, so the same host.
    String? staleId;
    for (final MapEntry<String, AgentsStoredPairing> e in _hosts.entries) {
      if (e.key != id && e.value.channelId == record.channelId) {
        staleId = e.key;
        older ??= e.value;
        break;
      }
    }
    final AgentsStoredPairing merged = record.inheritInfo(older);
    if (staleId != null) {
      // Keep the host's place in the order.
      final Map<String, AgentsStoredPairing> next =
          <String, AgentsStoredPairing>{};
      for (final MapEntry<String, AgentsStoredPairing> e in _hosts.entries) {
        if (e.key == staleId) {
          next[id] = merged;
        } else if (e.key != id) {
          next[e.key] = e.value;
        }
      }
      _hosts
        ..clear()
        ..addAll(next);
      if (lastUsed == staleId) lastUsed = id;
    } else {
      _hosts[id] = merged;
    }
    return merged;
  }

  void replace(AgentsStoredPairing record) => _hosts[record.hostId] = record;

  bool remove(String hostId) {
    final bool removed = _hosts.remove(hostId) != null;
    if (removed && lastUsed == hostId) lastUsed = null;
    return removed;
  }

  String encode() => jsonEncode(<String, dynamic>{
    'version': 2,
    'hosts': <String, dynamic>{
      for (final MapEntry<String, AgentsStoredPairing> e in _hosts.entries)
        e.key: e.value.toJson(),
    },
    'last_used': ?lastUsed,
  });
}

/// The store's change signal. The store lives as long as the shell that made
/// it and is never disposed, so a ping after the last listener left is safe.
class _PairingChanges extends ChangeNotifier {
  void ping() => notifyListeners();
}
