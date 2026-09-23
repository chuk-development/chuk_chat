// The Agents half of the cloud: `cowork_chats` is read back, deleted and
// re-sealed, not only written. With the flag off none of it runs.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/password_reset_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_storage_bootstrap.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

const String _user = 'user-7';
const String _chukChatId = '0b6c7f1e-2a51-4a8e-9d0e-6f4b8f7e1a23';

String _payload(List<List<String>> turns, {String? customName}) => jsonEncode({
  'v': 2,
  'customName': ?customName,
  'messages': [
    for (final t in turns) {'role': t[0], 'text': t[1]},
  ],
});

/// A `cowork_chats` row as the server returns it. The "ciphertext" is the
/// plaintext behind a marker, so the test decryptor can open it.
Map<String, dynamic> _cloudRow(
  String id,
  String payloadJson, {
  String updatedAt = '2026-09-20T10:00:00.000Z',
  String? title,
}) => <String, dynamic>{
  'id': id,
  'encrypted_payload': 'enc:$payloadJson',
  'encrypted_title': title == null ? null : 'enc:$title',
  'created_at': '2026-09-01T08:00:00.000Z',
  'is_starred': false,
  'updated_at': updatedAt,
};

class _Cloud {
  final Map<String, Map<String, dynamic>> rows = {};
  final List<List<String>?> selects = [];
  final List<String> deletes = [];
  final Map<String, Map<String, dynamic>> updates = {};

  /// The server's row limit: no response holds more rows, as with
  /// Supabase's `max-rows`.
  int maxRows = 1000;

  void install() {
    AgentsChatStore.cloudSelect =
        (userId, {ids, required columns, from, to}) async {
          expect(userId, _user);
          selects.add(ids);
          final sorted = rows.values.toList()
            ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
          var matched = [
            for (final row in sorted)
              if (ids == null || ids.contains(row['id']))
                columns == 'id, updated_at'
                    ? {'id': row['id'], 'updated_at': row['updated_at']}
                    : Map<String, dynamic>.from(row),
          ];
          if (from != null && to != null) {
            matched = matched.skip(from).take(to - from + 1).toList();
          }
          return matched.take(maxRows).toList();
        };
    AgentsChatStore.cloudDelete = (userId, id) async {
      expect(userId, _user);
      deletes.add(id);
      rows.remove(id);
    };
    AgentsChatStore.cloudUpdate = (userId, id, values) async {
      expect(userId, _user);
      updates[id] = values;
    };
    AgentsChatStore.decryptor = (cipher) async {
      if (!cipher.startsWith('enc:')) throw StateError('wrong key');
      return cipher.substring(4);
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Cloud cloud;
  late Map<String, Map<String, dynamic>> cache;
  late List<String> cacheDeletes;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ChatStorageService.reset();
    await AgentsChatStore.reset();
    ChatOrigin.reset();
    ChatOrigin.agentsEnabled = true;

    cloud = _Cloud()..install();
    cache = {};
    cacheDeletes = [];
    AgentsChatStore.userIdProvider = () => _user;
    AgentsChatStore.keyLoader = () async => true;
    AgentsChatStore.encryptor = (plain) async => 'enc:$plain';
    AgentsChatStore.localCacheReader = (userId, id) async => cache[id];
    AgentsChatStore.localCacheWriter = (userId, row) async {
      cache[row['id'] as String] = row;
    };
    AgentsChatStore.localMetaReader = (userId) async => cache.values.toList();
    AgentsChatStore.localCacheDeleter = (userId, id) async {
      cacheDeletes.add(id);
      cache.remove(id);
    };
    // The server takes every write (a test that wants a dirty thread says
    // so) and hands back its own timestamps, as Supabase does.
    AgentsChatStore.cloudUpsert = (userId, row) async => <String, dynamic>{
      'id': row['id'],
      'created_at': '2026-09-01T08:00:00.000Z',
      'updated_at': row['updated_at'],
      'is_starred': false,
    };
    AgentsChatStore.outboxRead = (_) async => null;
    AgentsChatStore.outboxWrite = (_, _) async {};
    AgentsChatStore.outboxDelete = (_) async {};
  });

  tearDown(() async {
    await AgentsChatStore.reset();
    await ChatStorageService.reset();
    await AgentsChatStorageBootstrap.reset();
    ChatOrigin.reset();
  });

  group('read back from cowork_chats', () {
    test('a new device loads a thread from the cloud and caches it', () async {
      cloud.rows['amber-otter-2'] = _cloudRow(
        'amber-otter-2',
        _payload([
          ['user', 'plan the trip'],
          ['assistant', 'here is a plan'],
        ]),
      );

      final chat = await ChatStorageService.loadFullChat('amber-otter-2');

      expect(chat, isNotNull);
      expect(chat!.messages.map((m) => m.text), [
        'plan the trip',
        'here is a plan',
      ]);
      expect(chat.title, 'plan the trip');
      expect(ChatStorageState.chatsById['amber-otter-2'], same(chat));
      // The plaintext copy lands in SQLite for the next (offline) start.
      final row = cache['amber-otter-2']!;
      expect(row['payload'], contains('here is a plan'));
      expect(cloud.selects, [
        ['amber-otter-2'],
      ]);
    });

    test('the SQLite row wins: no cloud read when the device has it', () async {
      cache['amber-otter-2'] = <String, dynamic>{
        'id': 'amber-otter-2',
        'payload': _payload([
          ['user', 'from sqlite'],
        ]),
        'created_at': '2026-09-01T08:00:00.000Z',
        'updated_at': '2026-09-20T10:00:00.000Z',
        'is_starred': false,
      };
      cloud.rows['amber-otter-2'] = _cloudRow(
        'amber-otter-2',
        _payload([
          ['user', 'from cloud'],
        ]),
      );

      final chat = await AgentsChatStore.loadThread('amber-otter-2');

      expect(chat!.messages.single.text, 'from sqlite');
      expect(cloud.selects, isEmpty);
    });

    test('a row the key cannot open is not a thread', () async {
      cloud.rows['amber-otter-2'] = <String, dynamic>{
        ..._cloudRow('amber-otter-2', '{}'),
        'encrypted_payload': 'sealed-with-another-key',
      };
      expect(await AgentsChatStore.loadThread('amber-otter-2'), isNull);
      expect(cache, isEmpty);
    });

    test(
      'the pull brings newer cloud copies in and leaves local ones',
      () async {
        // Known here, older than the cloud: pulled, and memory repaints.
        await AgentsChatStore.replaceThread('stale', [
          {'sender': 'user', 'text': 'old words'},
        ], updatedAt: DateTime.utc(2026, 9, 1));
        await AgentsChatStore.pending('stale');
        cloud.rows['stale'] = _cloudRow(
          'stale',
          _payload([
            ['user', 'new words from the laptop'],
          ]),
          updatedAt: '2026-09-21T10:00:00.000Z',
        );
        // Unknown here: pulled into SQLite, not into memory.
        cloud.rows['fresh'] = _cloudRow(
          'fresh',
          _payload([
            ['user', 'a thread from another device'],
          ]),
        );
        // Same age as the local copy: not fetched again.
        cache['same'] = <String, dynamic>{
          'id': 'same',
          'payload': _payload([
            ['user', 'x'],
          ]),
          'created_at': '2026-09-01T08:00:00.000Z',
          'updated_at': '2026-09-20T10:00:00.000Z',
        };
        cloud.rows['same'] = _cloudRow(
          'same',
          _payload([
            ['user', 'x'],
          ]),
        );
        // A UUID is a chuk_chat chat, never an Agents thread: not pulled.
        cloud.rows[_chukChatId] = _cloudRow(
          _chukChatId,
          _payload([
            ['user', 'y'],
          ]),
        );

        final pulled = await AgentsChatStore.pullFromCloud();

        expect(pulled.toSet(), {'stale', 'fresh'});
        expect(cloud.selects.last!.toSet(), {'stale', 'fresh'});
        expect(
          ChatStorageState.chatsById['stale']!.messages.single.text,
          'new words from the laptop',
        );
        expect(ChatStorageState.chatsById.containsKey('fresh'), isFalse);
        expect(cache['fresh']!['payload'], contains('another device'));
        expect(cache.containsKey(_chukChatId), isFalse);

        // A second tick finds nothing newer.
        expect(await AgentsChatStore.pullFromCloud(), isEmpty);
      },
    );

    test('the pull never overwrites a thread that is dirty', () async {
      AgentsChatStore.cloudUpsert = (_, _) async => null; // stays dirty
      await AgentsChatStore.replaceThread('mine', [
        {'sender': 'user', 'text': 'written offline'},
      ], updatedAt: DateTime.utc(2026, 9, 1));
      await AgentsChatStore.pending('mine');
      expect(AgentsChatStore.isDirty('mine'), isTrue);
      cloud.rows['mine'] = _cloudRow(
        'mine',
        _payload([
          ['user', 'older cloud copy'],
        ]),
        updatedAt: '2026-09-21T10:00:00.000Z',
      );

      expect(await AgentsChatStore.pullFromCloud(), isEmpty);
      expect(
        ChatStorageState.chatsById['mine']!.messages.single.text,
        'written offline',
      );
    });

    test('the bootstrap tick flushes and then pulls', () async {
      cloud.rows['fresh'] = _cloudRow(
        'fresh',
        _payload([
          ['user', 'hello'],
        ]),
      );
      await AgentsChatStorageBootstrap.flushNow();
      expect(cache.containsKey('fresh'), isTrue);
    });

    test('flag off: the pull reads nothing', () async {
      ChatOrigin.agentsEnabled = false;
      cloud.rows['fresh'] = _cloudRow('fresh', _payload([]));
      expect(await AgentsChatStore.pullFromCloud(), isEmpty);
      expect(cloud.selects, isEmpty);
    });
  });

  group('delete routes by origin', () {
    test('an Agents thread is deleted from cowork_chats', () async {
      await AgentsChatStore.replaceThread('amber-otter-2', [
        {'sender': 'user', 'text': 'bye'},
      ]);
      await AgentsChatStore.pending('amber-otter-2');
      cloud.rows['amber-otter-2'] = _cloudRow('amber-otter-2', _payload([]));

      await ChatStorageService.deleteChat('amber-otter-2');

      expect(cloud.deletes, ['amber-otter-2']);
      expect(cacheDeletes, ['amber-otter-2']);
      expect(ChatStorageState.chatsById.containsKey('amber-otter-2'), isFalse);
      expect(ChatStorageState.wasRecentlyDeleted('amber-otter-2'), isTrue);
      // The deleted thread does not come back with the next pull.
      cloud.rows['amber-otter-2'] = _cloudRow(
        'amber-otter-2',
        _payload([
          ['user', 'ghost'],
        ]),
      );
      expect(await AgentsChatStore.pullFromCloud(), isEmpty);
    });

    test('a dirty thread leaves the outbox when it is deleted', () async {
      AgentsChatStore.cloudUpsert = (_, _) async => null;
      await AgentsChatStore.replaceThread('mine', [
        {'sender': 'user', 'text': 'x'},
      ]);
      await AgentsChatStore.pending('mine');
      expect(AgentsChatStore.isDirty('mine'), isTrue);

      await ChatStorageService.deleteChat('mine');

      expect(AgentsChatStore.isDirty('mine'), isFalse);
      expect(ChatStorageState.savingChats.contains('mine'), isFalse);
    });

    test(
      'a delete waits for a flush in flight, so the row stays gone',
      () async {
        AgentsChatStore.cloudUpsert = (_, _) async => null; // dirty
        await AgentsChatStore.replaceThread('mine', [
          {'sender': 'user', 'text': 'x'},
        ]);
        await AgentsChatStore.pending('mine');

        final release = Completer<void>();
        AgentsChatStore.cloudUpsert = (userId, row) async {
          await release.future;
          cloud.rows[row['id'] as String] = _cloudRow('mine', '{}');
          return <String, dynamic>{
            'id': row['id'],
            'created_at': '2026-09-01T08:00:00.000Z',
            'updated_at': row['updated_at'],
          };
        };
        final flush = AgentsChatStore.flushOutbox();
        final delete = ChatStorageService.deleteChat('mine');
        release.complete();
        await flush;
        await delete;

        expect(cloud.rows.containsKey('mine'), isFalse);
        expect(cloud.deletes, ['mine']);
      },
    );

    test('a failed cloud delete keeps the thread', () async {
      await AgentsChatStore.replaceThread('mine', [
        {'sender': 'user', 'text': 'x'},
      ]);
      await AgentsChatStore.pending('mine');
      AgentsChatStore.cloudDelete = (_, _) async => throw StateError('offline');

      await expectLater(
        ChatStorageService.deleteChat('mine'),
        throwsStateError,
      );
      expect(ChatStorageState.chatsById.containsKey('mine'), isTrue);
    });

    test('a chuk_chat chat never touches cowork_chats', () async {
      // Upstream's delete runs (and throws here: no Supabase in a unit test).
      await expectLater(
        ChatStorageService.deleteChat(_chukChatId),
        throwsA(anything),
      );
      expect(cloud.deletes, isEmpty);
    });

    test('flag off: no delete ever reaches cowork_chats', () async {
      ChatOrigin.agentsEnabled = false;
      await expectLater(
        ChatStorageService.deleteChat('amber-otter-2'),
        throwsA(anything),
      );
      expect(cloud.deletes, isEmpty);
    });
  });

  group('password change re-seals cowork_chats', () {
    test('snapshot with the old key, re-encrypt with the new one', () async {
      cloud.rows['a'] = _cloudRow(
        'a',
        _payload([
          ['user', 'one'],
        ]),
        title: 'one',
      );
      cloud.rows['b'] = _cloudRow(
        'b',
        _payload([
          ['user', 'two'],
        ]),
      );
      cloud.rows['lost'] = <String, dynamic>{
        ..._cloudRow('lost', '{}'),
        'encrypted_payload': 'sealed-with-a-key-long-gone',
      };

      final snapshot = await AgentsChatStore.snapshotCloudThreads();
      expect(snapshot.map((t) => t.id).toSet(), {'a', 'b'});

      AgentsChatStore.encryptor = (plain) async => 'new:$plain';
      await AgentsChatStore.reencryptCloudThreads(snapshot);

      expect(cloud.updates.keys.toSet(), {'a', 'b'});
      expect(
        cloud.updates['a']!['encrypted_payload'],
        'new:${_payload([
          ['user', 'one'],
        ])}',
      );
      expect(cloud.updates['a']!['encrypted_title'], 'new:one');
      expect(cloud.updates['b']!.containsKey('encrypted_title'), isFalse);
    });

    test('writes wait while the key rotates, then flush', () async {
      final pushed = <String>[];
      AgentsChatStore.cloudUpsert = (userId, row) async {
        pushed.add(row['encrypted_payload'] as String);
        return <String, dynamic>{
          'id': row['id'],
          'created_at': '2026-09-01T08:00:00.000Z',
          'updated_at': row['updated_at'],
        };
      };
      await AgentsChatStore.pauseCloudWrites();
      await AgentsChatStore.replaceThread('mine', [
        {'sender': 'user', 'text': 'during the rotation'},
      ]);
      await AgentsChatStore.pending('mine');
      expect(pushed, isEmpty);
      expect(AgentsChatStore.isDirty('mine'), isTrue);

      AgentsChatStore.encryptor = (plain) async => 'new:$plain';
      await AgentsChatStore.resumeCloudWrites();
      expect(pushed.single, startsWith('new:'));
      expect(AgentsChatStore.isDirty('mine'), isFalse);
    });

    test('many threads are read in batches', () async {
      for (var i = 0; i < 120; i++) {
        cloud.rows['t-$i'] = _cloudRow(
          't-$i',
          _payload([
            ['user', 'n$i'],
          ]),
        );
      }
      final snapshot = await AgentsChatStore.snapshotCloudThreads();
      expect(snapshot.length, 120);
      final full = cloud.selects.whereType<List<String>>().toList();
      expect(full.map((ids) => ids.length), [50, 50, 20]);

      cloud.selects.clear();
      expect((await AgentsChatStore.pullFromCloud()).length, 120);
      expect(cloud.selects.whereType<List<String>>().length, 3);
    });

    test('a server cap below the page size does not skip rows', () async {
      // The server returns at most 30 rows per request while the client asks
      // for 50: a short page is not the end, and the next page starts after
      // the rows that actually came back.
      cloud.maxRows = 30;
      AgentsChatStore.idPageSize = 50;
      for (var i = 0; i < 120; i++) {
        final id = 'c-${i.toString().padLeft(3, '0')}';
        cloud.rows[id] = _cloudRow(
          id,
          _payload([
            ['user', 'n$i'],
          ]),
        );
      }

      final snapshot = await AgentsChatStore.snapshotCloudThreads();
      expect(snapshot.length, 120);
      expect(snapshot.map((t) => t.id).toSet().length, 120);
    });

    test('the id list is read in pages past the server row limit', () async {
      cloud.maxRows = 50;
      AgentsChatStore.idPageSize = 50;
      for (var i = 0; i < 120; i++) {
        cloud.rows['p-${i.toString().padLeft(3, '0')}'] = _cloudRow(
          'p-${i.toString().padLeft(3, '0')}',
          _payload([
            ['user', 'n$i'],
          ]),
        );
      }

      final snapshot = await AgentsChatStore.snapshotCloudThreads();
      expect(snapshot.length, 120);
      // Id pages of 50, 50, 20 and an empty one that ends the list, then
      // three full-row batches.
      expect(cloud.selects.where((ids) => ids == null).length, 4);

      cloud.selects.clear();
      expect((await AgentsChatStore.pullFromCloud()).length, 120);
      expect(cloud.selects.where((ids) => ids == null).length, 4);
    });

    test('a failed write throws, so the key rotation rolls back', () async {
      AgentsChatStore.cloudUpdate = (_, _, _) async =>
          throw StateError('offline');
      await expectLater(
        AgentsChatStore.reencryptCloudThreads(const [
          AgentsCloudThread(id: 'a', payloadJson: '{}'),
        ]),
        throwsStateError,
      );
    });
  });

  group('Agents threads stay out of chuk_chat surfaces', () {
    void seed() {
      ChatStorageState.chatsById['amber-otter-2'] = StoredChat.forSidebar(
        id: 'amber-otter-2',
        createdAt: DateTime.utc(2026, 9, 1),
        isStarred: false,
        isLocked: true,
      );
      ChatStorageState.chatsById[_chukChatId] = StoredChat.forSidebar(
        id: _chukChatId,
        createdAt: DateTime.utc(2026, 9, 2),
        isStarred: false,
        isLocked: true,
      );
    }

    test('flag on: savedChats and the reset counts hold chuk_chat only', () {
      seed();
      expect(ChatStorageService.savedChats.map((c) => c.id), [_chukChatId]);
      expect(PasswordResetService.lockedChatCount, 1);
      // The thread itself is still reachable by id.
      expect(ChatStorageService.getChatById('amber-otter-2'), isNotNull);
    });

    test('flag off: savedChats is upstream\'s, every chat', () {
      ChatOrigin.agentsEnabled = false;
      seed();
      expect(ChatStorageService.savedChats.length, 2);
      expect(PasswordResetService.lockedChatCount, 2);
    });
  });
}
