import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/chat_storage_state.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';

List<Map<String, dynamic>> rows(List<List<String>> turns) =>
    <Map<String, dynamic>>[
      for (final t in turns)
        <String, dynamic>{'sender': t[0], 'text': t[1], 'reasoning': ''},
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ChatStorageService.reset();
    await CoworkChatStore.reset();
  });

  tearDown(() async {
    await CoworkChatStore.reset();
    await ChatStorageService.reset();
  });

  test(
    'the thread is in memory before the returned future completes',
    () async {
      final future = CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'hello'],
          ['ai', 'hi there'],
        ]),
      );
      // No await yet: the imported screen reads the row map at once.
      final chat = ChatStorageService.getChatById('agent-1');
      expect(chat, isNotNull);
      expect(chat!.isFullyLoaded, isTrue);
      expect(chat.messages.map((m) => m.text), ['hello', 'hi there']);
      expect(chat.title, 'hello');
      expect(await future, isNotNull);
    },
  );

  test('a replace is a replace: the old rows are gone', () async {
    await CoworkChatStore.replaceThread(
      'agent-1',
      rows([
        ['user', 'one'],
      ]),
    );
    await CoworkChatStore.replaceThread(
      'agent-1',
      rows([
        ['user', 'one'],
        ['ai', 'two'],
        ['user', 'three'],
      ]),
    );
    final chat = ChatStorageService.getChatById('agent-1')!;
    expect(chat.messages.length, 3);
    expect(chat.messages.last.text, 'three');
  });

  test('no signed-in user: memory only, no cache, no cloud', () async {
    var cacheWrites = 0;
    var cloudWrites = 0;
    CoworkChatStore.localCacheWriter = (_, _) async => cacheWrites++;
    CoworkChatStore.cloudUpsert = (_, _) async {
      cloudWrites++;
      return null;
    };
    await CoworkChatStore.replaceThread(
      'agent-1',
      rows([
        ['user', 'x'],
      ]),
    );
    await CoworkChatStore.pending('agent-1');
    expect(cacheWrites, 0);
    expect(cloudWrites, 0);
    expect(ChatStorageService.getChatById('agent-1'), isNotNull);
  });

  test('signed in: SQLite row first, then the encrypted upsert', () async {
    final log = <String>[];
    Map<String, dynamic>? cacheRow;
    Map<String, dynamic>? cloudRow;
    CoworkChatStore.userIdProvider = () => 'user-7';
    CoworkChatStore.keyLoader = () async => true;
    CoworkChatStore.encryptor = (plain) async => 'enc(${plain.length})';
    CoworkChatStore.localCacheWriter = (userId, row) async {
      log.add('cache:$userId');
      cacheRow = row;
    };
    CoworkChatStore.cloudUpsert = (userId, row) async {
      log.add('cloud:$userId');
      cloudRow = row;
      return <String, dynamic>{
        'id': row['id'],
        'created_at': '2026-09-01T10:00:00.000Z',
        'updated_at': '2026-09-05T04:30:00.000Z',
        'is_starred': false,
      };
    };

    await CoworkChatStore.replaceThread(
      'agent-1',
      rows([
        ['user', 'what is the plan'],
        ['ai', 'ship it'],
      ]),
    );
    await CoworkChatStore.pending('agent-1');

    expect(log, ['cache:user-7', 'cloud:user-7']);

    // The plaintext cache row is the shape chuk_chat's loadFullChat reads.
    expect(cacheRow!['id'], 'agent-1');
    expect(cacheRow!['title'], 'what is the plan');
    final payload = jsonDecode(cacheRow!['payload'] as String) as Map;
    expect(payload['v'], 2);
    expect((payload['messages'] as List).length, 2);

    // The cloud row is ciphertext only, keyed for the upsert.
    expect(cloudRow!['id'], 'agent-1');
    expect(cloudRow!['user_id'], 'user-7');
    expect(cloudRow!['encrypted_payload'], startsWith('enc('));
    expect(cloudRow!['encrypted_title'], startsWith('enc('));
    expect(cloudRow!.containsKey('payload'), isFalse);
    expect(cloudRow!['updated_at'], isA<String>());

    // The server's timestamps win over the local guess.
    final chat = ChatStorageService.getChatById('agent-1')!;
    expect(chat.createdAt.toUtc().year, 2026);
    expect(chat.createdAt.toUtc().day, 1);
    expect(chat.updatedAt!.toUtc().day, 5);
    expect(chat.isFullyLoaded, isTrue);
  });

  test(
    'no encryption key: the SQLite row is written, the cloud is skipped',
    () async {
      var cloudWrites = 0;
      var cacheWrites = 0;
      CoworkChatStore.userIdProvider = () => 'user-7';
      CoworkChatStore.keyLoader = () async => false;
      CoworkChatStore.localCacheWriter = (_, _) async => cacheWrites++;
      CoworkChatStore.cloudUpsert = (_, _) async {
        cloudWrites++;
        return null;
      };
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'x'],
        ]),
      );
      await CoworkChatStore.pending('agent-1');
      expect(cacheWrites, 1);
      expect(cloudWrites, 0);
    },
  );

  test(
    'a failing cloud write never surfaces and never blocks the next one',
    () async {
      final seen = <String>[];
      CoworkChatStore.userIdProvider = () => 'user-7';
      CoworkChatStore.keyLoader = () async => true;
      CoworkChatStore.encryptor = (plain) async => plain;
      CoworkChatStore.localCacheWriter = (_, _) async {};
      CoworkChatStore.cloudUpsert = (_, row) async {
        seen.add(row['encrypted_payload'] as String);
        if (seen.length == 1) throw StateError('boom');
        return null;
      };
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'first'],
        ]),
      );
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'second'],
        ]),
      );
      await CoworkChatStore.pending('agent-1');
      expect(seen.length, 2);
      expect(seen.last, contains('second'));
      expect(
        ChatStorageService.getChatById('agent-1')!.messages.single.text,
        'second',
      );
    },
  );

  test(
    'writes for one session run in order, even when the first is slow',
    () async {
      final order = <String>[];
      CoworkChatStore.userIdProvider = () => 'user-7';
      CoworkChatStore.keyLoader = () async => true;
      CoworkChatStore.encryptor = (plain) async => plain;
      CoworkChatStore.localCacheWriter = (_, _) async {};
      var first = true;
      CoworkChatStore.cloudUpsert = (_, row) async {
        if (first) {
          first = false;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        order.add(row['encrypted_payload'] as String);
        return null;
      };
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'A'],
        ]),
      );
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'B'],
        ]),
      );
      await CoworkChatStore.pending('agent-1');
      expect(order.length, 2);
      expect(order.first, contains('A'));
      expect(order.last, contains('B'));
    },
  );

  test('a custom name survives a host replace and becomes the title', () async {
    await CoworkChatStore.replaceThread(
      'agent-1',
      rows([
        ['user', 'x'],
      ]),
    );
    final current = ChatStorageService.getChatById('agent-1')!;
    ChatStorageState.chatsById['agent-1'] = StoredChat(
      id: current.id,
      messages: current.messages,
      createdAt: current.createdAt,
      isStarred: true,
      customName: 'Ops bot',
    );
    await CoworkChatStore.replaceThread(
      'agent-1',
      rows([
        ['user', 'y'],
      ]),
    );
    final chat = ChatStorageService.getChatById('agent-1')!;
    expect(chat.customName, 'Ops bot');
    expect(chat.title, 'Ops bot');
    expect(chat.isStarred, isTrue);
  });

  test(
    'rows without a sender are dropped; an all-bad list stores nothing',
    () async {
      final stored = await CoworkChatStore.replaceThread(
        'agent-1',
        <Map<String, dynamic>>[
          <String, dynamic>{'garbage': 1},
        ],
      );
      expect(stored, isNull);
      expect(ChatStorageService.getChatById('agent-1'), isNull);

      final mixed = await CoworkChatStore.replaceThread(
        'agent-1',
        <Map<String, dynamic>>[
          <String, dynamic>{'garbage': 1},
          <String, dynamic>{'role': 'assistant', 'text': 'kept'},
        ],
      );
      expect(mixed!.messages.single.text, 'kept');
    },
  );

  test(
    'the replay cursor is dropped when the sync removes the thread',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cowork.replay_cursor.agent-1': 42,
        'cowork.replay_cursor.agent-2': 7,
      });
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'x'],
        ]),
      );
      await CoworkChatStore.replaceThread(
        'agent-2',
        rows([
          ['user', 'y'],
        ]),
      );

      // What ChatStorageSync.removeChatLocally does when the row is gone
      // on the server.
      ChatStorageState.chatsById.remove('agent-1');
      ChatStorageState.notifyChanges('agent-1');
      // notifyChanges debounces by 100 ms.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('cowork.replay_cursor.agent-1'), isNull);
      expect(prefs.getInt('cowork.replay_cursor.agent-2'), 7);
    },
  );

  group('outbox', _outboxTests);
}

// ---------------------------------------------------------------------------
// The cloud outbox (bead cowork-hyg)
// ---------------------------------------------------------------------------

void _outboxTests() {
  late Map<String, String> kv;
  late List<Map<String, dynamic>> cloudRows;
  late bool keyAvailable;
  late bool cloudUp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ChatStorageService.reset();
    await CoworkChatStore.reset();
    kv = <String, String>{};
    cloudRows = <Map<String, dynamic>>[];
    keyAvailable = false;
    cloudUp = true;
    CoworkChatStore.userIdProvider = () => 'user-7';
    CoworkChatStore.keyLoader = () async => keyAvailable;
    CoworkChatStore.encryptor = (plain) async => 'enc:$plain';
    CoworkChatStore.localCacheWriter = (_, _) async {};
    CoworkChatStore.outboxRead = (key) async => kv[key];
    CoworkChatStore.outboxWrite = (key, value) async => kv[key] = value;
    CoworkChatStore.outboxDelete = (key) async => kv.remove(key);
    CoworkChatStore.cloudUpsert = (_, row) async {
      if (!cloudUp) throw StateError('offline');
      cloudRows.add(row);
      return <String, dynamic>{
        'id': row['id'],
        'created_at': '2026-09-05T04:00:00.000Z',
        'updated_at': row['updated_at'],
        'is_starred': false,
      };
    };
  });

  tearDown(() async {
    await CoworkChatStore.reset();
    await ChatStorageService.reset();
  });

  Map<String, dynamic> outbox() {
    final raw = kv['cowork.cloud_outbox.user-7'];
    if (raw == null) return const <String, dynamic>{};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  test(
    'no key: the thread is dirty, persisted, shielded from the sync',
    () async {
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'x'],
        ]),
      );
      await CoworkChatStore.pending('agent-1');
      expect(CoworkChatStore.isDirty('agent-1'), isTrue);
      expect(outbox().keys, ['agent-1']);
      expect(ChatStorageState.savingChats, contains('agent-1'));
      expect(cloudRows, isEmpty);
    },
  );

  test(
    'the key arrives: a flush uploads the memory copy and clears the flag',
    () async {
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'later'],
        ]),
      );
      await CoworkChatStore.pending('agent-1');
      keyAvailable = true;
      await CoworkChatStore.flushOutbox();
      expect(cloudRows.single['id'], 'agent-1');
      expect(cloudRows.single['encrypted_payload'], contains('later'));
      expect(CoworkChatStore.isDirty('agent-1'), isFalse);
      expect(outbox(), isEmpty);
      expect(ChatStorageState.savingChats, isNot(contains('agent-1')));
    },
  );

  test(
    'a successful write is clean; an offline one is dirty and retried',
    () async {
      keyAvailable = true;
      cloudUp = false;
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'x'],
        ]),
      );
      await CoworkChatStore.pending('agent-1');
      expect(CoworkChatStore.isDirty('agent-1'), isTrue);
      expect(cloudRows, isEmpty);

      await CoworkChatStore.flushOutbox(); // still offline
      expect(CoworkChatStore.isDirty('agent-1'), isTrue);

      cloudUp = true;
      await CoworkChatStore.flushOutbox();
      expect(cloudRows.single['id'], 'agent-1');
      expect(CoworkChatStore.isDirty('agent-1'), isFalse);
    },
  );

  test('a persisted outbox from a previous run is loaded and flushed from '
      'the SQLite row when the thread is not in memory', () async {
    kv['cowork.cloud_outbox.user-7'] = jsonEncode(<String, String>{
      'old-thread': '2026-09-04T10:00:00.000',
    });
    CoworkChatStore.localCacheReader = (userId, id) async => <String, dynamic>{
      'id': id,
      'payload': jsonEncode(<String, dynamic>{
        'v': 2,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'text': 'from disk'},
        ],
      }),
      'created_at': '2026-09-04T09:00:00.000',
      'updated_at': '2026-09-04T10:00:00.000',
      'is_starred': false,
      'title': 'from disk',
    };
    keyAvailable = true;
    await CoworkChatStore.flushOutbox();
    expect(cloudRows.single['id'], 'old-thread');
    expect(cloudRows.single['encrypted_payload'], contains('from disk'));
    expect(cloudRows.single['encrypted_title'], 'enc:from disk');
    // The cache row holds a local-time ISO string (chuk_chat writes
    // `toIso8601String()` of a local DateTime); the cloud row carries UTC.
    expect(
      cloudRows.single['updated_at'],
      DateTime.parse('2026-09-04T10:00:00.000').toUtc().toIso8601String(),
    );
    expect(outbox(), isEmpty);
  });

  test(
    'a dirty thread with no local copy anywhere is dropped from the outbox',
    () async {
      kv['cowork.cloud_outbox.user-7'] = jsonEncode(<String, String>{
        'ghost': '2026-09-04T10:00:00.000',
      });
      CoworkChatStore.localCacheReader = (_, _) async => null;
      keyAvailable = true;
      await CoworkChatStore.flushOutbox();
      expect(cloudRows, isEmpty);
      expect(outbox(), isEmpty);
      expect(ChatStorageState.savingChats, isNot(contains('ghost')));
    },
  );

  test(
    'the facade never removes a dirty thread and never merges over it',
    () async {
      await CoworkChatStore.replaceThread(
        'agent-1',
        rows([
          ['user', 'mine'],
        ]),
      );
      await CoworkChatStore.pending('agent-1');
      expect(CoworkChatStore.isDirty('agent-1'), isTrue);

      // What ChatSyncService does when the cloud has no row for a local chat.
      ChatStorageService.removeChatLocally('agent-1');
      expect(ChatStorageService.getChatById('agent-1'), isNotNull);

      // What it does when the cloud has an (older) row for it.
      await ChatStorageService.mergeSyncedChatsBatch(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'agent-1', 'encrypted_payload': 'stale'},
      ]);
      await ChatStorageService.mergeSyncedChat(<String, dynamic>{
        'id': 'agent-1',
        'encrypted_payload': 'stale',
      });
      expect(
        ChatStorageService.getChatById('agent-1')!.messages.single.text,
        'mine',
      );
    },
  );
}
