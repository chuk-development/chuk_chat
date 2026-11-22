/// Supabase-backed encrypted mirror of the Agents trust records (one row per
/// paired computer since CHAT-177).
///
/// This is the other half of "reinstall anywhere, reconnect automatically"
/// (see `docs/PRODUCT_PHILOSOPHY.md`). The local [AgentsPairingStore] keeps the
/// trust record in the OS keychain, which is perfect while the app lives on one
/// device but is gone the moment the user deletes the client or moves to a new
/// phone. To survive that, the same record is mirrored to Supabase, keyed to the
/// signed-in user, so a fresh install can sign in and pull it back.
///
/// The record contains real key material (the 32-byte channel key). Supabase
/// must therefore only ever hold **ciphertext**. Everything is encrypted
/// client-side with [EncryptionService] — the same per-user AES-256-GCM key that
/// already protects chat payloads, derived from the user's password via PBKDF2
/// with a salt held in `user_metadata`. Supabase, its admins, and anyone with a
/// stolen anon key see an opaque blob and nothing else.
///
/// Both methods are defensive: any failure (not initialised, not signed in, no
/// encryption key, network error, corrupt/foreign ciphertext) resolves to a
/// no-op on save and `null` on load, so an offline or half-configured client
/// keeps working from its local store.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// One mirrored row as it is stored: the host it belongs to and the
/// ciphertext.
@immutable
class AgentsPairingRow {
  const AgentsPairingRow({required this.hostId, required this.ciphertext});

  /// The host's relay device id, or [SupabasePairingSync.legacyHostId] for a
  /// row written before CHAT-177.
  final String hostId;
  final String ciphertext;
}

/// What the mirror needs from the outside world: the signed-in user, the
/// table and the account key. The production one is Supabase plus
/// [EncryptionService]; a test passes an in-memory one.
abstract class AgentsPairingCloud {
  const AgentsPairingCloud();

  /// The signed-in user's id, or null when there is no session (or no
  /// Supabase at all).
  String? currentUserId();

  /// Makes sure the account key is unlocked.
  Future<bool> ensureKey();

  Future<String> encrypt(String plaintext);
  Future<String> decrypt(String ciphertext);

  /// Every row of [userId].
  Future<List<AgentsPairingRow>> selectAll(String userId);

  /// Inserts or replaces the row `(userId, hostId)`.
  Future<void> upsert(String userId, String hostId, String ciphertext);

  /// Deletes the row of [hostId], or every row of the user without one.
  Future<void> delete(String userId, {String? hostId});
}

/// The production [AgentsPairingCloud]: the `cowork_pairings` table under
/// row-level security, sealed with the account key.
class SupabaseAgentsPairingCloud extends AgentsPairingCloud {
  const SupabaseAgentsPairingCloud();

  @override
  String? currentUserId() {
    if (!SupabaseService.isInitialized) return null;
    return SupabaseService.auth.currentUser?.id;
  }

  /// It is cached after a password sign-in; on a fresh reinstall the caller
  /// must have unlocked it (the usual password step) before pairing can be
  /// mirrored or read back.
  @override
  Future<bool> ensureKey() async {
    if (EncryptionService.hasKey) return true;
    return EncryptionService.tryLoadKey();
  }

  @override
  Future<String> encrypt(String plaintext) =>
      EncryptionService.encrypt(plaintext);

  @override
  Future<String> decrypt(String ciphertext) =>
      EncryptionService.decrypt(ciphertext);

  @override
  Future<List<AgentsPairingRow>> selectAll(String userId) async {
    final List<Map<String, dynamic>> rows = await SupabaseService.client
        .from(SupabasePairingSync.table)
        .select(
          '${SupabasePairingSync.columnHostId},'
          '${SupabasePairingSync.columnCiphertext}',
        )
        .eq(SupabasePairingSync.columnUserId, userId);
    return <AgentsPairingRow>[
      for (final Map<String, dynamic> row in rows)
        if (row[SupabasePairingSync.columnCiphertext] is String)
          AgentsPairingRow(
            hostId:
                (row[SupabasePairingSync.columnHostId] as String?) ??
                SupabasePairingSync.legacyHostId,
            ciphertext: row[SupabasePairingSync.columnCiphertext] as String,
          ),
    ];
  }

  @override
  Future<void> upsert(String userId, String hostId, String ciphertext) async {
    await SupabaseService.client.from(SupabasePairingSync.table).upsert(
      <String, dynamic>{
        SupabasePairingSync.columnUserId: userId,
        SupabasePairingSync.columnHostId: hostId,
        SupabasePairingSync.columnCiphertext: ciphertext,
        SupabasePairingSync.columnUpdatedAt: DateTime.now()
            .toUtc()
            .toIso8601String(),
      },
      onConflict: SupabasePairingSync.conflictTarget,
    );
  }

  @override
  Future<void> delete(String userId, {String? hostId}) async {
    var query = SupabaseService.client
        .from(SupabasePairingSync.table)
        .delete()
        .eq(SupabasePairingSync.columnUserId, userId);
    if (hostId != null) {
      query = query.eq(SupabasePairingSync.columnHostId, hostId);
    }
    await query;
  }
}

/// Reads and writes the encrypted trust-record mirror in Supabase: one row
/// per paired computer (CHAT-177).
///
/// The contract for the table this talks to is in `docs/SUPABASE_SCHEMA.md`.
class SupabasePairingSync {
  const SupabasePairingSync({this._cloud});

  final AgentsPairingCloud? _cloud;

  AgentsPairingCloud get _backend =>
      _cloud ?? const SupabaseAgentsPairingCloud();

  /// Table holding one encrypted trust record per user and computer.
  static const String table = 'cowork_pairings';

  /// `uuid` — the owner. Row-level security ties every row to `auth.uid()`.
  static const String columnUserId = 'user_id';

  /// `text` — the host's relay device id. With [columnUserId] the primary
  /// key. [legacyHostId] for a row from before CHAT-177.
  static const String columnHostId = 'host_id';

  /// `text` — the AES-256-GCM ciphertext produced by [EncryptionService.encrypt].
  static const String columnCiphertext = 'ciphertext';

  /// `timestamptz` — last write, for debugging and last-writer-wins.
  static const String columnUpdatedAt = 'updated_at';

  /// The upsert's conflict target: the primary key.
  static const String conflictTarget = 'user_id,host_id';

  /// The host id of a row the migration carried over. The app re-keys it to
  /// the real id once it has decrypted the row.
  static const String legacyHostId = 'legacy';

  /// Encrypts [pairing] and upserts it under the signed-in user's id and its
  /// host id.
  ///
  /// Best-effort by contract: it silently does nothing when there is no
  /// Supabase, no signed-in user, or no encryption key available, and it
  /// swallows network / server errors. It never throws, so callers can mirror
  /// on every local save without guarding.
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {
    await publishEncryptedPairing(pairing);
  }

  /// Returns success so the supervisor can retry a locked key or failed upload.
  /// A record with no relay device id (a loopback address) is never mirrored:
  /// no other device could dial it.
  Future<bool> publishEncryptedPairing(AgentsStoredPairing pairing) async {
    try {
      final String? hostId = pairing.relayDeviceId;
      if (hostId == null) return false;
      final AgentsPairingCloud cloud = _backend;
      final String? userId = cloud.currentUserId();
      if (userId == null) return false;
      if (!await cloud.ensureKey()) return false;
      final String ciphertext = await cloud.encrypt(
        jsonEncode(pairing.toJson()),
      );
      await cloud.upsert(userId, hostId, ciphertext);
      return true;
    } catch (error) {
      // Best-effort mirror: offline / server errors must not break local save.
      if (kDebugMode) {
        debugPrint('⚠️ [AgentsPairingSync] save skipped: ${error.runtimeType}');
      }
      return false;
    }
  }

  /// Fetches and decrypts every mirrored trust record of the signed-in user.
  ///
  /// The outcome is [AgentsCloudPairingOutcome.found] when at least one row
  /// opened. A row that cannot be opened (another password era, a foreign
  /// ciphertext) is skipped; only when no row opens the outcome says why.
  ///
  /// A row from before CHAT-177 (host id [legacyHostId]) is re-keyed to its
  /// real host id in the background: the new row is written first, then the
  /// legacy row is deleted. Never throws.
  Future<AgentsCloudPairingsRead> readEncryptedPairings() async {
    final AgentsPairingCloud cloud = _backend;
    final String? userId;
    try {
      userId = cloud.currentUserId();
    } catch (_) {
      return const AgentsCloudPairingsRead(AgentsCloudPairingOutcome.noSession);
    }
    if (userId == null) {
      return const AgentsCloudPairingsRead(AgentsCloudPairingOutcome.noSession);
    }
    final List<AgentsPairingRow> rows;
    try {
      rows = await cloud.selectAll(userId);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [AgentsPairingSync] read failed: ${error.runtimeType}');
      }
      return const AgentsCloudPairingsRead(AgentsCloudPairingOutcome.network);
    }
    final List<AgentsPairingRow> usable = <AgentsPairingRow>[
      for (final AgentsPairingRow row in rows)
        if (row.ciphertext.isNotEmpty) row,
    ];
    if (usable.isEmpty) {
      return const AgentsCloudPairingsRead(AgentsCloudPairingOutcome.noRecord);
    }
    try {
      if (!await cloud.ensureKey()) {
        return const AgentsCloudPairingsRead(
          AgentsCloudPairingOutcome.keyLocked,
        );
      }
    } catch (_) {
      return const AgentsCloudPairingsRead(AgentsCloudPairingOutcome.keyLocked);
    }
    final Map<String, AgentsStoredPairing> found =
        <String, AgentsStoredPairing>{};
    final List<AgentsStoredPairing> rekeys = <AgentsStoredPairing>[];
    for (final AgentsPairingRow row in usable) {
      final AgentsStoredPairing? parsed;
      try {
        parsed = AgentsStoredPairing.tryParse(
          await cloud.decrypt(row.ciphertext),
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '⚠️ [AgentsPairingSync] decrypt failed: ${error.runtimeType}',
          );
        }
        continue;
      }
      if (parsed == null) continue;
      // A row from before CHAT-177 is the account's first computer: its own
      // agent keeps the old id on every device.
      final AgentsStoredPairing pairing = row.hostId == legacyHostId
          ? parsed.asLegacy()
          : parsed;
      final String? realId = pairing.relayDeviceId;
      if (row.hostId == legacyHostId && realId != null) {
        rekeys.add(pairing);
      }
      // A real row wins over the legacy copy of the same host; the legacy
      // mark survives either way.
      final String key = realId ?? pairing.hostId;
      final AgentsStoredPairing? seen = found[key];
      if (seen == null) {
        found[key] = pairing;
      } else if (row.hostId == legacyHostId) {
        found[key] = seen.inheritInfo(pairing);
      } else {
        found[key] = pairing.inheritInfo(seen);
      }
    }
    if (found.isEmpty) {
      return const AgentsCloudPairingsRead(
        AgentsCloudPairingOutcome.decryptFailed,
      );
    }
    if (rekeys.isNotEmpty) unawaited(_rekeyLegacy(cloud, userId, rekeys));
    return AgentsCloudPairingsRead(
      AgentsCloudPairingOutcome.found,
      List<AgentsStoredPairing>.unmodifiable(found.values),
    );
  }

  /// Moves a legacy row to its real host id, sealed again with the legacy
  /// mark in it: upsert first, delete second, so a failure in between leaves
  /// a duplicate (which the next read folds together), never a lost record.
  Future<void> _rekeyLegacy(
    AgentsPairingCloud cloud,
    String userId,
    List<AgentsStoredPairing> rekeys,
  ) async {
    try {
      for (final AgentsStoredPairing pairing in rekeys) {
        final String? hostId = pairing.relayDeviceId;
        if (hostId == null) continue;
        final String ciphertext = await cloud.encrypt(
          jsonEncode(pairing.toJson()),
        );
        await cloud.upsert(userId, hostId, ciphertext);
      }
      await cloud.delete(userId, hostId: legacyHostId);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [AgentsPairingSync] re-key skipped: ${error.runtimeType}',
        );
      }
    }
  }

  /// The first record of [readEncryptedPairings], for callers that ask "is
  /// there a computer at all".
  Future<AgentsCloudPairingRead> readEncryptedPairing() async {
    final AgentsCloudPairingsRead read = await readEncryptedPairings();
    return AgentsCloudPairingRead(
      read.outcome,
      read.pairings.isEmpty ? null : read.pairings.first,
    );
  }

  /// [readEncryptedPairing] without the reason.
  Future<AgentsStoredPairing?> loadEncryptedPairing() async =>
      (await readEncryptedPairing()).pairing;

  /// Removes the mirrored row of [hostId], or every row of the signed-in user
  /// without one — the cloud side of the local "remove / forget" action.
  /// Best-effort; never throws.
  Future<void> clearEncryptedPairing({String? hostId}) async {
    try {
      final AgentsPairingCloud cloud = _backend;
      final String? userId = cloud.currentUserId();
      if (userId == null) return;
      await cloud.delete(userId, hostId: hostId);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [AgentsPairingSync] clear skipped: ${error.runtimeType}',
        );
      }
    }
  }
}

/// How a read of the encrypted mirror ended.
enum AgentsCloudPairingOutcome {
  /// A record was read and decrypted.
  found,

  /// No Supabase client or no signed-in user yet.
  noSession,

  /// The account has no mirrored record: this account never added a computer.
  noRecord,

  /// A record exists, but the account key is not unlocked yet.
  keyLocked,

  /// The read did not reach Supabase (offline, timeout, server error).
  network,

  /// A record exists, but it cannot be decrypted or parsed with this key.
  decryptFailed,
}

/// One read of the encrypted mirror: the record, or why there is none.
@immutable
class AgentsCloudPairingRead {
  const AgentsCloudPairingRead(this.outcome, [this.pairing]);

  final AgentsCloudPairingOutcome outcome;

  /// Non-null only when [outcome] is [AgentsCloudPairingOutcome.found].
  final AgentsStoredPairing? pairing;
}

/// One read of the whole mirror: every record that opened, or why there is
/// none.
@immutable
class AgentsCloudPairingsRead {
  const AgentsCloudPairingsRead(
    this.outcome, [
    this.pairings = const <AgentsStoredPairing>[],
  ]);

  final AgentsCloudPairingOutcome outcome;

  /// Non-empty only when [outcome] is [AgentsCloudPairingOutcome.found].
  final List<AgentsStoredPairing> pairings;
}
