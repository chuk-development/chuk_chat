// Opening a chat must not move it in the sidebar.
//
// Bug chuk_chat-u7fr: the user opened an old chat, read it and sent nothing.
// Afterwards the chat stood at the top of the sidebar, as if it had a new
// message. A chat opened from the cache or the cloud had no digest on this
// device, so the first save after opening it (leaving it for a new chat, a
// stale tool call finalised on load) always wrote: `updatedAt` became now,
// and the upload moved `updated_at` in the cloud too, so every other device
// re-sorted as well. In the Agents build the save also restamped the last
// answer's duration with the days since its request, which changed the
// payload on its own.
//
// Now the chat as it was opened is the copy a save compares with: the same
// payload saves nothing and uploads nothing.

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:chuk_chat/services/chat_dirty_store.dart';
import 'package:chuk_chat/services/chat_storage_crud.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String oldChatId = '0a1b2c3d-0000-4000-8000-000000000001';
const String newChatId = '0a1b2c3d-0000-4000-8000-000000000002';
const String userId = 'user-1';

final DateTime oldUpdatedAt = DateTime.utc(2026, 3, 1, 12);
final DateTime newUpdatedAt = DateTime.utc(2026, 10, 18, 9);

/// An old chat as the cache or the cloud gives it back: several turns, with
/// the fields a real chat carries (model, reasoning, tool calls, status).
StoredChat storedOldChat({String? customName}) => StoredChat(
  id: oldChatId,
  messages: [
    ChatMessage(role: 'user', text: 'Wie ist das Wetter in Kiel?'),
    ChatMessage(
      role: 'assistant',
      text: 'In Kiel sind es 14 Grad und es regnet.',
      reasoning: 'The user asks for the weather.',
      modelId: 'deepseek/deepseek-v4-flash-0731',
      provider: 'fireworks',
      toolCalls: '[{"name":"weather","arguments":{"city":"Kiel"}}]',
      messageId: 'm-2',
      status: ChatMessageStatus.sent,
    ),
    ChatMessage(role: 'user', text: 'Und morgen?'),
    ChatMessage(
      role: 'assistant',
      text: 'Morgen wird es sonnig.',
      modelId: 'deepseek/deepseek-v4-flash-0731',
      messageId: 'm-4',
    ),
  ],
  createdAt: DateTime.utc(2026, 3, 1, 11),
  updatedAt: oldUpdatedAt,
  isStarred: false,
  customName: customName,
  title: customName ?? 'Wie ist das Wetter in Kiel?',
);

StoredChat storedNewChat() => StoredChat(
  id: newChatId,
  messages: [ChatMessage(role: 'user', text: 'hi')],
  createdAt: newUpdatedAt,
  updatedAt: newUpdatedAt,
  isStarred: false,
);

/// The maps the chat screen holds for [chat] after opening it, and hands
/// back to the save when it is left.
List<Map<String, dynamic>> openedMaps(StoredChat chat) => chat.messages
    .map<Map<String, dynamic>>(ChatUiHelpers.messageToRawMap)
    .toList();

List<String> sidebarOrder() =>
    ChatStorageState.savedChats.map((c) => c.id).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> kv;

  setUp(() async {
    await ChatStorageService.reset();
    kv = <String, String>{};
    ChatDirtyStore.readKv = (key) async => kv[key];
    ChatDirtyStore.writeKv = (key, value) async => kv[key] = value;
    await ChatDirtyStore.load(userId);
    // Opened: fully loaded from the cache, nothing saved on this device yet.
    ChatStorageState.chatsById[oldChatId] = storedOldChat();
    ChatStorageState.chatsById[newChatId] = storedNewChat();
  });

  tearDown(() async {
    ChatDirtyStore.readKv = LocalChatCacheService.kvGet;
    ChatDirtyStore.writeKv = LocalChatCacheService.kvSet;
    await ChatStorageService.reset();
  });

  group('opening a chat keeps its place', () {
    test('saving the chat as it was opened saves nothing', () {
      expect(ChatStorageState.localDigest[oldChatId], isNull);

      expect(
        ChatStorageCrud.isUnchangedSave(oldChatId, openedMaps(storedOldChat())),
        isTrue,
      );
    });

    test('saving the chat as it was opened uploads nothing', () {
      expect(ChatStorageState.lastWrite[oldChatId], isNull);

      expect(
        ChatStorageCrud.isUnchangedUpload(
          oldChatId,
          openedMaps(storedOldChat()),
        ),
        isTrue,
      );
    });

    test('a renamed chat as it was opened saves nothing either', () {
      ChatStorageState.chatsById[oldChatId] = storedOldChat(
        customName: 'Wetter Kiel',
      );

      expect(
        ChatStorageCrud.isUnchangedSave(oldChatId, openedMaps(storedOldChat())),
        isTrue,
      );
    });

    test('the opened chat keeps updatedAt and the sidebar order', () {
      final before = sidebarOrder();
      expect(before, <String>[newChatId, oldChatId]);

      ChatStorageCrud.isUnchangedSave(oldChatId, openedMaps(storedOldChat()));
      ChatStorageCrud.isUnchangedUpload(oldChatId, openedMaps(storedOldChat()));

      expect(ChatStorageState.chatsById[oldChatId]!.updatedAt, oldUpdatedAt);
      expect(sidebarOrder(), before);
    });

    test('a new message is a change, saved and uploaded', () {
      final maps = openedMaps(
        storedOldChat(),
      )..add(<String, dynamic>{'sender': 'user', 'text': 'Und am Wochenende?'});

      expect(ChatStorageCrud.isUnchangedSave(oldChatId, maps), isFalse);
      expect(ChatStorageCrud.isUnchangedUpload(oldChatId, maps), isFalse);
    });

    test('an edited message is a change', () {
      final maps = openedMaps(storedOldChat());
      maps[2] = <String, dynamic>{...maps[2], 'text': 'Und übermorgen?'};

      expect(ChatStorageCrud.isUnchangedSave(oldChatId, maps), isFalse);
      expect(ChatStorageCrud.isUnchangedUpload(oldChatId, maps), isFalse);
    });

    test('a dirty chat is not taken as unchanged: its copy in memory may '
        'carry a change the cache does not hold yet', () async {
      // A rename while a turn runs: the name goes into memory, and the save
      // that follows must still write it.
      await ChatDirtyStore.markDirty(userId, oldChatId, pendingInsert: false);
      ChatStorageState.chatsById[oldChatId] = storedOldChat(
        customName: 'Wetter Kiel',
      );

      expect(
        ChatStorageCrud.isUnchangedSave(oldChatId, openedMaps(storedOldChat())),
        isFalse,
      );
      expect(
        ChatStorageCrud.isUnchangedUpload(
          oldChatId,
          openedMaps(storedOldChat()),
        ),
        isFalse,
      );
    });

    test('a chat replaced since it was opened is compared afresh', () {
      ChatStorageCrud.isUnchangedSave(oldChatId, openedMaps(storedOldChat()));

      // Another device wrote it; the sync replaced the copy in memory.
      final synced = storedOldChat().copyWith(
        updatedAt: DateTime.utc(2026, 10, 19),
      );
      ChatStorageState.chatsById[oldChatId] = synced;

      expect(
        ChatStorageCrud.isUnchangedSave(oldChatId, openedMaps(storedOldChat())),
        isFalse,
      );
    });
  });

  group('the duration of a settled answer is not restamped', () {
    Map<String, String> answer({required String generationMs}) => {
      'sender': 'ai',
      'text': 'Morgen wird es sonnig.',
      'reasoning': '',
      'messageId': 'm-4',
      'startedAt': DateTime.now()
          .subtract(const Duration(days: 30))
          .toIso8601String(),
      'generationMs': generationMs,
    };

    List<ChatMessage> stored({required String generationMs}) => [
      ChatMessage(role: 'user', text: 'Und morgen?'),
      ChatMessage(
        role: 'assistant',
        text: 'Morgen wird es sonnig.',
        messageId: 'm-4',
        generationMs: generationMs,
      ),
    ];

    test('an opened chat keeps the duration of its last answer', () {
      final messages = [
        {'sender': 'user', 'text': 'Und morgen?', 'reasoning': ''},
        answer(generationMs: '4200'),
      ];

      ChatPersistenceHandler.stampWorkedFor(
        messages,
        stored: stored(generationMs: '4200'),
      );

      expect(messages.last['generationMs'], '4200');
    });

    test('an answer that changed since its last save is restamped', () {
      // A tool round of a running turn: the answer grew since the last save.
      final messages = [
        {'sender': 'user', 'text': 'Und morgen?', 'reasoning': ''},
        {...answer(generationMs: '4200'), 'text': 'Morgen wird es sonnig, '},
      ];

      ChatPersistenceHandler.stampWorkedFor(
        messages,
        stored: stored(generationMs: '4200'),
      );

      expect(messages.last['generationMs'], isNot('4200'));
    });
  });
}
