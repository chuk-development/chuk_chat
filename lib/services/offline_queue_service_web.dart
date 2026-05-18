// lib/services/offline_queue_service_web.dart
// Web fallback: SharedPreferences-backed offline message queue.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/queued_message.dart';

/// SharedPreferences-backed persistent queue used on web where SQLite is not
/// available.  Stores entries as a JSON list under a single key.
class OfflineQueueService {
  OfflineQueueService._();

  static final OfflineQueueService instance = OfflineQueueService._();

  /// Test-only overrides — accepted on web for analyzer parity with the
  /// native implementation. No effect since SharedPreferences is in-memory in
  /// the test environment.
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

  Future<List<QueuedMessage>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <QueuedMessage>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <QueuedMessage>[];
      return decoded
          .whereType<Map>()
          .map((m) => QueuedMessage.fromRow(m.cast<String, dynamic>()))
          .toList(growable: true);
    } catch (_) {
      return <QueuedMessage>[];
    }
  }

  Future<void> _write(List<QueuedMessage> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(rows.map((r) => r.toRow()).toList(growable: false)),
    );
  }

  Future<void> init() async {
    // No-op — prefs are loaded lazily.
  }

  Future<String> enqueue({
    required String chatId,
    required Map<String, dynamic> sendPayload,
    String? id,
  }) async {
    final rows = await _read();
    final now = DateTime.now().millisecondsSinceEpoch;
    final queueId = id ?? _uuid.v4();
    rows.add(
      QueuedMessage(
        id: queueId,
        chatId: chatId,
        sendPayload: sendPayload,
        attemptCount: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _write(rows);
    if (kDebugMode) {
      debugPrint('[OfflineQueue] enqueued id=$queueId chat=$chatId');
    }
    await _emit();
    return queueId;
  }

  Future<void> markFailed(String id, String error) async {
    final rows = await _read();
    final now = DateTime.now().millisecondsSinceEpoch;
    final idx = rows.indexWhere((r) => r.id == id);
    if (idx == -1) return;
    rows[idx] = rows[idx].copyWith(
      attemptCount: rows[idx].attemptCount + 1,
      lastError: error,
      updatedAt: now,
    );
    await _write(rows);
    await _emit();
  }

  Future<void> incrementAttempts(String id) async {
    final rows = await _read();
    final now = DateTime.now().millisecondsSinceEpoch;
    final idx = rows.indexWhere((r) => r.id == id);
    if (idx == -1) return;
    rows[idx] = rows[idx].copyWith(
      attemptCount: rows[idx].attemptCount + 1,
      updatedAt: now,
    );
    await _write(rows);
    await _emit();
  }

  Future<void> remove(String id) async {
    final rows = await _read();
    final before = rows.length;
    rows.removeWhere((r) => r.id == id);
    if (rows.length == before) return;
    await _write(rows);
    await _emit();
  }

  Future<List<QueuedMessage>> listForChat(String chatId) async {
    final rows = await _read();
    final filtered = rows.where((r) => r.chatId == chatId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return filtered;
  }

  Future<List<QueuedMessage>> listAll() async {
    final rows = await _read();
    rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return rows;
  }

  Future<QueuedMessage?> getById(String id) async {
    final rows = await _read();
    for (final r in rows) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<int> count() async => (await _read()).length;

  Stream<List<QueuedMessage>> watch() => _watchCtrl.stream;

  Future<void> _emit() async {
    if (_watchCtrl.isClosed) return;
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
    await _write(<QueuedMessage>[]);
    await _emit();
  }

  @visibleForTesting
  Future<void> debugReset() async {}
}
