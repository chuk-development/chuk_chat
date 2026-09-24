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
//    cloud error: the local part is complete, the cloud chats that are left
//    are found again at the next start (their envelope is still v1), and the
//    screen shows again only for them. No state is half written: each cloud
//    chat is one UPDATE, and the cache is restored as a whole.
//
// Skipped: dirty chats (their next cloud save is v3 anyway), locked chats
// (another key; the recovery flow rewrites them as v3), Agents threads (a
// separate table and format). Nothing streams while the screen is up.
//
// Web: no cache database, so only the cloud part runs, behind the same screen.

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/services/chat_dirty_store.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:cryptography/cryptography.dart'
    show SecretBoxAuthenticationError;
import 'package:flutter/foundation.dart';

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
  });

  final String userId;

  /// Cache rows that are not a v3 frame yet.
  final List<String> localIds;

  /// Cloud chats with a `{"v":"1"}` envelope, minus skipped and dirty ones.
  final List<String> cloud;

  /// Whether the cloud list is complete (false: offline, no key, an error).
  final bool cloudKnown;

  int get total => localIds.length + cloud.length;
  bool get hasWork => total > 0;
}

/// How a run ended.
enum ChatMaintenanceOutcome {
  /// Everything is v3 (or skipped for good). The done flag is set.
  complete,

  /// Local part complete; some cloud chats wait for the next start.
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

  /// Test seams.
  @visibleForTesting
  static ChatMigrationCloud cloud = const SupabaseChatMigrationCloud();
  @visibleForTesting
  static Future<String?> Function(String key) readKv =
      LocalChatCacheService.kvGet;
  @visibleForTesting
  static Future<void> Function(String key, String value) writeKv =
      LocalChatCacheService.kvSet;

  /// Called between the local rewrite and its verification (tests break a
  /// row here to prove the restore).
  @visibleForTesting
  static Future<void> Function()? debugBeforeLocalVerify;

  /// Whether this platform has a cache database to upgrade.
  @visibleForTesting
  static bool hasLocalDatabase = !kIsWeb;

  static String _stateKey(String userId) => 'chat_payload_v3_migration_$userId';

  /// What is left to do for [userId]; an empty plan when the account is
  /// done. Never throws: a cloud list that cannot be read is left for later.
  static Future<ChatMaintenancePlan> plan(String userId) async {
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
    if (hasLocalDatabase) {
      try {
        localIds = [
          for (final id in await LocalChatCacheService.idsNeedingPayloadUpgrade(
            userId,
          ))
            if (!ChatOrigin.isAgentsThread(id) && !state.skip.contains(id)) id,
        ];
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ [PayloadV3] cache scan failed: $e');
      }
    }

    var cloudIds = const <String>[];
    var cloudKnown = false;
    try {
      if (await cloud.ensureKey()) {
        cloudIds = [
          for (final id in await cloud.listPlainEnvelopeChats(userId))
            if (!state.skip.contains(id) && !ChatDirtyStore.isDirty(id)) id,
        ];
        cloudKnown = true;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [PayloadV3] cloud scan failed: ${e.runtimeType}');
      }
    }

    final plan = ChatMaintenancePlan(
      userId: userId,
      localIds: localIds,
      cloud: cloudIds,
      cloudKnown: cloudKnown,
    );
    if (!plan.hasWork && cloudKnown) {
      state.done = true;
      await _saveState(userId, state);
    }
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
        throw ChatMaintenanceFailure('backup', e);
      }
    }

    // ── 2. + 3. Local rewrite and verification ───────────────────────────
    final rewritten = <String, String>{}; // id -> original fingerprint
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
        await _verifyLocalRow(userId, entry.key, entry.value);
        report(progress.copyWith(verified: progress.verified + 1));
      }
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
      throw ChatMaintenanceFailure('local', e, restored: restored);
    }

    // ── 4. Cloud ──────────────────────────────────────────────────────────
    var cloudPending = !plan.cloudKnown;
    ChatMaintenanceFailure? cloudFailure;
    var stop = false;
    await _pool(plan.cloud, (id) async {
      if (stop) return;
      try {
        final result = await _migrateCloudChat(userId, id, state);
        if (result == _CloudResult.pending) cloudPending = true;
      } on ChatMaintenanceFailure catch (e) {
        cloudFailure ??= e;
        stop = true;
      } catch (e) {
        // Offline or a server error: the rest waits for the next start.
        cloudPending = true;
        if (NetworkStatusService.isNetworkError(e) || e is TimeoutException) {
          stop = true;
        }
        if (kDebugMode) {
          debugPrint('⚠️ [PayloadV3] cloud chat failed: ${e.runtimeType}');
        }
      }
      report(
        progress.copyWith(
          migrated: progress.migrated + 1,
          verified: progress.verified + 1,
        ),
      );
    }, shouldStop: () => stop);
    if (stop) cloudPending = true;

    // ── 5. Done ───────────────────────────────────────────────────────────
    if (!cloudPending && cloudFailure == null) state.done = true;
    await _saveState(userId, state);
    if (useBackup) {
      try {
        await LocalChatCacheService.deleteBackup();
      } catch (_) {
        // A stale backup is replaced by the next run.
      }
    }
    if (cloudFailure != null) throw cloudFailure!;
    return state.done
        ? ChatMaintenanceOutcome.complete
        : ChatMaintenanceOutcome.cloudPending;
  }

  /// Rewrite one cache row as v3. Returns the fingerprint of its original
  /// messages, or null when there was nothing to do.
  static Future<String?> _migrateLocalRow(
    String userId,
    String chatId,
    _MigrationState state,
  ) async {
    final raw = await LocalChatCacheService.loadRawById(userId, chatId);
    if (raw == null) return null;
    final payload = raw.row['payload'];
    if (payload is! String || payload.isEmpty) return null;
    ({String v3, String fingerprint})? converted;
    try {
      converted = await compute(convertChatPayloadToV3WithFingerprint, payload);
    } on FormatException {
      converted = null;
    } on UnsupportedError {
      converted = null;
    }
    if (converted == null) {
      // Not a payload this app can prove in v3 (unparseable, or the proof
      // failed): the row stays as it is and readable, and is not retried.
      state.skip.add(chatId);
      return null;
    }
    final written = await LocalChatCacheService.replacePayloadIfUnchanged(
      userId,
      chatId,
      payload: converted.v3,
      expectedUpdatedAt: raw.row['updated_at'] as String?,
      expectedStoredLength: raw.storedLength,
    );
    if (!written) throw StateError('A cached chat changed during the rewrite');
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
      state.skip.add(chatId);
      return _CloudResult.skipped;
    }

    final ChatEnvelopeV3? converted;
    try {
      converted = await cloud.convert(row.encrypted);
    } on SecretBoxAuthenticationError {
      // Not decryptable with this key: a locked chat, left for recovery.
      state.skip.add(chatId);
      return _CloudResult.skipped;
    } on FormatException {
      state.skip.add(chatId); // not a chat payload
      return _CloudResult.skipped;
    } on UnsupportedError {
      state.skip.add(chatId); // a payload version this app does not know
      return _CloudResult.skipped;
    }
    // Anything else (no key any more, a signed-out user) propagates and
    // leaves the chat for the next start.
    if (converted == null) {
      state.skip.add(chatId);
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
      state.skip.add(chatId);
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

  /// Run [work] over [items], at most [parallelism] at a time.
  static Future<void> _pool(
    List<String> items,
    Future<void> Function(String item) work, {
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
      for (var i = 0; i < parallelism && i < items.length; i++) worker(),
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
      if (kDebugMode) debugPrint('⚠️ [PayloadV3] state not saved: $e');
    }
  }

  /// Whether the migration of [userId] is recorded as done.
  @visibleForTesting
  static Future<bool> isDone(String userId) async =>
      (await _loadState(userId)).done;
}

enum _CloudResult { done, skipped, pending }

/// Persisted progress of one account: the done flag and the chats that are
/// never retried (locked with another key, or failed the proof). Which cloud
/// chats are left is read from the cloud itself: a `{"v":"1"}` envelope.
class _MigrationState {
  _MigrationState({this.done = false, Set<String>? skip})
    : skip = skip ?? <String>{};

  factory _MigrationState.fromJson(Map<String, dynamic> json) =>
      _MigrationState(
        done: json['done'] == true,
        skip: json['skip'] is List
            ? (json['skip'] as List).whereType<String>().toSet()
            : null,
      );

  bool done;
  final Set<String> skip;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'done': done,
    'skip': skip.toList(),
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

  ChatMaintenancePhase get phase => _phase;
  ChatMaintenanceProgress get progress => _progress;
  ChatMaintenanceFailure? get failure => _failure;

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
    _set(ChatMaintenancePhase.checking);
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
  }) {
    _progress = progress;
    _failure = failure;
    _set(phase);
  }

  /// Forget the run (sign-out, tests).
  void reset() {
    final released = _released;
    if (released != null && !released.isCompleted) released.complete();
    _released = null;
    _userId = null;
    _plan = null;
    _failure = null;
    _progress = const ChatMaintenanceProgress();
    _phase = ChatMaintenancePhase.idle;
    notifyListeners();
  }
}

enum ChatMaintenancePhase { idle, checking, running, failed, done }
