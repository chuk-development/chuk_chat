// Disk IO: a turn writes its chat to the cloud once, not once per save.
//
// Live, 2026-09-24: `UPDATE encrypted_chats SET encrypted_payload = …` ran
// 103k times and wrote 12 GB of WAL, 70 % of all writes. Every checkpoint of
// a turn (each tool round, each stream tick, the 2 s auto-save) re-encrypted
// and rewrote the whole chat. Now a checkpoint is saved on the device only
// (memory + SQLite + a dirty mark), and the turn's last save writes the
// cloud. A chat left dirty (failed write, killed app) is written by a flush.
//
// No network: the local and the cloud writes are faked through the
// ChatStorageService seams, the dirty set's kv store through its own.

import 'dart:io';

import 'package:chuk_chat/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:chuk_chat/services/chat_dirty_store.dart';
import 'package:chuk_chat/services/chat_storage_crud.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_sidebar.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/kv_cache_test_env.dart';

const String chatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b';
const String userId = 'user-1';

List<Map<String, String>> turn(String answer) => <Map<String, String>>[
  {'sender': 'user', 'text': 'Wie ist das Wetter gerade in Kiel?'},
  {'sender': 'ai', 'text': answer},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> kv;
  late List<String> localSaves;
  late List<String> cloudInserts;
  late List<String> cloudUpdates;

  setUp(() async {
    await ChatStorageService.reset();
    kv = <String, String>{};
    ChatDirtyStore.readKv = (key) async => kv[key];
    ChatDirtyStore.writeKv = (key, value) async => kv[key] = value;

    localSaves = <String>[];
    cloudInserts = <String>[];
    cloudUpdates = <String>[];
    ChatStorageService.debugCrudSaveLocal = (maps, {String? chatId}) async {
      final id = chatId ?? 'new-chat';
      localSaves.add(id);
      final chat = StoredChat(
        id: id,
        messages: [
          for (final m in maps)
            ChatMessage(
              role: m['sender'] == 'user' ? 'user' : 'assistant',
              text: m['text'] as String? ?? '',
            ),
        ],
        createdAt: DateTime.utc(2026, 9, 24),
        isStarred: false,
      );
      ChatStorageState.chatsById[id] = chat;
      await ChatDirtyStore.markDirty(userId, id, pendingInsert: false);
      return chat;
    };
    ChatStorageService.debugCrudSave = (maps, {String? chatId}) async {
      cloudInserts.add(chatId ?? '');
      return ChatStorageState.chatsById[chatId];
    };
    ChatStorageService.debugCrudUpdate = (chatId, maps) async {
      cloudUpdates.add(chatId);
      return ChatStorageState.chatsById[chatId];
    };
  });

  tearDown(() async {
    ChatStorageService.debugCrudSaveLocal = ChatStorageCrud.saveLocal;
    ChatStorageService.debugCrudSave = ChatStorageCrud.saveChat;
    ChatStorageService.debugCrudUpdate = ChatStorageCrud.updateChat;
    ChatDirtyStore.readKv = LocalChatCacheService.kvGet;
    ChatDirtyStore.writeKv = LocalChatCacheService.kvSet;
    await ChatStorageService.reset();
  });

  group('a turn writes the cloud once', () {
    test('checkpoints inside a turn stay on the device', () async {
      final handler = ChatPersistenceHandler();
      for (var round = 1; round <= 10; round++) {
        await handler.persistChat(
          messages: turn('tool round $round'),
          chatId: chatId,
          waitForCompletion: true,
          commit: false,
        );
      }

      expect(localSaves, hasLength(10));
      expect(cloudInserts, isEmpty);
      expect(cloudUpdates, isEmpty);
      expect(ChatDirtyStore.isDirty(chatId), isTrue);
    });

    test('ten tool rounds and the end of the turn: one cloud write', () async {
      final handler = ChatPersistenceHandler();
      for (var round = 1; round <= 10; round++) {
        await handler.persistChat(
          messages: turn('tool round $round'),
          chatId: chatId,
          waitForCompletion: true,
          commit: false,
        );
      }
      await handler.persistChat(
        messages: turn('the final answer'),
        chatId: chatId,
        waitForCompletion: true,
      );

      expect(localSaves, hasLength(11));
      expect(cloudInserts.length + cloudUpdates.length, 1);
    });

    test('stream-tick patches are local; the patch that ends the turn is '
        'the one cloud write', () async {
      final handler = ChatPersistenceHandler();
      await handler.persistChat(
        messages: turn('Thinking about it'),
        chatId: chatId,
        waitForCompletion: true,
        commit: false,
      );
      for (var tick = 1; tick <= 5; tick++) {
        await handler.updateBackgroundChatMessage(
          chatId: chatId,
          messageIndex: 1,
          content: 'partial answer $tick',
          immediate: true,
        );
      }
      expect(cloudUpdates, isEmpty);

      await handler.updateBackgroundChatMessage(
        chatId: chatId,
        messageIndex: 1,
        content: 'the final answer',
        status: 'sent',
        immediate: true,
        commit: true,
      );

      expect(localSaves, hasLength(7));
      expect(cloudUpdates, <String>[chatId]);
    });

    test(
      'a chat the cloud does not hold yet is inserted, not updated',
      () async {
        await ChatDirtyStore.markDirty(userId, chatId, pendingInsert: true);
        ChatStorageState.chatsById[chatId] = StoredChat(
          id: chatId,
          messages: [ChatMessage(role: 'user', text: 'hi')],
          createdAt: DateTime.utc(2026, 9, 24),
          isStarred: false,
        );

        await ChatStorageService.syncChat(chatId, turn('hi'));

        expect(cloudInserts, <String>[chatId]);
        expect(cloudUpdates, isEmpty);
      },
    );
  });

  group('the dirty set', () {
    test(
      'a cloud write clears the mark only for the newest local save',
      () async {
        final rev = await ChatDirtyStore.markDirty(
          userId,
          chatId,
          pendingInsert: true,
        );
        // A newer checkpoint lands while the cloud write of `rev` runs.
        await ChatDirtyStore.markDirty(userId, chatId, pendingInsert: false);

        await ChatDirtyStore.markSynced(userId, chatId, rev);
        expect(ChatDirtyStore.isDirty(chatId), isTrue);
        // The row exists now, so the next write is an update.
        expect(ChatDirtyStore.isPendingInsert(chatId), isFalse);

        await ChatDirtyStore.markSynced(
          userId,
          chatId,
          ChatDirtyStore.revision(chatId),
        );
        expect(ChatDirtyStore.isDirty(chatId), isFalse);
      },
    );

    test('a flush writes every dirty chat and clears it', () async {
      await ChatDirtyStore.markDirty(userId, chatId, pendingInsert: false);
      await ChatDirtyStore.markDirty(userId, 'other', pendingInsert: true);

      final pushed = <String>[];
      await ChatDirtyStore.flush(userId, (id) async => pushed.add(id));

      expect(pushed, unorderedEquals(<String>[chatId, 'other']));
      expect(ChatDirtyStore.ids, isEmpty);
      expect(kv['chat_dirty_v1_$userId'], '{}');
    });

    test('a failed flush keeps the chat dirty for the next one', () async {
      await ChatDirtyStore.markDirty(userId, chatId, pendingInsert: false);

      await ChatDirtyStore.flush(
        userId,
        (id) async => throw StateError('Chat not saved'),
      );
      expect(ChatDirtyStore.isDirty(chatId), isTrue);

      // The next flush (app start, background, network back) retries it.
      final pushed = <String>[];
      await ChatDirtyStore.flush(userId, (id) async => pushed.add(id));
      expect(pushed, <String>[chatId]);
      expect(ChatDirtyStore.isDirty(chatId), isFalse);
    });

    test('after a network error the rest of the flush waits', () async {
      await ChatDirtyStore.markDirty(userId, 'a', pendingInsert: false);
      await ChatDirtyStore.markDirty(userId, 'b', pendingInsert: false);

      var attempts = 0;
      await ChatDirtyStore.flush(userId, (id) async {
        attempts++;
        throw const SocketException('Failed host lookup');
      });

      expect(attempts, 1);
      expect(ChatDirtyStore.ids, unorderedEquals(<String>['a', 'b']));
    });

    test('the sync keeps a dirty chat the cloud does not list', () async {
      await ChatDirtyStore.markDirty(userId, chatId, pendingInsert: true);

      expect(
        ChatStorageSidebar.idsGoneFromServer(<String>[chatId, 'gone'], {}),
        <String>{'gone'},
      );

      ChatStorageState.chatsById[chatId] = StoredChat(
        id: chatId,
        messages: [ChatMessage(role: 'user', text: 'hi')],
        createdAt: DateTime.utc(2026, 9, 24),
        isStarred: false,
      );
      ChatStorageService.removeChatLocally(chatId);
      expect(ChatStorageState.chatsById.containsKey(chatId), isTrue);
    });
  });

  group('the dirty set on disk', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await useTempKvCache();
      ChatDirtyStore.readKv = LocalChatCacheService.kvGet;
      ChatDirtyStore.writeKv = LocalChatCacheService.kvSet;
    });

    tearDown(() => disposeTempKvCache(tempDir));

    test('survives a restart and is flushed after it', () async {
      await ChatDirtyStore.markDirty(userId, chatId, pendingInsert: true);

      // The app is killed: memory and the database handle are gone.
      ChatDirtyStore.reset();
      await LocalChatCacheService.debugReset();

      await ChatDirtyStore.load(userId);
      expect(ChatDirtyStore.isDirty(chatId), isTrue);
      expect(ChatDirtyStore.isPendingInsert(chatId), isTrue);

      final pushed = <String>[];
      await ChatDirtyStore.flush(userId, (id) async => pushed.add(id));
      expect(pushed, <String>[chatId]);

      ChatDirtyStore.reset();
      await ChatDirtyStore.load(userId);
      expect(ChatDirtyStore.ids, isEmpty);
    });
  });
}
