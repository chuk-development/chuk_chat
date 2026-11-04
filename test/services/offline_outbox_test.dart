// test/services/offline_outbox_test.dart
//
// The offline outbox (docs/OFFLINE_SEND.md): sealing at rest, the version-1
// migration, ownership and sign-out wipe, and the flush rules (per-chat order,
// stop at the first failure, backoff, failed rows are never retried by
// themselves, accepted sends are not re-sent, preparers, hold).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';

void main() {
  final queue = OfflineQueueService.instance;
  final manager = OfflineRetryManager.instance;

  setUpAll(() {
    sqfliteFfiInit();
    OfflineQueueService.debugDatabaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    OfflineQueueService.debugDatabasePath = inMemoryDatabasePath;
    await queue.debugReset();
    await queue.init();
    await queue.debugClearAll();
    manager.debugReset();
    OutboxCipher.useFake(userId: 'u1');
  });

  tearDown(() {
    OutboxCipher.reset();
    OfflineRetryManager.now = () => DateTime.now().millisecondsSinceEpoch;
  });

  group('storage', () {
    test('payload is sealed at rest and opened on read', () async {
      final id = await queue.enqueue(
        chatId: 'c',
        sendPayload: {'messageText': 'secret words'},
      );
      final raw = await queue.debugRawRows();
      expect(raw.single['encrypted'], 1);
      expect('${raw.single['message_json']}', isNot(contains('secret')));
      final row = await queue.getById(id);
      expect(row!.sendPayload['messageText'], 'secret words');
      expect(row.userId, 'u1');
      expect(row.state, OutboxState.queued);
    });

    test('without a key the row stays plaintext and is sealed later',
        () async {
      OutboxCipher.useFake(userId: 'u1', withKey: false);
      final id = await queue.enqueue(
        chatId: 'c',
        sendPayload: {'messageText': 'early'},
      );
      expect((await queue.debugRawRows()).single['encrypted'], 0);
      OutboxCipher.useFake(userId: 'u1');
      expect(await queue.sealPlaintextRows('u1'), 1);
      final raw = await queue.debugRawRows();
      expect(raw.single['encrypted'], 1);
      expect((await queue.getById(id))!.sendPayload['messageText'], 'early');
    });

    test('a row that cannot be opened is kept and locked', () async {
      await queue.enqueue(chatId: 'c', sendPayload: {'messageText': 'x'});
      OutboxCipher.open = (_) async => throw StateError('wrong key');
      final rows = await queue.listAll();
      expect(rows.single.locked, isTrue);
      expect(await queue.count(), 1);
    });

    test('seq orders rows; listAll filters by user', () async {
      final a = await queue.enqueue(chatId: 'c', sendPayload: {'i': 1});
      final b = await queue.enqueue(
        chatId: 'c',
        sendPayload: {'i': 2},
        userId: 'u2',
      );
      final c = await queue.enqueue(chatId: 'c', sendPayload: {'i': 3});
      final all = await queue.listAll();
      expect(all.map((r) => r.id), [a, b, c]);
      expect(all[0].seq < all[1].seq && all[1].seq < all[2].seq, isTrue);
      expect((await queue.listAll(userId: 'u1')).map((r) => r.id), [a, c]);
    });

    test('wipeUser removes only that user', () async {
      await queue.enqueue(chatId: 'c', sendPayload: {'i': 1});
      await queue.enqueue(chatId: 'c', sendPayload: {'i': 2}, userId: 'u2');
      final gone = await queue.wipeUser('u1');
      expect(gone, hasLength(1));
      expect(await queue.count(), 1);
      expect((await queue.listAll()).single.userId, 'u2');
    });

    test('recoverInterrupted puts preparing/sending back to queued', () async {
      final a = await queue.enqueue(chatId: 'c', sendPayload: {'i': 1});
      final b = await queue.enqueue(chatId: 'c', sendPayload: {'i': 2});
      await queue.setState(a, OutboxState.sending);
      await queue.setState(b, OutboxState.failed);
      expect(await queue.recoverInterrupted(), 1);
      expect((await queue.getById(a))!.state, OutboxState.queued);
      expect((await queue.getById(b))!.state, OutboxState.failed);
    });
  });

  group('migration from version 1', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('outbox_v1_');
    });

    tearDown(() async {
      await queue.debugReset();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('old rows survive, get a seq, and are claimed and sealed', () async {
      final path = p.join(dir.path, 'offline_queue.db');
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE pending_messages (
                id TEXT PRIMARY KEY,
                chat_id TEXT NOT NULL,
                message_json TEXT NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      await v1.insert('pending_messages', {
        'id': 'old-2',
        'chat_id': 'c',
        'message_json': '{"messageText":"second"}',
        'attempt_count': 0,
        'created_at': 2000,
        'updated_at': 2000,
      });
      await v1.insert('pending_messages', {
        'id': 'old-1',
        'chat_id': 'c',
        'message_json': '{"messageText":"first"}',
        'attempt_count': 3,
        'created_at': 1000,
        'updated_at': 1000,
      });
      await v1.close();

      await queue.debugReset();
      OfflineQueueService.debugDatabasePath = path;
      final rows = await queue.listAll();
      expect(rows.map((r) => r.id), ['old-1', 'old-2']);
      expect(rows.first.sendPayload['messageText'], 'first');
      expect(rows.first.userId, isNull);
      expect(rows.first.state, OutboxState.queued);

      expect(await queue.claimLegacyRows('u1'), 2);
      final raw = await queue.debugRawRows();
      expect(raw.every((r) => r['encrypted'] == 1), isTrue);
      expect(raw.every((r) => r['user_id'] == 'u1'), isTrue);
      final after = await queue.listAll(userId: 'u1');
      expect(after.map((r) => r.sendPayload['messageText']), [
        'first',
        'second',
      ]);
    });
  });

  group('flush', () {
    test('drains per chat in order and stops a chat at its first failure',
        () async {
      final a1 = await queue.enqueue(chatId: 'A', sendPayload: {'n': 'a1'});
      final b1 = await queue.enqueue(chatId: 'B', sendPayload: {'n': 'b1'});
      final a2 = await queue.enqueue(chatId: 'A', sendPayload: {'n': 'a2'});
      final b2 = await queue.enqueue(chatId: 'B', sendPayload: {'n': 'b2'});
      final called = <String>[];
      manager.registerExecutor((m) async {
        called.add(m.sendPayload['n'] as String);
        if (m.id == a1) {
          return const SendExecutorResult.failure('network: socket closed');
        }
        return const SendExecutorResult.success();
      });
      await manager.debugDrain();
      expect(called, ['a1', 'b1', 'b2']);
      expect(await queue.getById(a2), isNotNull);
      expect(await queue.getById(b1), isNull);
      expect(await queue.getById(b2), isNull);
    });

    test('backoff: a deferred row waits for its time, then fails for good',
        () async {
      var clock = 1000000;
      OfflineRetryManager.now = () => clock;
      final id = await queue.enqueue(chatId: 'c', sendPayload: {'i': 1});
      var calls = 0;
      manager.registerExecutor((m) async {
        calls++;
        return const SendExecutorResult.failure('network: timeout');
      });

      await manager.debugDrain();
      expect(calls, 1);
      var row = (await queue.getById(id))!;
      expect(row.state, OutboxState.queued);
      expect(row.nextAttemptAt, clock + 5000);

      // Not due yet: an automatic flush skips it.
      await manager.debugDrain();
      expect(calls, 1);

      for (var i = 0; i < OfflineRetryManager.backoffSchedule.length; i++) {
        clock += const Duration(hours: 1).inMilliseconds;
        await manager.debugDrain();
      }
      row = (await queue.getById(id))!;
      expect(row.state, OutboxState.failed);
      expect(calls, OfflineRetryManager.backoffSchedule.length + 1);

      // Failed rows are never retried by themselves.
      clock += const Duration(days: 1).inMilliseconds;
      await manager.debugDrain();
      expect(calls, OfflineRetryManager.backoffSchedule.length + 1);

      // A manual Retry sends it again.
      manager.registerExecutor((m) async {
        calls++;
        return const SendExecutorResult.success();
      });
      await manager.retryRow(id);
      expect(await queue.getById(id), isNull);
    });

    test('a send the server accepted fails at once and is not re-sent',
        () async {
      final id = await queue.enqueue(chatId: 'c', sendPayload: {'i': 1});
      var calls = 0;
      manager.registerExecutor((m) async {
        calls++;
        return const SendExecutorResult.accepted('connection lost');
      });
      await manager.debugDrain(manual: true);
      await manager.debugDrain(manual: true);
      expect(calls, 1);
      final row = (await queue.getById(id))!;
      expect(row.state, OutboxState.failed);
      expect(row.lastError, 'connection lost');
    });

    test('a deferred result counts no attempt', () async {
      final id = await queue.enqueue(chatId: 'c', sendPayload: {'i': 1});
      manager.registerExecutor(
        (m) async => const SendExecutorResult.deferred('not signed in'),
      );
      await manager.debugDrain(manual: true);
      final row = (await queue.getById(id))!;
      expect(row.attemptCount, 0);
      expect(row.state, OutboxState.queued);
    });

    test('rows of another user are not sent', () async {
      await queue.enqueue(chatId: 'c', sendPayload: {'i': 1}, userId: 'u2');
      var calls = 0;
      manager.registerExecutor((m) async {
        calls++;
        return const SendExecutorResult.success();
      });
      await manager.debugDrain(manual: true);
      expect(calls, 0);
      expect(await queue.count(), 1);
    });

    test('preparer updates the payload, then the send gets it; onDone runs',
        () async {
      final id = await queue.enqueue(
        chatId: 'c',
        sendPayload: {'messageText': '', 'voicePath': '/tmp/x.wav'},
        kind: OutboxKind.voice,
      );
      final done = <String>[];
      manager.registerPreparer(
        OutboxPreparer(
          name: 'voice',
          appliesTo: (m) =>
              m.isVoice && (m.sendPayload['messageText'] as String).isEmpty,
          prepare: (m) async => PrepareResult.ok(
            payload: {...m.sendPayload, 'messageText': 'hello'},
          ),
          onDone: (m) async => done.add(m.sendPayload['messageText'] as String),
        ),
      );
      String? sent;
      manager.registerExecutor((m) async {
        sent = m.sendPayload['messageText'] as String;
        return const SendExecutorResult.success();
      });
      await manager.debugDrain();
      expect(sent, 'hello');
      expect(done, ['hello']);
      expect(await queue.getById(id), isNull);
    });

    test('a preparer can hold the row for the user', () async {
      final id = await queue.enqueue(
        chatId: 'c',
        sendPayload: {'messageText': ''},
        kind: OutboxKind.voice,
      );
      manager.registerPreparer(
        OutboxPreparer(
          name: 'voice',
          appliesTo: (m) => (m.sendPayload['messageText'] as String).isEmpty,
          prepare: (m) async => PrepareResult.ok(
            payload: {...m.sendPayload, 'messageText': 'draft'},
            hold: true,
          ),
        ),
      );
      var calls = 0;
      manager.registerExecutor((m) async {
        calls++;
        return const SendExecutorResult.success();
      });
      await manager.debugDrain();
      expect(calls, 0);
      final row = (await queue.getById(id))!;
      expect(row.state, OutboxState.held);
      expect(row.sendPayload['messageText'], 'draft');

      // Held rows wait for the user.
      await manager.debugDrain(manual: true);
      expect(calls, 0);
      await manager.retryRow(id);
      expect(calls, 1);
      expect(await queue.getById(id), isNull);
    });

    test('a failing preparer keeps the row and skips the send', () async {
      final id = await queue.enqueue(chatId: 'c', sendPayload: {'i': 1});
      manager.registerPreparer(
        OutboxPreparer(
          name: 'images',
          appliesTo: (_) => true,
          prepare: (_) async => const PrepareResult.failure('network: down'),
        ),
      );
      var calls = 0;
      manager.registerExecutor((m) async {
        calls++;
        return const SendExecutorResult.success();
      });
      await manager.debugDrain();
      expect(calls, 0);
      final row = (await queue.getById(id))!;
      expect(row.state, OutboxState.queued);
      expect(row.attemptCount, 1);
    });
  });
}
