// test/services/offline_queue_service_test.dart
//
// Unit tests for OfflineQueueService — verifies enqueue/list/remove and the
// watch() stream over an in-memory SQLite database.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/services/offline_queue_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    OfflineQueueService.debugDatabaseFactory = databaseFactoryFfi;
    OfflineQueueService.debugDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    await OfflineQueueService.instance.debugReset();
    await OfflineQueueService.instance.init();
    await OfflineQueueService.instance.debugClearAll();
  });

  group('OfflineQueueService', () {
    test('enqueue + listForChat returns the message', () async {
      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'chat-1',
        sendPayload: {'messageText': 'hello'},
      );

      final pending = await OfflineQueueService.instance.listForChat('chat-1');
      expect(pending, hasLength(1));
      expect(pending.first.id, id);
      expect(pending.first.chatId, 'chat-1');
      expect(pending.first.sendPayload['messageText'], 'hello');
      expect(pending.first.attemptCount, 0);
      expect(pending.first.lastError, isNull);
    });

    test('listForChat only returns matching chat', () async {
      await OfflineQueueService.instance.enqueue(
        chatId: 'chat-a',
        sendPayload: {'messageText': 'a'},
      );
      await OfflineQueueService.instance.enqueue(
        chatId: 'chat-b',
        sendPayload: {'messageText': 'b'},
      );

      final a = await OfflineQueueService.instance.listForChat('chat-a');
      final b = await OfflineQueueService.instance.listForChat('chat-b');
      expect(a, hasLength(1));
      expect(b, hasLength(1));
      expect(a.first.sendPayload['messageText'], 'a');
      expect(b.first.sendPayload['messageText'], 'b');
    });

    test('listAll returns entries ordered by created_at ASC', () async {
      final id1 = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );
      // Force a different timestamp by waiting at least 1 ms.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final id2 = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 2},
      );

      final all = await OfflineQueueService.instance.listAll();
      expect(all.map((m) => m.id).toList(), [id1, id2]);
    });

    test('remove removes the entry', () async {
      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'chat-1',
        sendPayload: {'messageText': 'x'},
      );
      expect(await OfflineQueueService.instance.count(), 1);
      await OfflineQueueService.instance.remove(id);
      expect(await OfflineQueueService.instance.count(), 0);
    });

    test('markFailed updates last_error and increments attempt_count, does '
        'not remove', () async {
      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'chat-1',
        sendPayload: {'messageText': 'x'},
      );

      await OfflineQueueService.instance.markFailed(id, 'boom');
      final after = await OfflineQueueService.instance.getById(id);
      expect(after, isNotNull);
      expect(after!.attemptCount, 1);
      expect(after.lastError, 'boom');

      await OfflineQueueService.instance.markFailed(id, 'again');
      final after2 = await OfflineQueueService.instance.getById(id);
      expect(after2!.attemptCount, 2);
      expect(after2.lastError, 'again');
    });

    test('incrementAttempts bumps the counter without setting lastError',
        () async {
      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );
      await OfflineQueueService.instance.incrementAttempts(id);
      final after = await OfflineQueueService.instance.getById(id);
      expect(after!.attemptCount, 1);
      expect(after.lastError, isNull);
    });

    test('watch() stream emits on enqueue/remove', () async {
      final emitted = <int>[];
      final sub = OfflineQueueService.instance.watch().listen((list) {
        emitted.add(list.length);
      });

      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );
      await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 2},
      );
      await OfflineQueueService.instance.remove(id);
      // Drain microtasks so all add() events propagate.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(emitted, isNotEmpty);
      // After all operations we should have ended at length=1.
      expect(emitted.last, 1);
    });
  });
  group('OfflineQueueService migration', () {
    test('opens a v2 file that an older build set back to version 1',
        () async {
      final dir = await Directory.systemTemp.createTemp('offline_queue_');
      final path = '${dir.path}/offline_queue.db';
      // What an older build leaves: v2 columns, user_version 1.
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.execute('''
        CREATE TABLE pending_messages (
          id TEXT PRIMARY KEY, chat_id TEXT NOT NULL,
          message_json TEXT NOT NULL,
          attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          user_id TEXT, kind TEXT NOT NULL DEFAULT 'text',
          state TEXT NOT NULL DEFAULT 'queued',
          next_attempt_at INTEGER NOT NULL DEFAULT 0,
          seq INTEGER NOT NULL DEFAULT 0,
          encrypted INTEGER NOT NULL DEFAULT 0)
      ''');
      await raw.execute(
        'CREATE INDEX idx_pending_user ON pending_messages (user_id)',
      );
      await raw.setVersion(1);
      await raw.close();

      await OfflineQueueService.instance.debugReset();
      OfflineQueueService.debugDatabasePath = path;
      addTearDown(() async {
        await OfflineQueueService.instance.debugReset();
        OfflineQueueService.debugDatabasePath = inMemoryDatabasePath;
        await dir.delete(recursive: true);
      });

      await OfflineQueueService.instance.init();
      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'chat-1',
        sendPayload: {'messageText': 'hello'},
      );
      final pending = await OfflineQueueService.instance.listForChat('chat-1');
      expect(pending.single.id, id);
    });
  });
}
