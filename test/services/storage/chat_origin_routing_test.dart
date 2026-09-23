// Each chat kind reaches its own table and its own offline queue.
//
// A chuk_chat chat (UUID id) is read from and written to `encrypted_chats`
// through upstream's ChatStorageCrud, and a message typed offline goes into
// OfflineQueueService, which the retry manager drains. An Agents thread
// (session key) is written through AgentsChatStore into `cowork_chats`, and
// its offline prompt goes into AgentsTaskOutbox. With FEATURE_AGENTS off,
// every chat takes upstream's path.
//
// No network: the upstream writes, the Agents upsert and both queues are
// faked through their test seams.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/chat_storage_crud.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

const String chukChatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b';
const String agentsThreadKey = 'amber-otter-2';

List<Map<String, dynamic>> turn(String text) => <Map<String, dynamic>>[
  <String, dynamic>{'sender': 'user', 'text': text, 'reasoning': ''},
];

OfflineSendPayload payload(String chatId) => OfflineSendPayload(
  chatId: chatId,
  messageText: 'typed offline',
  modelId: 'm1',
  providerSlug: 'p1',
);

/// Upstream's local removal drops the chat first and then reaches for the
/// Supabase session to clear the cache. A unit test has no Supabase client,
/// so that second step throws after the part under test is done.
void removeAsTheSyncDoes(String chatId) {
  try {
    ChatStorageService.removeChatLocally(chatId);
  } on StateError {
    // No Supabase client: the cache clean-up after the removal.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Where the writes went, by store.
  late List<String> crudSaves;
  late List<String> crudUpdates;
  late List<String> agentsUpserts;
  late Map<String, String> outboxDisk;

  setUpAll(() {
    sqfliteFfiInit();
    OfflineQueueService.debugDatabaseFactory = databaseFactoryFfi;
    OfflineQueueService.debugDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatOrigin.reset();
    await ChatStorageService.reset();
    await AgentsChatStore.reset();

    crudSaves = <String>[];
    crudUpdates = <String>[];
    agentsUpserts = <String>[];
    ChatStorageService.debugCrudSave = (maps, {String? chatId}) async {
      crudSaves.add(chatId ?? '');
      return null;
    };
    ChatStorageService.debugCrudUpdate = (chatId, maps) async {
      crudUpdates.add(chatId);
      return null;
    };
    AgentsChatStore.userIdProvider = () => 'user-1';
    AgentsChatStore.keyLoader = () async => true;
    AgentsChatStore.encryptor = (plain) async => 'enc:$plain';
    AgentsChatStore.localCacheWriter = (_, _) async {};
    AgentsChatStore.localCacheReader = (_, _) async => null;
    AgentsChatStore.outboxRead = (_) async => null;
    AgentsChatStore.outboxWrite = (_, _) async {};
    AgentsChatStore.outboxDelete = (_) async {};
    AgentsChatStore.cloudUpsert = (userId, row) async {
      agentsUpserts.add(row['id'] as String);
      return <String, dynamic>{
        'id': row['id'],
        'created_at': '2026-09-23T10:00:00Z',
        'updated_at': '2026-09-23T10:00:00Z',
      };
    };

    outboxDisk = <String, String>{};
    AgentsTaskOutbox.resetForTest();
    AgentsTaskOutbox.read = (key) async => outboxDisk[key];
    AgentsTaskOutbox.write = (key, value) async => outboxDisk[key] = value;
    AgentsTaskOutbox.delete = (key) async => outboxDisk.remove(key);

    await OfflineQueueService.instance.debugReset();
    await OfflineQueueService.instance.init();
    await OfflineQueueService.instance.debugClearAll();
    OfflineRetryManager.instance.debugReset();
  });

  tearDown(() async {
    ChatStorageService.debugCrudSave = ChatStorageCrud.saveChat;
    ChatStorageService.debugCrudUpdate = ChatStorageCrud.updateChat;
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    OfflineRetryManager.instance.debugReset();
    await AgentsChatStore.reset();
    await ChatStorageService.reset();
    ChatOrigin.reset();
  });

  group('ChatOrigin', () {
    test('with the flag off, nothing is an Agents thread', () {
      ChatOrigin.agentsEnabled = false;
      ChatOrigin.claimAgentsThread(chukChatId);
      expect(ChatOrigin.isAgentsThread(agentsThreadKey), isFalse);
      expect(ChatOrigin.isAgentsThread('default'), isFalse);
      expect(ChatOrigin.isAgentsThread(chukChatId), isFalse);
    });

    test('with the flag on, a session key is one and a UUID is not', () {
      ChatOrigin.agentsEnabled = true;
      expect(ChatOrigin.isAgentsThread(agentsThreadKey), isTrue);
      expect(ChatOrigin.isAgentsThread('default'), isTrue);
      expect(ChatOrigin.isAgentsThread(chukChatId), isFalse);
      expect(ChatOrigin.isAgentsThread(chukChatId.toUpperCase()), isFalse);
      expect(ChatOrigin.isAgentsThread(null), isFalse);
      expect(ChatOrigin.isAgentsThread(''), isFalse);
    });

    test('a claimed key is an Agents thread whatever its shape', () {
      ChatOrigin.agentsEnabled = true;
      const uuidShapedKey = '11111111-2222-4333-8444-555555555555';
      expect(ChatOrigin.isAgentsThread(uuidShapedKey), isFalse);
      ChatOrigin.claimAgentsThread(uuidShapedKey);
      expect(ChatOrigin.isAgentsThread(uuidShapedKey), isTrue);
    });
  });

  group('chat writes', () {
    test('the Agents table is cowork_chats', () {
      expect(kAgentsChatsTable, 'cowork_chats');
    });

    test('flag off: every chat takes upstream\'s write path', () async {
      ChatOrigin.agentsEnabled = false;
      await ChatStorageService.saveChat(turn('a'), chatId: chukChatId);
      await ChatStorageService.updateChat(chukChatId, turn('b'));
      // Even a key shaped like a session key: there are no Agents threads.
      await ChatStorageService.saveChat(turn('c'), chatId: agentsThreadKey);
      await ChatStorageService.updateChat(agentsThreadKey, turn('d'));
      await AgentsChatStore.pending(agentsThreadKey);

      expect(crudSaves, <String>[chukChatId, agentsThreadKey]);
      expect(crudUpdates, <String>[chukChatId, agentsThreadKey]);
      expect(agentsUpserts, isEmpty);
    });

    test('flag on: a chuk_chat chat is saved and updated upstream\'s way, '
        'never into cowork_chats', () async {
      ChatOrigin.agentsEnabled = true;
      await ChatStorageService.saveChat(turn('a'), chatId: chukChatId);
      await ChatStorageService.updateChat(chukChatId, turn('b'));
      await AgentsChatStore.pending(chukChatId);

      expect(crudSaves, <String>[chukChatId]);
      expect(crudUpdates, <String>[chukChatId]);
      expect(agentsUpserts, isEmpty);
      expect(AgentsChatStore.isDirty(chukChatId), isFalse);
    });

    test('flag on: an Agents thread goes to the Agents store only', () async {
      ChatOrigin.agentsEnabled = true;
      await ChatStorageService.saveChat(turn('a'), chatId: agentsThreadKey);
      await AgentsChatStore.pending(agentsThreadKey);
      await ChatStorageService.updateChat(agentsThreadKey, turn('b'));
      await AgentsChatStore.pending(agentsThreadKey);

      expect(agentsUpserts, <String>[agentsThreadKey, agentsThreadKey]);
      expect(crudSaves, isEmpty);
      expect(crudUpdates, isEmpty);
      expect(
        ChatStorageService.getChatById(agentsThreadKey)!.messages.single.text,
        'b',
      );
    });

    test('flag on: a new chat with no id is a chuk_chat chat', () async {
      ChatOrigin.agentsEnabled = true;
      await ChatStorageService.saveChat(turn('a'));
      expect(crudSaves, <String>['']);
      expect(agentsUpserts, isEmpty);
    });
  });

  group('the encrypted_chats sync', () {
    test('keeps an Agents thread that table does not hold', () async {
      ChatOrigin.agentsEnabled = true;
      await ChatStorageService.saveChat(turn('a'), chatId: agentsThreadKey);
      await AgentsChatStore.pending(agentsThreadKey);
      expect(AgentsChatStore.isDirty(agentsThreadKey), isFalse);

      // The sync found no `encrypted_chats` row for it.
      ChatStorageService.removeChatLocally(agentsThreadKey);

      expect(ChatStorageService.getChatById(agentsThreadKey), isNotNull);
    });

    test('still removes a chuk_chat chat the cloud deleted', () {
      ChatOrigin.agentsEnabled = true;
      ChatStorageState.chatsById[chukChatId] = StoredChat(
        id: chukChatId,
        messages: const <ChatMessage>[],
        createdAt: DateTime.utc(2026, 9, 23),
        isStarred: false,
      );

      removeAsTheSyncDoes(chukChatId);

      expect(ChatStorageService.getChatById(chukChatId), isNull);
    });

    test('flag off: removal is upstream\'s for any id', () {
      ChatOrigin.agentsEnabled = false;
      ChatStorageState.chatsById[agentsThreadKey] = StoredChat(
        id: agentsThreadKey,
        messages: const <ChatMessage>[],
        createdAt: DateTime.utc(2026, 9, 23),
        isStarred: false,
      );

      removeAsTheSyncDoes(agentsThreadKey);

      expect(ChatStorageService.getChatById(agentsThreadKey), isNull);
    });
  });

  group('offline messages', () {
    Future<List<String>> drainWithExecutor() async {
      final sent = <String>[];
      OfflineRetryManager.instance.registerExecutor((QueuedMessage msg) async {
        sent.add(msg.chatId);
        return const SendExecutorResult.success();
      });
      await OfflineRetryManager.instance.retryNow();
      return sent;
    }

    test(
      'flag off: queued in OfflineQueueService and sent by the drain',
      () async {
        ChatOrigin.agentsEnabled = false;
        final queueId = await OfflineSendCoordinator.enqueue(
          payload(chukChatId),
        );

        expect(await OfflineQueueService.instance.getById(queueId), isNotNull);
        expect(outboxDisk, isEmpty);

        expect(await drainWithExecutor(), <String>[chukChatId]);
        expect(await OfflineQueueService.instance.count(), 0);
      },
    );

    test(
      'flag on: a chuk_chat message is queued and drained upstream\'s way',
      () async {
        ChatOrigin.agentsEnabled = true;
        final queueId = await OfflineSendCoordinator.enqueue(
          payload(chukChatId),
        );

        expect(await OfflineQueueService.instance.getById(queueId), isNotNull);
        expect(await AgentsTaskOutbox.pendingFor(chukChatId), isEmpty);

        expect(await drainWithExecutor(), <String>[chukChatId]);
        expect(await OfflineQueueService.instance.count(), 0);
      },
    );

    test(
      'flag on: an Agents prompt goes into the Agents outbox only',
      () async {
        ChatOrigin.agentsEnabled = true;
        final localId = await OfflineSendCoordinator.enqueue(
          payload(agentsThreadKey),
        );

        final pending = await AgentsTaskOutbox.pendingFor(agentsThreadKey);
        expect(pending.map((t) => t.localId), <String>[localId]);
        expect(pending.single.prompt, 'typed offline');
        expect(await OfflineQueueService.instance.count(), 0);
      },
    );

    test('flag on: an Agents view in front does not strand a chuk_chat '
        'message', () async {
      ChatOrigin.agentsEnabled = true;
      await OfflineSendCoordinator.enqueue(payload(chukChatId));
      var reconnects = 0;
      OfflineRetryManager.instance.registerReconnect(() async => reconnects++);

      final sent = await drainWithExecutor();

      expect(reconnects, 1);
      expect(sent, <String>[chukChatId]);
      expect(await OfflineQueueService.instance.count(), 0);
    });
  });
}
