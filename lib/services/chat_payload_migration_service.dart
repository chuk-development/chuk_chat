// lib/services/chat_payload_migration_service.dart
//
// The one-time rewrite of every chat to payload v3 (chat_payload_codec.dart)
// in a compressed envelope (encryption_service.dart), in the SQLite cache and
// in the cloud (`encrypted_chats`). It runs behind a blocking maintenance
// screen (widgets/chat_maintenance_gate.dart) before any chat UI loads.
//
// Flow of [ChatPayloadMigrationService.execute]:
//
// 1. Back up the SQLite cache (`VACUUM INTO chat_cache.backup.db`).
// 2. Local: rewrite every cache row that is not a v3 frame yet. Each row is
//    converted and proven in an isolate (the v3 JSON must give the same
//    messages), and written only while the row is unchanged.
// 3. Local verification: read every rewritten row back, decode it and compare
//    its fingerprint with the original's. Any fault restores the backup and
//    ends the run with an error (Retry / Continue on the screen; Continue is
//    safe because the reader still reads v1 and v2).
// 4. Cloud: rewrite every chat whose envelope is still `{"v":"1"}`, 4 at a
//    time. Proven before the write (convertChatEnvelopeToV3). The UPDATE
//    carries `updated_at = <read value> + 1 µs` with the guard
//    `WHERE updated_at = <read value>`: the database trigger keeps a value
//    the client changed on purpose, so the sidebar order and dates stay, and
//    a save that came in meanwhile wins. Each written chat is verified from
//    the envelope that was written (decrypt, decode, compare fingerprints);
//    a mismatch writes the original ciphertext back.
// 5. Done: the flag goes into `kv_cache`, the backup is deleted. Offline or a
//    cloud error: the local part is complete, and the cloud chats that are
//    left (their envelope is still v1) are retried behind the app. No state
//    is half written: each cloud chat is one UPDATE, and the cache is
//    restored as a whole.
//
// Skipped: dirty chats (their next cloud save is v3 anyway), locked chats
// (another key; the recovery flow rewrites them as v3), Agents threads (a
// separate table and format). Nothing streams while the screen is up.
//
// Web: no cache database, so only the cloud part runs, behind the same screen.
//
// A normal start (the session was already there when the app started) never
// waits for the cloud: [ChatPayloadMigrationService.startupCheck] reads only
// the state in `kv_cache` and the cache, and the cloud list is read behind
// the app ([ChatPayloadMigrationService.checkCloudInBackground]).
//
// The app waits for the cloud once per account and device: the first check
// that holds the app (a sign-in on this device, or the start after cloud
// chats were found behind the app) spends that wait, whatever its outcome.
// What it leaves is retried behind the app, never behind the screen again.
// A chat that fails for a reason that cannot pass (not decryptable, not a
// payload this app can read) is left as it is at once; any other failure is
// counted, and the third one leaves the chat as it is too. A cache row that
// cannot be read or converted is left as it is, and after two local runs
// that failed, all cache rows are. A chat left as it is stays readable (the
// reader reads v1 and v2); its next save writes v3. Every such decision goes
// to the opt-in diagnostics log (a reason and an error type, never an id).

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/services/chat_dirty_store.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:cryptography/cryptography.dart'
    show SecretBoxAuthenticationError;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;

/// `updated_at` + 1 µs, as Postgres wants it. Works on the web too, where a
/// `DateTime` holds only milliseconds.
String bumpTimestampByOneMicrosecond(String timestamp) {
  final match = RegExp(
    r'^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}(?::?\d{2})?)?$',
  ).firstMatch(timestamp.trim());
  if (match == null) {
    throw FormatException('Not a timestamp: $timestamp');
  }
  var offset = match.group(3) ?? 'Z';
  if (RegExp(r'^[+-]\d{2}$').hasMatch(offset)) offset = '$offset:00';
  var base = DateTime.parse('${match.group(1)!.replaceFirst(' ', 'T')}$offset')
      .toUtc();
  final fraction = (match.group(2) ?? '').padRight(6, '0');
  if (fraction.length > 6) {
    throw FormatException('More than microsecond precision: $timestamp');
  }
  var micros = int.parse(fraction) + 1;
  if (micros == 1000000) {
    micros = 0;
    base = base.add(const Duration(seconds: 1));
  }
  String two(int v) => v.toString().padLeft(2, '0');
  return '${base.year.toString().padLeft(4, '0')}-${two(base.month)}-'
      '${two(base.day)}T${two(base.hour)}:${two(base.minute)}:'
      '${two(base.second)}.${micros.toString().padLeft(6, '0')}+00:00';
}

/// Progress of a run, for the two bars of the maintenance screen.
@immutable
class ChatMaintenanceProgress {
  const ChatMaintenanceProgress({
    this.migrated = 0,
    this.verified = 0,
    this.total = 0,
  });

  final int migrated;
  final int verified;
  final int total;

  ChatMaintenanceProgress copyWith({int? migrated, int? verified}) =>
      ChatMaintenanceProgress(
        migrated: migrated ?? this.migrated,
        verified: verified ?? this.verified,
        total: total,
      );
}

/// What needs rewriting for one account.
@immutable
class ChatMaintenancePlan {
  const ChatMaintenancePlan({
    required this.userId,
    required this.localIds,
    required this.cloud,
    required this.cloudKnown,
    this.localKnown = true,
  });

  final String userId;

  /// Cache rows that are not a v3 frame yet.
  final List<String> localIds;

  /// Cloud chats with a `{"v":"1"}` envelope, minus skipped and dirty ones.
  final List<String> cloud;

  /// Whether the cloud list is complete (false: offline, no key, an error).
  final bool cloudKnown;

  /// Whether the cache scan ran (false: it failed). The done flag needs it.
  final bool localKnown;

  int get total => localIds.length + cloud.length;
  bool get hasWork => total > 0;
}

/// What a normal start has to wait for, from local state only.
enum ChatStartupCheck {
  /// The account is done: nothing to check.
  done,

  /// Only the cloud is unchecked: the app opens, the check runs behind it.
  background,

  /// Cache rows to rewrite, or the one wait for the cloud is still owed
  /// (cloud chats found behind the app, or a sign-in on this device): the
  /// maintenance screen runs before the app opens.
  blocking,
}

/// How a run ended.
enum ChatMaintenanceOutcome {
  /// Everything is v3 (or skipped for good). The done flag is set.
  complete,

  /// Local part complete; some cloud chats are retried behind the app.
  cloudPending,
}

/// A run that failed. [restored] tells whether the cache backup was put back.
class ChatMaintenanceFailure implements Exception {
  const ChatMaintenanceFailure(this.stage, this.cause, {this.restored = false});

  final String stage;
  final Object cause;
  final bool restored;

  @override
  String toString() => 'ChatMaintenanceFailure($stage, restored: $restored)';
}

/// The cloud half, behind an interface so tests run it without Supabase.
abstract class ChatMigrationCloud {
  /// Ids of the chats whose envelope is still `{"v":"1"}`.
  Future<List<String>> listPlainEnvelopeChats(String userId);

  /// The row (ciphertext and `updated_at` as the server sent it), or null.
  Future<({String encrypted, String updatedAt})?> readRow(
    String userId,
    String chatId,
  );

  /// UPDATE with the `updated_at` guard. Returns the `updated_at` the server
  /// stored, or null when the guard failed (the row changed or is gone).
  Future<String?> writeRow(
    String userId,
    String chatId, {
    required String encrypted,
    required String updatedAt,
    required String expectedUpdatedAt,
  });

  /// Convert a v1 envelope to a proven v3 envelope (null: proof failed).
  Future<ChatEnvelopeV3?> convert(String encrypted);

  /// Decrypt an envelope and fingerprint its messages.
  Future<String> fingerprint(String encrypted);

  /// The key version of the current key.
  int get currentKeyVersion;

  /// Whether the encryption key is loaded (loads it if it can).
  Future<bool> ensureKey();
}

/// [ChatMigrationCloud] over Supabase and [EncryptionService].
class SupabaseChatMigrationCloud implements ChatMigrationCloud {
  const SupabaseChatMigrationCloud();

  @override
  Future<List<String>> listPlainEnvelopeChats(String userId) async {
    // Every writer puts "v" first, so a prefix match finds the old ones.
    final rows = await SupabaseService.client
        .from('encrypted_chats')
        .select('id')
        .eq('user_id', userId)
        .like('encrypted_payload', '{"v":"1"%')
        .timeout(const Duration(seconds: 8));
    return [for (final row in rows) row['id'] as String];
  }

  @override
  Future<({String encrypted, String updatedAt})?> readRow(
    String userId,
    String chatId,
  ) async {
    final row = await SupabaseService.client
        .from('encrypted_chats')
        .select('encrypted_payload, updated_at')
        .eq('id', chatId)
        .eq('user_id', userId)
        .maybeSingle()
        .timeout(const Duration(seconds: 15));
    final encrypted = row?['encrypted_payload'] as String?;
    final updatedAt = row?['updated_at'] as String?;
    if (encrypted == null || encrypted.isEmpty || updatedAt == null) {
      return null;
    }
    return (encrypted: encrypted, updatedAt: updatedAt);
  }

  @override
  Future<String?> writeRow(
    String userId,
    String chatId, {
    required String encrypted,
    required String updatedAt,
    required String expectedUpdatedAt,
  }) async {
    final rows = await SupabaseService.client
        .from('encrypted_chats')
        .update({'encrypted_payload': encrypted, 'updated_at': updatedAt})
        .eq('id', chatId)
        .eq('user_id', userId)
        .eq('updated_at', expectedUpdatedAt)
        .select('updated_at')
        .timeout(const Duration(seconds: 15));
    if (rows.isEmpty) return null;
    return rows.first['updated_at'] as String?;
  }

  @override
  Future<ChatEnvelopeV3?> convert(String encrypted) =>
      EncryptionService.convertChatPayloadToV3(encrypted);

  @override
  Future<String> fingerprint(String encrypted) =>
      EncryptionService.chatPayloadFingerprintOf(encrypted);

  @override
  int get currentKeyVersion => EncryptionService.currentKeyVersion;

  @override
  Future<bool> ensureKey() async {
    if (EncryptionService.hasKey) return true;
    try {
      return await EncryptionService.tryLoadKey().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }
}

class ChatPayloadMigrationService {
  ChatPayloadMigrationService._();

  /// Concurrent chats in the cloud part (and conversions in the local part).
  static const int parallelism = 4;

  /// Concurrent chats when the cloud part is retried behind the app. The
  /// web has no isolates: there the conversion runs on the UI thread.
  static const int backgroundParallelism = kIsWeb ? 1 : 2;

  /// Failures after which a cloud chat is left as it is for good.
  static const int maxTries = 3;

  /// Failed local runs (the backup put back) after which the cache rows are
  /// left as they are and no longer hold the app.
  static const int maxLocalFailures = 2;

  /// Test seams.
  @visibleForTesting
  static ChatMigrationCloud cloud = const SupabaseChatMigrationCloud();
  @visibleForTesting
  static Future<String?> Function(String key) readKv =
      LocalChatCacheService.kvGet;
  @visibleForTesting
  static Future<void> Function(String key, String value) writeKv =
      LocalChatCacheService.kvSet;

  /// The cache scan for rows that are not a v3 frame yet.
  @visibleForTesting
  static Future<List<String>> Function(String userId) localUpgradeIds =
      LocalChatCacheService.idsNeedingPayloadUpgrade;

  /// Called between the local rewrite and its verification (tests break a
  /// row here to prove the restore).
  @visibleForTesting
  static Future<void> Function()? debugBeforeLocalVerify;

  /// Whether this platform has a cache database to upgrade.
  @visibleForTesting
  static bool hasLocalDatabase = !kIsWeb;

  static String _stateKey(String userId) => 'chat_payload_v3_migration_$userId';

  /// What a start of [userId] waits for. Reads the state in `kv_cache` and
  /// the cache only: no key, no network, so it returns in milliseconds.
  ///
  /// [signIn] is true when the session was not there at app start. Such a
  /// start waits for the whole check only while this device never waited
  /// for the cloud of this account; after that it is a normal start.
  static Future<ChatStartupCheck> startupCheck(
    String userId, {
    bool signIn = false,
  }) async {
    final state = await _loadState(userId);
    if (state.done) return ChatStartupCheck.done;
    if (!state.cloudWaited && (state.cloudPending || signIn)) {
      return ChatStartupCheck.blocking;
    }
    if (hasLocalDatabase) {
      try {
        final ids = await localUpgradeIds(userId);
        if (ids.any(
          (id) => !ChatOrigin.isAgentsThread(id) && !state.skip.contains(id),
        )) {
          return ChatStartupCheck.blocking;
        }
      } catch (e) {
        // The blocking plan could not see the rows either. The check behind
        // the app keeps the done flag unset, so the next start scans again.
        if (kDebugMode) debugPrint('⚠️ [PayloadV3] cache scan failed: $e');
      }
    }
    return ChatStartupCheck.background;
  }

  /// The runs of [checkCloudInBackground] in flight, per user.
  static final Map<String, Future<void>> _background = {};

  /// The cloud half of the check, run behind the app on a normal start. The
  /// list needs no key: it only names the chats that still have a v1
  /// envelope. None left: the account is done. Some left while the app never
  /// waited for the cloud: the next start rewrites them behind the screen,
  /// once. Some left after that wait: they are rewritten here, behind the
  /// app, with the same guards as behind the screen. Never throws.
  static Future<void> checkCloudInBackground(String userId) {
    final running = _background[userId];
    if (running != null) return running;
    // A block body: `remove` returns this very future, and whenComplete
    // would wait for it.
    final run = _checkCloudInBackground(userId).whenComplete(() {
      _background.remove(userId);
    });
    _background[userId] = run;
    return run;
  }

  static Future<void> _checkCloudInBackground(String userId) async {
    try {
      final found = await plan(userId, behindApp: true);
      if (found.cloud.isEmpty) return;
      final state = await _loadState(userId);
      if (!state.cloudWaited) {
        state.cloudPending = true;
        await _saveState(userId, state);
        return;
      }
      if (!await cloud.ensureKey()) {
        _logIncompleteCheck('no_key_behind_app');
        return;
      }
      final result = await _runCloud(
        userId,
        found.cloud,
        state,
        width: backgroundParallelism,
      );
      if (!result.pending &&
          result.failure == null &&
          found.cloudKnown &&
          found.localKnown &&
          found.localIds.isEmpty) {
        state.done = true;
      }
      await _saveState(userId, state);
      _log('Chats retried behind the app', {
        'chats': found.cloud.length,
        'done': state.done,
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [PayloadV3] background check failed: ${e.runtimeType}');
      }
    }
  }

  /// What is left to do for [userId]; an empty plan when the account is
  /// done. Never throws: a cloud list that cannot be read is left for later.
  ///
  /// By default this is the check the app waits for: it loads the key, and
  /// it spends the one wait for the cloud of this account on this device
  /// (whatever it finds, what is left afterwards is retried behind the app).
  /// [behindApp] lists the cloud chats without the key and changes nothing
  /// but the done flag (the check behind a normal start).
  static Future<ChatMaintenancePlan> plan(
    String userId, {
    bool behindApp = false,
  }) async {
    final state = await _loadState(userId);
    if (state.done) {
      return ChatMaintenancePlan(
        userId: userId,
        localIds: const [],
        cloud: const [],
        cloudKnown: true,
      );
    }
    try {
      await ChatDirtyStore.load(userId);
    } catch (_) {
      // No dirty set: nothing is skipped for it.
    }

    var localIds = const <String>[];
    var localKnown = !hasLocalDatabase;
    if (hasLocalDatabase) {
      try {
        localIds = [
          for (final id in await localUpgradeIds(userId))
            if (!ChatOrigin.isAgentsThread(id) && !state.skip.contains(id)) id,
        ];
        localKnown = true;
      } catch (e) {
        _logIncompleteCheck('cache_scan_failed', e);
        if (kDebugMode) debugPrint('⚠️ [PayloadV3] cache scan failed: $e');
      }
    }

    var cloudIds = const <String>[];
    var cloudKnown = false;
    final scan = Stopwatch()..start();
    try {
      if (behindApp || await cloud.ensureKey()) {
        cloudIds = [
          for (final id in await cloud.listPlainEnvelopeChats(userId))
            if (!state.skip.contains(id) && !ChatDirtyStore.isDirty(id)) id,
        ];
        cloudKnown = true;
      } else {
        _logIncompleteCheck('no_key');
      }
    } catch (e) {
      _logIncompleteCheck('scan_failed', e, scan.elapsedMilliseconds);
      if (kDebugMode) {
        debugPrint('⚠️ [PayloadV3] cloud scan failed: ${e.runtimeType}');
      }
    }

    final plan = ChatMaintenancePlan(
      userId: userId,
      localIds: localIds,
      cloud: cloudIds,
      cloudKnown: cloudKnown,
      localKnown: localKnown,
    );
    var changed = false;
    if (!plan.hasWork && cloudKnown && localKnown) {
      state.done = true;
      state.cloudPending = false;
      changed = true;
    }
    if (!behindApp && (!state.cloudWaited || state.cloudPending)) {
      // The app waits for this check: that is the one wait for the cloud.
      // Whatever this check leaves is retried behind the app, never behind
      // the screen again (no key, a failed scan and a failing chat included).
      state.cloudWaited = true;
      state.cloudPending = false;
      changed = true;
    }
    if (changed) await _saveState(userId, state);
    return plan;
  }

  /// Run [plan]; see the file comment. Throws [ChatMaintenanceFailure] when
  /// the local part fails (the cache is restored) or a written cloud chat
  /// does not verify (it is written back).
  static Future<ChatMaintenanceOutcome> execute(
    ChatMaintenancePlan plan, {
    void Function(ChatMaintenanceProgress progress)? onProgress,
  }) async {
    final userId = plan.userId;
    final state = await _loadState(userId);
    var progress = ChatMaintenanceProgress(total: plan.total);
    void report(ChatMaintenanceProgress next) {
      progress = next;
      onProgress?.call(next);
    }

    report(progress);

    // ── 1. Backup ────────────────────────────────────────────────────────
    final useBackup = hasLocalDatabase && plan.localIds.isNotEmpty;
    if (useBackup) {
      try {
        await LocalChatCacheService.backupDatabase();
      } catch (e) {
        await _noteLocalFailure(plan, state, 'backup_failed', e);
        throw ChatMaintenanceFailure('backup', e);
      }
    }

    // ── 2. + 3. Local rewrite and verification ───────────────────────────
    final rewritten = <String, String>{}; // id -> original fingerprint
    String? verifying;
    try {
      await _pool(plan.localIds, (id) async {
        final fingerprint = await _migrateLocalRow(userId, id, state);
        if (fingerprint != null) rewritten[id] = fingerprint;
        report(progress.copyWith(migrated: progress.migrated + 1));
      });
      await debugBeforeLocalVerify?.call();
      final skippedLocal = plan.localIds.length - rewritten.length;
      if (skippedLocal > 0) {
        report(progress.copyWith(verified: progress.verified + skippedLocal));
      }
      for (final entry in rewritten.entries) {
        verifying = entry.key;
        await _verifyLocalRow(userId, entry.key, entry.value);
        report(progress.copyWith(verified: progress.verified + 1));
      }
      verifying = null;
    } catch (e) {
      var restored = false;
      if (useBackup) {
        try {
          await LocalChatCacheService.restoreBackup();
          restored = true;
        } catch (restoreError) {
          if (kDebugMode) {
            debugPrint('❌ [PayloadV3] restore failed: $restoreError');
          }
        }
      }
      // The row that did not verify is not rewritten again: the same
      // conversion would fail the same way at every start.
      final bad = verifying;
      if (bad != null) _leaveAsIs(state, bad, 'local_verify_failed', e);
      await _noteLocalFailure(plan, state, 'local_failed', e);
      throw ChatMaintenanceFailure('local', e, restored: restored);
    }

    // ── 4. Cloud ──────────────────────────────────────────────────────────
    final cloudResult = await _runCloud(
      userId,
      plan.cloud,
      state,
      onChat: () => report(
        progress.copyWith(
          migrated: progress.migrated + 1,
          verified: progress.verified + 1,
        ),
      ),
    );
    final cloudPending = !plan.cloudKnown || cloudResult.pending;
    final cloudFailure = cloudResult.failure;

    // ── 5. Done ───────────────────────────────────────────────────────────
    if (!cloudPending && cloudFailure == null && plan.localKnown) {
      state.done = true;
    }
    // This run was the app's one wait for the cloud: cloud chats it left
    // (and an unread cloud list) are retried behind the app, never behind
    // the screen again.
    state.cloudWaited = true;
    state.cloudPending = false;
    await _saveState(userId, state);
    if (useBackup) {
      try {
        await LocalChatCacheService.deleteBackup();
      } catch (_) {
        // A stale backup is replaced by the next run.
      }
    }
    if (cloudFailure != null) throw cloudFailure;
    return state.done
        ? ChatMaintenanceOutcome.complete
        : ChatMaintenanceOutcome.cloudPending;
  }

  /// A local run failed (the backup is back in place, and with it the state
  /// from before the run): count it and save the state again. After
  /// [maxLocalFailures] the cache rows of [plan] are left as they are, so a
  /// fault that repeats never holds every start.
  static Future<void> _noteLocalFailure(
    ChatMaintenancePlan plan,
    _MigrationState state,
    String reason,
    Object error,
  ) async {
    state.localFailures++;
    _log('Chat maintenance failed', {
      'reason': reason,
      'error': error.runtimeType.toString(),
      'failures': state.localFailures,
    });
    if (state.localFailures >= maxLocalFailures) {
      state.skip.addAll(plan.localIds);
      _log('Cached chats left as they are', {
        'reason': 'local_runs_failed',
        'rows': plan.localIds.length,
      });
    }
    await _saveState(plan.userId, state);
  }

  /// Rewrite one cache row as v3. Returns the fingerprint of its original
  /// messages, or null when there was nothing to do.
  static Future<String?> _migrateLocalRow(
    String userId,
    String chatId,
    _MigrationState state,
  ) async {
    ({Map<String, dynamic> row, int storedLength, bool framed})? raw;
    try {
      raw = await LocalChatCacheService.loadRawById(userId, chatId);
    } catch (e) {
      // The stored payload does not decode (a broken gzip blob, bad UTF-8).
      // The app cannot read the row either; the next sync replaces it.
      _leaveAsIs(state, chatId, 'local_unreadable', e);
      return null;
    }
    if (raw == null) return null; // deleted meanwhile
    final payload = raw.row['payload'];
    if (payload is! String || payload.isEmpty) {
      _leaveAsIs(state, chatId, 'local_empty');
      return null;
    }
    ({String v3, String fingerprint})? converted;
    try {
      converted = await compute(convertChatPayloadToV3WithFingerprint, payload);
    } catch (e) {
      // Not a payload this app can read (unparseable, an unexpected shape,
      // a newer version): the row stays as it is and is not retried. The
      // same data fails the same way, so a retry would only fail again.
      _leaveAsIs(state, chatId, 'local_unconvertible', e);
      return null;
    }
    if (converted == null) {
      // The proof failed: the row stays as it is and readable.
      _leaveAsIs(state, chatId, 'local_proof_failed');
      return null;
    }
    final written = await LocalChatCacheService.replacePayloadIfUnchanged(
      userId,
      chatId,
      payload: converted.v3,
      expectedUpdatedAt: raw.row['updated_at'] as String?,
      expectedStoredLength: raw.storedLength,
    );
    // A save came in meanwhile: the row holds what the app wrote (a frame,
    // so it needs nothing). Not a fault, and nothing to roll back for it.
    if (!written) return null;
    return converted.fingerprint;
  }

  static Future<void> _verifyLocalRow(
    String userId,
    String chatId,
    String expected,
  ) async {
    final raw = await LocalChatCacheService.loadRawById(userId, chatId);
    final payload = raw?.row['payload'];
    if (raw == null || !raw.framed || payload is! String) {
      throw StateError('A rewritten cached chat is missing or not framed');
    }
    if (peekChatPayloadVersion(payload) != kChatPayloadVersion) {
      throw StateError('A rewritten cached chat is not v3');
    }
    if (await compute(chatPayloadJsonFingerprint, payload) != expected) {
      throw StateError('A rewritten cached chat differs from its original');
    }
  }

  static Future<_CloudResult> _migrateCloudChat(
    String userId,
    String chatId,
    _MigrationState state,
  ) async {
    if (ChatDirtyStore.isDirty(chatId)) return _CloudResult.skipped;
    final row = await cloud.readRow(userId, chatId);
    if (row == null) return _CloudResult.skipped; // deleted meanwhile
    final version = envelopeVersionOf(row.encrypted);
    if (version == kCompressedEnvelopeVersion) return _CloudResult.done;
    final keyVersion = EncryptionService.extractKeyVersion(row.encrypted) ?? 1;
    if (version != kPlainEnvelopeVersion ||
        keyVersion != cloud.currentKeyVersion) {
      _leaveAsIs(state, chatId, 'cloud_other_key');
      return _CloudResult.skipped;
    }

    final ChatEnvelopeV3? converted;
    try {
      converted = await cloud.convert(row.encrypted);
    } on SecretBoxAuthenticationError {
      // Not decryptable with this key: a locked chat, left for recovery.
      _leaveAsIs(state, chatId, 'cloud_locked');
      return _CloudResult.skipped;
    } catch (e) {
      // Anything else that is not about this chat's data (no key any more,
      // a signed-out user) propagates and is counted by the caller.
      if (!_isUnreadable(e)) rethrow;
      // Not a chat payload this app can read (unparseable, an unexpected
      // shape, a newer version): the same data fails the same way again.
      _leaveAsIs(state, chatId, 'cloud_unconvertible', e);
      return _CloudResult.skipped;
    }
    if (converted == null) {
      _leaveAsIs(state, chatId, 'cloud_proof_failed');
      return _CloudResult.skipped;
    }

    final newUpdatedAt = bumpTimestampByOneMicrosecond(row.updatedAt);
    final stored = await cloud.writeRow(
      userId,
      chatId,
      encrypted: converted.envelope,
      updatedAt: newUpdatedAt,
      expectedUpdatedAt: row.updatedAt,
    );
    if (stored == null) return _CloudResult.pending; // changed meanwhile

    // Verify from the ciphertext that was written; on a mismatch put the
    // original back (guarded by the timestamp this run wrote).
    if (await cloud.fingerprint(converted.envelope) != converted.fingerprint) {
      await cloud.writeRow(
        userId,
        chatId,
        encrypted: row.encrypted,
        updatedAt: bumpTimestampByOneMicrosecond(stored),
        expectedUpdatedAt: stored,
      );
      _leaveAsIs(state, chatId, 'cloud_verify_failed');
      throw ChatMaintenanceFailure(
        'cloud-verify',
        StateError('A rewritten chat differs from its original'),
      );
    }

    // The cache row follows the new timestamp, so the next sync does not
    // download the chat again.
    if (hasLocalDatabase) {
      try {
        await LocalChatCacheService.updateUpdatedAtIfEqual(
          userId,
          chatId,
          expected: row.updatedAt,
          value: stored,
        );
      } catch (_) {
        // One extra download, nothing worse.
      }
    }
    return _CloudResult.done;
  }

  /// Rewrite the cloud chats [ids] (step 4 of a run, or the retry behind the
  /// app). A chat that fails is counted in [state]; see [_countFailure]. The
  /// run stops at a chat that does not verify (it is written back, and the
  /// failure is returned) and when the network is gone.
  static Future<({bool pending, ChatMaintenanceFailure? failure})> _runCloud(
    String userId,
    List<String> ids,
    _MigrationState state, {
    int width = parallelism,
    void Function()? onChat,
  }) async {
    var pending = false;
    ChatMaintenanceFailure? failure;
    var stop = false;
    await _pool(ids, (id) async {
      if (stop) return;
      try {
        final result = await _migrateCloudChat(userId, id, state);
        if (result == _CloudResult.pending) {
          // Another save won the guard: it most likely wrote v3 already.
          pending = true;
          _countFailure(state, id, 'cloud_changed');
        } else {
          state.tries.remove(id);
        }
      } on ChatMaintenanceFailure catch (e) {
        failure ??= e;
        stop = true;
      } catch (e) {
        pending = true;
        if (e is TimeoutException) {
          // A slow network, or a row too large for the timeout: counted, so
          // a row that never fits is left as it is after a few tries.
          _countFailure(state, id, 'cloud_timeout', e);
          stop = true;
        } else if (e is StateError || NetworkStatusService.isNetworkError(e)) {
          // Not this chat's fault (offline, no key or no user any more):
          // nothing is counted, the rest waits for the next try.
          stop = true;
        } else {
          // A server error about this row: counted.
          _countFailure(state, id, 'cloud_failed', e);
        }
        if (kDebugMode) {
          debugPrint('⚠️ [PayloadV3] cloud chat failed: ${e.runtimeType}');
        }
      }
      onChat?.call();
    }, width: width, shouldStop: () => stop);
    if (stop) pending = true;
    return (pending: pending, failure: failure);
  }

  /// Whether [error] comes from the chat's own data: the same data fails the
  /// same way at every try.
  static bool _isUnreadable(Object error) =>
      error is FormatException ||
      error is UnsupportedError ||
      error is TypeError ||
      error is ArgumentError ||
      error is RangeError;

  /// Count a failure of the cloud chat [chatId]. The [maxTries]th one leaves
  /// it as it is, so no chat is tried at every start forever.
  static void _countFailure(
    _MigrationState state,
    String chatId,
    String reason, [
    Object? error,
  ]) {
    final tries = (state.tries[chatId] ?? 0) + 1;
    if (tries >= maxTries) {
      _leaveAsIs(state, chatId, reason, error);
    } else {
      state.tries[chatId] = tries;
    }
  }

  /// Leave [chatId] as it is for good: it is never planned again. It stays
  /// readable, and its next save writes v3.
  static void _leaveAsIs(
    _MigrationState state,
    String chatId,
    String reason, [
    Object? error,
  ]) {
    state.skip.add(chatId);
    state.tries.remove(chatId);
    _log('Chat left as it is', {
      'reason': reason,
      if (error != null) 'error': error.runtimeType.toString(),
    });
  }

  /// Run [work] over [items], at most [width] at a time.
  static Future<void> _pool(
    List<String> items,
    Future<void> Function(String item) work, {
    int width = parallelism,
    bool Function()? shouldStop,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        if (shouldStop?.call() ?? false) return;
        final item = items[next++];
        await work(item);
      }
    }

    await Future.wait([
      for (var i = 0; i < width && i < items.length; i++) worker(),
    ]);
  }

  static Future<_MigrationState> _loadState(String userId) async {
    try {
      final raw = await readKv(_stateKey(userId));
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return _MigrationState.fromJson(decoded);
        }
      }
    } catch (_) {
      // A broken state starts over; every step is idempotent.
    }
    return _MigrationState();
  }

  static Future<void> _saveState(String userId, _MigrationState state) async {
    try {
      await writeKv(_stateKey(userId), jsonEncode(state.toJson()));
    } catch (e) {
      // The next start checks again; every step is idempotent.
      _log('Chat check state not saved', {'error': e.runtimeType.toString()});
      if (kDebugMode) debugPrint('⚠️ [PayloadV3] state not saved: $e');
    }
  }

  /// Why a check could not set the done flag, for the opt-in diagnostics
  /// log, with how long a failed scan took (a timeout shows as ~8000 ms).
  static void _logIncompleteCheck(String reason, [Object? error, int? ms]) =>
      _log('Chat check incomplete', {
        'reason': reason,
        if (error != null) 'error': error.runtimeType.toString(),
        'ms': ?ms,
      });

  /// A line in the opt-in diagnostics log: reasons, counts and error types
  /// only, never a message, an id or chat content. A log that cannot be
  /// written never stops the check.
  static void _log(String message, Map<String, Object?> data) {
    unawaited(
      DiagnosticsLogService.warning(
        'maintenance',
        message,
        data: data,
      ).catchError((Object _) {}),
    );
  }

  /// Whether the migration of [userId] is recorded as done.
  @visibleForTesting
  static Future<bool> isDone(String userId) async =>
      (await _loadState(userId)).done;

  /// Whether a check found cloud chats for the next start.
  @visibleForTesting
  static Future<bool> isCloudPending(String userId) async =>
      (await _loadState(userId)).cloudPending;

  /// Whether the app has waited for the cloud of [userId] once already.
  @visibleForTesting
  static Future<bool> hasWaitedForCloud(String userId) async =>
      (await _loadState(userId)).cloudWaited;

  /// Whether [chatId] is left as it is for good.
  @visibleForTesting
  static Future<bool> isLeftAsIs(String userId, String chatId) async =>
      (await _loadState(userId)).skip.contains(chatId);
}

enum _CloudResult { done, skipped, pending }

/// Persisted progress of one account on this device (`kv_cache`, which a
/// sign-out does not clear): the done flag, whether a check behind the app
/// found cloud chats for the next start, whether the app already waited for
/// the cloud once, the failed local runs, the chats that are never retried
/// (locked with another key, not readable, failed the proof, or failed
/// [ChatPayloadMigrationService.maxTries] times) and the failures counted so
/// far. Which cloud chats are left is read from the cloud itself: a
/// `{"v":"1"}` envelope.
class _MigrationState {
  _MigrationState({
    this.done = false,
    this.cloudPending = false,
    this.cloudWaited = false,
    this.localFailures = 0,
    Set<String>? skip,
    Map<String, int>? tries,
  }) : skip = skip ?? <String>{},
       tries = tries ?? <String, int>{};

  factory _MigrationState.fromJson(Map<String, dynamic> json) {
    final rawTries = json['tries'];
    return _MigrationState(
      done: json['done'] == true,
      cloudPending: json['cloudPending'] == true,
      cloudWaited: json['cloudWaited'] == true,
      localFailures: json['localFailures'] is int
          ? json['localFailures'] as int
          : 0,
      skip: json['skip'] is List
          ? (json['skip'] as List).whereType<String>().toSet()
          : null,
      tries: rawTries is Map
          ? <String, int>{
              for (final e in rawTries.entries)
                if (e.key is String && e.value is int)
                  e.key as String: e.value as int,
            }
          : null,
    );
  }

  bool done;
  bool cloudPending;
  bool cloudWaited;
  int localFailures;
  final Set<String> skip;
  final Map<String, int> tries;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'done': done,
    'cloudPending': cloudPending,
    'cloudWaited': cloudWaited,
    'localFailures': localFailures,
    'skip': skip.toList(),
    'tries': tries,
  };
}

/// Drives the maintenance screen: plans, runs, and holds the app until the
/// chats are rewritten (or the user continues after an error).
class ChatMaintenanceController extends ChangeNotifier {
  ChatMaintenanceController._();

  static final ChatMaintenanceController instance =
      ChatMaintenanceController._();

  ChatMaintenancePhase _phase = ChatMaintenancePhase.idle;
  ChatMaintenanceProgress _progress = const ChatMaintenanceProgress();
  ChatMaintenanceFailure? _failure;
  String? _userId;
  Completer<void>? _released;
  ChatMaintenancePlan? _plan;

  /// The user whose session was already there when the app started. Kept
  /// until a real sign-out (see [watchSignOuts]), not dropped by [reset]:
  /// the session manager also resets for an auth event without a session
  /// that is no sign-out (gotrue replays `initialSession` with no session
  /// when the Agents build set an expired session aside at startup), and a
  /// normal start must stay a normal start then.
  String? _restoredUserId;
  StreamSubscription<AuthState>? _signOuts;
  bool _showsSyncHint = false;

  ChatMaintenancePhase get phase => _phase;
  ChatMaintenanceProgress get progress => _progress;
  ChatMaintenanceFailure? get failure => _failure;

  /// Whether a slow check may say "Syncing your chats": only right after a
  /// sign-in, never on a normal start.
  bool get showsSyncHint => _showsSyncHint;

  /// Record the session the app started with (main(), after the Supabase
  /// init). Its check never holds the app for the cloud.
  void noteRestoredSession(String? userId) => _restoredUserId = userId;

  /// Forget the session the app started with: after a real sign-out, the
  /// next sign-in is a sign-in.
  void forgetRestoredSession() => _restoredUserId = null;

  /// Follow [events] (the Supabase auth stream, from main()) and forget the
  /// restored session at a real sign-out. Errors on the stream are ignored.
  void watchSignOuts(Stream<AuthState> events) {
    unawaited(_signOuts?.cancel());
    _signOuts = events.listen((AuthState state) {
      if (state.event == AuthChangeEvent.signedOut) forgetRestoredSession();
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    unawaited(_signOuts?.cancel());
    _signOuts = null;
    super.dispose();
  }

  /// Whether the chat UI must wait (the gate shows the screen or nothing).
  bool get holdsApp =>
      _phase == ChatMaintenancePhase.checking ||
      _phase == ChatMaintenancePhase.running ||
      _phase == ChatMaintenancePhase.failed;

  /// Plan and, when there is work, run the maintenance for [userId]. The
  /// future completes when the app may load chats. Safe to call from several
  /// places: every caller waits for the same run.
  Future<void> ensureReady(String userId) {
    if (_userId == userId && _released != null) return _released!.future;
    _userId = userId;
    _released = Completer<void>();
    unawaited(_check(userId));
    return _released!.future;
  }

  Future<void> _check(String userId) async {
    final restored = userId == _restoredUserId;
    _showsSyncHint = false;
    _set(ChatMaintenancePhase.checking);
    // Local state first (milliseconds). The app opens at once unless the
    // cache has rows to rewrite or the one wait for the cloud is still owed:
    // cloud chats found behind the app at an earlier start, or a sign-in on
    // a device that never waited for this account. Everything else about
    // the cloud is read behind the app.
    final start = await ChatPayloadMigrationService.startupCheck(
      userId,
      signIn: !restored,
    );
    if (_userId != userId) return;
    switch (start) {
      case ChatStartupCheck.done:
        _release();
        return;
      case ChatStartupCheck.background:
        _release();
        unawaited(ChatPayloadMigrationService.checkCloudInBackground(userId));
        return;
      case ChatStartupCheck.blocking:
        // Real work before the app opens (once): the check that plans it
        // may say what it waits for.
        _showsSyncHint = true;
        notifyListeners();
        break;
    }
    final plan = await ChatPayloadMigrationService.plan(userId);
    if (_userId != userId) return;
    if (!plan.hasWork) {
      _release();
      return;
    }
    _plan = plan;
    await _run();
  }

  Future<void> _run() async {
    final plan = _plan;
    if (plan == null) return;
    _failure = null;
    _progress = ChatMaintenanceProgress(total: plan.total);
    _set(ChatMaintenancePhase.running);
    try {
      await ChatPayloadMigrationService.execute(
        plan,
        onProgress: (p) {
          _progress = p;
          notifyListeners();
        },
      );
      _release();
    } on ChatMaintenanceFailure catch (e) {
      _failure = e;
      _set(ChatMaintenancePhase.failed);
    } catch (e) {
      _failure = ChatMaintenanceFailure('unexpected', e);
      _set(ChatMaintenancePhase.failed);
    }
  }

  /// Try again after a failure: plan anew (the cache was restored).
  Future<void> retry() async {
    final userId = _userId;
    if (userId == null || _phase != ChatMaintenancePhase.failed) return;
    _set(ChatMaintenancePhase.checking);
    final plan = await ChatPayloadMigrationService.plan(userId);
    if (!plan.hasWork) {
      _release();
      return;
    }
    _plan = plan;
    await _run();
  }

  /// Go on to the app after a failure. Safe: the reader reads v1 and v2,
  /// and the cache was restored.
  void continueAnyway() {
    if (_phase != ChatMaintenancePhase.failed) return;
    _release();
  }

  void _release() {
    _set(ChatMaintenancePhase.done);
    final released = _released;
    if (released != null && !released.isCompleted) released.complete();
  }

  void _set(ChatMaintenancePhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// Put the controller into [phase] with [progress] (widget tests).
  @visibleForTesting
  void debugShow(
    ChatMaintenancePhase phase, {
    ChatMaintenanceProgress progress = const ChatMaintenanceProgress(),
    ChatMaintenanceFailure? failure,
    bool syncHint = false,
  }) {
    _progress = progress;
    _failure = failure;
    _showsSyncHint = syncHint;
    _set(phase);
  }

  /// Forget the run (sign-out, tests). The session the app started with is
  /// kept; a real sign-out forgets it ([forgetRestoredSession]).
  void reset() {
    final released = _released;
    if (released != null && !released.isCompleted) released.complete();
    _released = null;
    _userId = null;
    _showsSyncHint = false;
    _plan = null;
    _failure = null;
    _progress = const ChatMaintenanceProgress();
    _phase = ChatMaintenancePhase.idle;
    notifyListeners();
  }
}

enum ChatMaintenancePhase { idle, checking, running, failed, done }
