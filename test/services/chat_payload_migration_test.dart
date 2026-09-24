// The blocking maintenance run that rewrites every chat to payload v3:
// backup, local rewrite + verification against a real SQLite file, restore on
// failure, the cloud part with the `updated_at + 1 µs` guard (a fake cloud
// with real AES envelopes), progress counts and the done flag.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/chat_dirty_store.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/chat_payload_migration_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/payload_compression.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/kv_cache_test_env.dart';

const String userId = 'user-1';

String _id(int i) => '3f2b8c1e-4a5d-4e6f-9a7b-00000000000$i';

String _updatedAt(int i) => '2026-09-0${i + 1}T10:00:00.12345$i+00:00';

String _v2Json(int i) {
  final calls = [
    {'id': 'c$i', 'name': 'search', 'result': List.filled(60, 'r$i ').join()},
  ];
  return jsonEncode({
    'v': 2,
    'messages': [
      ChatMessage(role: 'user', text: 'Frage $i').toJson(),
      ChatMessage(
        role: 'assistant',
        text: 'Antwort $i',
        toolCalls: jsonEncode(calls),
        contentBlocks: jsonEncode([
          {'type': 'toolCalls', 'toolCalls': calls},
        ]),
      ).toJson(),
    ],
    'customName': 'Chat $i',
  });
}

Future<String> _sealV1(String text, List<int> key) async {
  final rng = Random.secure();
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(text),
    secretKey: SecretKey(key),
    nonce: List<int>.generate(12, (_) => rng.nextInt(256)),
  );
  return jsonEncode({
    'v': '1',
    'kv': 1,
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  });
}

/// An in-memory `encrypted_chats` with the prod trigger's rule: a written
/// `updated_at` is kept when the client changed it, else it becomes "now".
class _FakeCloud implements ChatMigrationCloud {
  _FakeCloud(this.key);

  final List<int> key;
  final Map<String, ({String encrypted, String updatedAt})> rows = {};
  final List<String> writes = [];
  bool offline = false;

  /// Simulates another device saving a chat between read and write.
  String? changeBeforeWrite;

  @override
  Future<List<String>> listPlainEnvelopeChats(String userId) async {
    if (offline) throw const SocketException('offline');
    return [
      for (final e in rows.entries)
        if (e.value.encrypted.startsWith('{"v":"1"')) e.key,
    ];
  }

  @override
  Future<({String encrypted, String updatedAt})?> readRow(
    String userId,
    String chatId,
  ) async => rows[chatId];

  @override
  Future<String?> writeRow(
    String userId,
    String chatId, {
    required String encrypted,
    required String updatedAt,
    required String expectedUpdatedAt,
  }) async {
    if (changeBeforeWrite == chatId) {
      final row = rows[chatId]!;
      rows[chatId] = (
        encrypted: row.encrypted,
        updatedAt: '2026-09-24T12:00:00.000000+00:00',
      );
    }
    final row = rows[chatId];
    if (row == null || row.updatedAt != expectedUpdatedAt) return null;
    final stored = updatedAt == row.updatedAt
        ? '2026-09-24T12:00:00.000000+00:00' // the trigger's NOW()
        : updatedAt;
    rows[chatId] = (encrypted: encrypted, updatedAt: stored);
    writes.add(chatId);
    return stored;
  }

  @override
  Future<ChatEnvelopeV3?> convert(String encrypted) => convertChatEnvelopeToV3(
    encrypted: encrypted,
    keyBytes: key,
    keyVersion: 1,
  );

  @override
  Future<String> fingerprint(String encrypted) =>
      chatEnvelopeFingerprint(encrypted, key);

  @override
  int get currentKeyVersion => 1;

  @override
  Future<bool> ensureKey() async => true;
}

void main() {
  late Directory tempDir;
  late _FakeCloud cloud;

  setUp(() async {
    tempDir = await useTempKvCache();
    await ChatStorageState.reset();
    ChatDirtyStore.reset();
    final rng = Random.secure();
    cloud = _FakeCloud(List<int>.generate(32, (_) => rng.nextInt(256)));
    ChatPayloadMigrationService.cloud = cloud;
    ChatPayloadMigrationService.hasLocalDatabase = true;
    ChatPayloadMigrationService.debugBeforeLocalVerify = null;
    ChatMaintenanceController.instance.reset();
  });

  tearDown(() async {
    ChatPayloadMigrationService.cloud = const SupabaseChatMigrationCloud();
    ChatPayloadMigrationService.debugBeforeLocalVerify = null;
    ChatMaintenanceController.instance.reset();
    await ChatStorageState.reset();
    await disposeTempKvCache(tempDir);
  });

  Future<Database> rawDb() =>
      databaseFactoryFfi.openDatabase(p.join(tempDir.path, 'chat_cache.db'));

  /// A cache row the way it was stored before v3: gzip of v2 JSON.
  Future<void> seedLocal(int i) async {
    await LocalChatCacheService.upsert(
      userId,
      LocalChatCacheService.buildPlaintextRow(
        id: _id(i),
        payload: _v2Json(i),
        createdAt: '2026-08-01T10:00:00.000Z',
        isStarred: false,
        updatedAt: _updatedAt(i),
        title: 'Chat $i',
      ),
    );
    final db = await rawDb();
    await db.rawUpdate('UPDATE chat_cache SET payload = ? WHERE id = ?', [
      GZipCodec(level: 4).encode(utf8.encode(_v2Json(i))),
      _id(i),
    ]);
  }

  Future<void> seedCloud(int i) async {
    cloud.rows[_id(i)] = (
      encrypted: await _sealV1(_v2Json(i), cloud.key),
      updatedAt: _updatedAt(i),
    );
  }

  group('updated_at + 1 µs', () {
    test('adds one microsecond, in UTC, with six digits', () {
      expect(
        bumpTimestampByOneMicrosecond('2026-09-01T10:00:00.123456+00:00'),
        '2026-09-01T10:00:00.123457+00:00',
      );
      expect(
        bumpTimestampByOneMicrosecond('2026-09-01T10:00:00+02:00'),
        '2026-09-01T08:00:00.000001+00:00',
      );
      expect(
        bumpTimestampByOneMicrosecond('2026-09-01T10:00:00.5Z'),
        '2026-09-01T10:00:00.500001+00:00',
      );
      expect(
        bumpTimestampByOneMicrosecond('2026-12-31T23:59:59.999999+00'),
        '2027-01-01T00:00:00.000000+00:00',
      );
      expect(
        () => bumpTimestampByOneMicrosecond('yesterday'),
        throwsFormatException,
      );
    });
  });

  test('a full run: backup, local and cloud to v3, verified, done', () async {
    for (var i = 0; i < 3; i++) {
      await seedLocal(i);
      await seedCloud(i);
    }

    final plan = await ChatPayloadMigrationService.plan(userId);
    expect(plan.localIds.length, 3);
    expect(plan.cloud.length, 3);
    expect(plan.total, 6);

    final seen = <ChatMaintenanceProgress>[];
    var backupDuringRun = false;
    ChatPayloadMigrationService.debugBeforeLocalVerify = () async {
      backupDuringRun = await LocalChatCacheService.hasBackup();
    };
    final outcome = await ChatPayloadMigrationService.execute(
      plan,
      onProgress: seen.add,
    );

    expect(outcome, ChatMaintenanceOutcome.complete);
    expect(backupDuringRun, isTrue);
    expect(await LocalChatCacheService.hasBackup(), isFalse);
    expect(seen.last.migrated, 6);
    expect(seen.last.verified, 6);
    for (var k = 1; k < seen.length; k++) {
      expect(seen[k].migrated, greaterThanOrEqualTo(seen[k - 1].migrated));
      expect(seen[k].verified, lessThanOrEqualTo(seen[k].migrated));
    }

    for (var i = 0; i < 3; i++) {
      // Cache: a v3 frame with the same messages.
      final raw = await LocalChatCacheService.loadRawById(userId, _id(i));
      expect(raw!.framed, isTrue);
      final payload = raw.row['payload'] as String;
      expect(peekChatPayloadVersion(payload), 3);
      expect(
        chatPayloadsEquivalent(
          decodeChatPayload(payload),
          decodeChatPayload(_v2Json(i)),
        ),
        isTrue,
      );
      // Cloud: compressed envelope, updated_at moved by exactly 1 µs, and
      // the cache row follows it (no re-download at the next sync).
      final row = cloud.rows[_id(i)]!;
      expect(envelopeVersionOf(row.encrypted), kCompressedEnvelopeVersion);
      expect(row.updatedAt, '2026-09-0${i + 1}T10:00:00.12345${i + 1}+00:00');
      expect(raw.row['updated_at'], row.updatedAt);
      final opened = await openEnvelopeText(row.encrypted, cloud.key);
      expect(
        chatPayloadsEquivalent(
          decodeChatPayload(opened),
          decodeChatPayload(_v2Json(i)),
        ),
        isTrue,
      );
    }

    expect(await ChatPayloadMigrationService.isDone(userId), isTrue);
    final again = await ChatPayloadMigrationService.plan(userId);
    expect(again.hasWork, isFalse);
  });

  test('a local fault restores the backup and reports it', () async {
    for (var i = 0; i < 2; i++) {
      await seedLocal(i);
    }
    final plan = await ChatPayloadMigrationService.plan(userId);
    ChatPayloadMigrationService.debugBeforeLocalVerify = () async {
      // Break one rewritten row: another chat's content in its place.
      final db = await rawDb();
      await db.rawUpdate('UPDATE chat_cache SET payload = ? WHERE id = ?', [
        compressPayloadFast(toChatPayloadV3(_v2Json(7))),
        _id(0),
      ]);
    };

    await expectLater(
      ChatPayloadMigrationService.execute(plan),
      throwsA(
        isA<ChatMaintenanceFailure>()
            .having((f) => f.stage, 'stage', 'local')
            .having((f) => f.restored, 'restored', isTrue),
      ),
    );

    // Both rows are back as they were before the run.
    for (var i = 0; i < 2; i++) {
      final raw = await LocalChatCacheService.loadRawById(userId, _id(i));
      expect(raw!.framed, isFalse);
      expect(raw.row['payload'], _v2Json(i));
    }
    expect(await ChatPayloadMigrationService.isDone(userId), isFalse);
    expect(cloud.writes, isEmpty);
  });

  test('a chat changed during the run waits for the next start', () async {
    await seedCloud(0);
    await seedCloud(1);
    cloud.changeBeforeWrite = _id(1);

    final plan = await ChatPayloadMigrationService.plan(userId);
    final outcome = await ChatPayloadMigrationService.execute(plan);

    expect(outcome, ChatMaintenanceOutcome.cloudPending);
    expect(cloud.writes, [_id(0)]);
    // The other device's save was not overwritten.
    expect(envelopeVersionOf(cloud.rows[_id(1)]!.encrypted), '1');
    expect(await ChatPayloadMigrationService.isDone(userId), isFalse);

    cloud.changeBeforeWrite = null;
    final next = await ChatPayloadMigrationService.plan(userId);
    expect(next.cloud, [_id(1)]);
  });

  test('offline: the local part completes, the cloud waits', () async {
    await seedLocal(0);
    await seedCloud(0);
    cloud.offline = true;

    final plan = await ChatPayloadMigrationService.plan(userId);
    expect(plan.cloudKnown, isFalse);
    expect(plan.cloud, isEmpty);
    final outcome = await ChatPayloadMigrationService.execute(plan);

    expect(outcome, ChatMaintenanceOutcome.cloudPending);
    expect(
      (await LocalChatCacheService.loadRawById(userId, _id(0)))!.framed,
      isTrue,
    );
    expect(await ChatPayloadMigrationService.isDone(userId), isFalse);

    cloud.offline = false;
    final next = await ChatPayloadMigrationService.plan(userId);
    expect(next.localIds, isEmpty);
    expect(next.cloud, [_id(0)]);
  });

  test('dirty and locked chats are skipped, not rewritten', () async {
    await seedCloud(0);
    await seedCloud(1);
    await ChatDirtyStore.markDirty(userId, _id(0), pendingInsert: false);
    // Chat 1 is sealed with another key: locked.
    final rng = Random.secure();
    cloud.rows[_id(1)] = (
      encrypted: await _sealV1(
        _v2Json(1),
        List<int>.generate(32, (_) => rng.nextInt(256)),
      ),
      updatedAt: _updatedAt(1),
    );

    final plan = await ChatPayloadMigrationService.plan(userId);
    expect(plan.cloud, [_id(1)]); // the dirty one is not even planned
    final outcome = await ChatPayloadMigrationService.execute(plan);

    expect(outcome, ChatMaintenanceOutcome.complete);
    expect(cloud.writes, isEmpty);
    final next = await ChatPayloadMigrationService.plan(userId);
    expect(next.hasWork, isFalse);
  });

  test('the controller holds the app until the run is over', () async {
    await seedLocal(0);
    final controller = ChatMaintenanceController.instance;
    final phases = <ChatMaintenancePhase>[];
    controller.addListener(() => phases.add(controller.phase));

    await controller.ensureReady(userId);

    expect(phases, contains(ChatMaintenancePhase.running));
    expect(controller.phase, ChatMaintenancePhase.done);
    expect(controller.holdsApp, isFalse);
    expect(controller.progress.migrated, 1);
    expect(controller.progress.verified, 1);
  });

  test('after a failure the user can continue to the app', () async {
    await seedLocal(0);
    ChatPayloadMigrationService.debugBeforeLocalVerify = () async {
      final db = await rawDb();
      await db.rawUpdate('DELETE FROM chat_cache WHERE id = ?', [_id(0)]);
    };
    final controller = ChatMaintenanceController.instance;
    var released = false;
    final ready = controller.ensureReady(userId).then((_) => released = true);

    while (controller.phase != ChatMaintenancePhase.failed) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.holdsApp, isTrue);
    expect(controller.failure?.restored, isTrue);
    expect(released, isFalse);
    // The restore put the row back.
    expect(await LocalChatCacheService.loadRawById(userId, _id(0)), isNotNull);

    controller.continueAnyway();
    await ready;
    expect(released, isTrue);
    expect(controller.holdsApp, isFalse);
  });
}
