// lib/services/offline_queue_service_web.dart
// Web fallback: SharedPreferences-backed offline outbox. Same API and same
// rules as the native store (docs/OFFLINE_SEND.md); rows are a JSON list
// under one key. Old rows (no owner, plaintext) are claimed and sealed by
// the first signed-in user.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';

class OfflineQueueService {
  OfflineQueueService._();

  static final OfflineQueueService instance = OfflineQueueService._();

  /// Test-only overrides — accepted on web for analyzer parity with the
  /// native implementation.
  @visibleForTesting
  // ignore: prefer_typing_uninitialized_variables, unused_field
  static dynamic debugDatabasePath;
  @visibleForTesting
  // ignore: prefer_typing_uninitialized_variables, unused_field
  static dynamic debugDatabaseFactory;

  static const String _prefsKey = 'offline_queue_v1';
  static const Uuid _uuid = Uuid();

  final StreamController<List<QueuedMessage>> _watchCtrl =
      StreamController<List<QueuedMessage>>.broadcast();

  Future<List<Map<String, dynamic>>> _readRaw() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList(growable: true);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _writeRaw(List<Map<String, dynamic>> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(rows));
  }

  Future<({String value, int encrypted})> _seal(
    Map<String, dynamic> payload,
  ) async {
    final plain = jsonEncode(payload);
    final sealed = await OutboxCipher.seal(plain);
    if (sealed == null) return (value: plain, encrypted: 0);
    return (value: sealed, encrypted: 1);
  }

  Future<QueuedMessage> _fromRaw(Map<String, dynamic> row) async {
    final raw = row['message_json'];
    if (row['encrypted'] == 1 && raw is String) {
      try {
        final plain = await OutboxCipher.open(raw);
        return QueuedMessage.fromRow(
          row,
          payloadOverride: QueuedMessage.decodePayload(plain),
        );
      } catch (_) {
        return QueuedMessage.fromRow(
          row,
          payloadOverride: <String, dynamic>{},
          locked: true,
        );
      }
    }
    return QueuedMessage.fromRow(row);
  }

  Future<List<QueuedMessage>> _sorted(
    Iterable<Map<String, dynamic>> raw,
  ) async {
    final out = <QueuedMessage>[];
    for (final r in raw) {
      out.add(await _fromRaw(r));
    }
    out.sort((a, b) {
      final c = a.seq.compareTo(b.seq);
      return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
    });
    return out;
  }

  int _asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  Future<void> init() async {
    // Old rows have no seq: give them one in created_at order.
    final rows = await _readRaw();
    if (rows.isEmpty || rows.every((r) => r['seq'] != null)) return;
    rows.sort(
      (a, b) => _asInt(a['created_at']).compareTo(_asInt(b['created_at'])),
    );
    for (var i = 0; i < rows.length; i++) {
      rows[i]['seq'] ??= i + 1;
    }
    await _writeRaw(rows);
  }

  Future<int> sealPlaintextRows(String userId) async {
    if (!OutboxCipher.canOpen()) return 0;
    final rows = await _readRaw();
    var n = 0;
    for (final r in rows) {
      if (r['encrypted'] == 1 || r['user_id'] != userId) continue;
      final s = await _seal(QueuedMessage.decodePayload(r['message_json']));
      if (s.encrypted == 0) break;
      r['message_json'] = s.value;
      r['encrypted'] = 1;
      n++;
    }
    if (n > 0) await _writeRaw(rows);
    return n;
  }

  Future<int> claimLegacyRows(String userId) async {
    final rows = await _readRaw();
    var n = 0;
    for (final r in rows) {
      if (r['user_id'] == null) {
        r['user_id'] = userId;
        n++;
      }
    }
    if (n == 0) return 0;
    await _writeRaw(rows);
    await sealPlaintextRows(userId);
    await _emit();
    return n;
  }

  Future<String> enqueue({
    required String chatId,
    required Map<String, dynamic> sendPayload,
    String? id,
    String kind = OutboxKind.text,
    String? userId,
    OutboxState state = OutboxState.queued,
  }) async {
    final rows = await _readRaw();
    final now = DateTime.now().millisecondsSinceEpoch;
    final queueId = id ?? _uuid.v4();
    final sealed = await _seal(sendPayload);
    var maxSeq = 0;
    for (final r in rows) {
      final s = _asInt(r['seq']);
      if (s > maxSeq) maxSeq = s;
    }
    rows.removeWhere((r) => r['id'] == queueId);
    rows.add(<String, dynamic>{
      'id': queueId,
      'chat_id': chatId,
      'message_json': sealed.value,
      'encrypted': sealed.encrypted,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
      'user_id': userId ?? OutboxCipher.currentUserId(),
      'kind': kind,
      'state': state.name,
      'next_attempt_at': 0,
      'seq': maxSeq + 1,
    });
    await _writeRaw(rows);
    if (kDebugMode) {
      debugPrint('[OfflineQueue] enqueued id=$queueId chat=$chatId');
    }
    await _emit();
    return queueId;
  }

  Future<void> _mutate(String id, void Function(Map<String, dynamic>) f) async {
    final rows = await _readRaw();
    final idx = rows.indexWhere((r) => r['id'] == id);
    if (idx == -1) return;
    f(rows[idx]);
    rows[idx]['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await _writeRaw(rows);
    await _emit();
  }

  Future<void> updatePayload(String id, Map<String, dynamic> payload) async {
    final sealed = await _seal(payload);
    await _mutate(id, (r) {
      r['message_json'] = sealed.value;
      r['encrypted'] = sealed.encrypted;
    });
  }

  Future<void> setState(
    String id,
    OutboxState state, {
    String? error,
    bool clearError = false,
    int? nextAttemptAt,
    bool bumpAttempts = false,
    bool resetAttempts = false,
  }) => _mutate(id, (r) {
    r['state'] = state.name;
    if (error != null) {
      r['last_error'] = error;
    } else if (clearError) {
      r['last_error'] = null;
    }
    if (nextAttemptAt != null) r['next_attempt_at'] = nextAttemptAt;
    if (resetAttempts) {
      r['attempt_count'] = 0;
    } else if (bumpAttempts) {
      r['attempt_count'] = _asInt(r['attempt_count']) + 1;
    }
  });

  Future<void> markFailed(String id, String error) =>
      setState(id, OutboxState.failed, error: error, bumpAttempts: true);

  Future<void> incrementAttempts(String id) => _mutate(id, (r) {
    r['attempt_count'] = _asInt(r['attempt_count']) + 1;
  });

  Future<void> requeue(String id) => setState(
    id,
    OutboxState.queued,
    clearError: true,
    nextAttemptAt: 0,
    resetAttempts: true,
  );

  Future<int> recoverInterrupted() async {
    final rows = await _readRaw();
    var n = 0;
    for (final r in rows) {
      if (r['state'] == 'preparing' || r['state'] == 'sending') {
        r['state'] = 'queued';
        n++;
      }
    }
    if (n > 0) {
      await _writeRaw(rows);
      await _emit();
    }
    return n;
  }

  Future<void> remove(String id) async {
    final rows = await _readRaw();
    final before = rows.length;
    rows.removeWhere((r) => r['id'] == id);
    if (rows.length == before) return;
    await _writeRaw(rows);
    await _emit();
  }

  /// Sign-out: the rows of [userId] and the rows with no owner go (see the
  /// native store).
  Future<List<QueuedMessage>> wipeUser(String userId) async {
    final rows = await _readRaw();
    bool gone(Map<String, dynamic> r) =>
        r['user_id'] == userId || r['user_id'] == null;
    final removed = rows
        .where(gone)
        .map((r) => QueuedMessage.fromRow(r, payloadOverride: const {}))
        .toList(growable: false);
    rows.removeWhere(gone);
    await _writeRaw(rows);
    await _emit();
    return removed;
  }

  Future<List<QueuedMessage>> listForChat(String chatId) async =>
      _sorted((await _readRaw()).where((r) => r['chat_id'] == chatId));

  Future<List<QueuedMessage>> listAll({String? userId}) async => _sorted(
    (await _readRaw()).where((r) => userId == null || r['user_id'] == userId),
  );

  Future<QueuedMessage?> getById(String id) async {
    for (final r in await _readRaw()) {
      if (r['id'] == id) return _fromRaw(r);
    }
    return null;
  }

  Future<int> count({String? userId}) async => (await _readRaw())
      .where((r) => userId == null || r['user_id'] == userId)
      .length;

  Stream<List<QueuedMessage>> watch() => _watchCtrl.stream;

  Future<void> _emit() async {
    if (_watchCtrl.isClosed || !_watchCtrl.hasListener) return;
    try {
      _watchCtrl.add(await listAll());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OfflineQueue] watch emit failed: $e');
      }
    }
  }

  @visibleForTesting
  Future<void> debugClearAll() async {
    await _writeRaw(<Map<String, dynamic>>[]);
    await _emit();
  }

  @visibleForTesting
  Future<List<Map<String, Object?>>> debugRawRows() async =>
      (await _readRaw()).cast<Map<String, Object?>>();

  @visibleForTesting
  Future<void> debugReset() async {}
}
