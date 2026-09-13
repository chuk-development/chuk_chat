// test/platform_specific/chat/assistant_message_write_mixin_test.dart
//
// Where an assistant write lands when the reader walks away mid-answer.
//
// Each of the four write methods forks: the chat on screen goes into the live
// `messages` list, every other chat goes to storage. The fork used to have a
// hole — an ACTIVE chat whose widget was already torn down (or whose index no
// longer addressed the list) matched neither side, and the write was dropped on
// the floor: no list entry, no storage row. That is bead cowork-8n33, and it is
// exactly the moment a user leaves the screen while the coworker still answers.
//
// The tests below hold that fork open from both sides: the live path still wins
// when the widget is there, and storage always catches what the live path
// declines.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/tool_call.dart';
import 'package:cowork/platform_specific/chat/assistant_message_write_mixin.dart';
import 'package:cowork/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:cowork/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:cowork/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:cowork/platform_specific/chat/regen_variant_seed.dart';
import 'package:cowork/services/chat_storage_service.dart';

void main() {
  const String chatOnScreen = 'chat-on-screen';
  const String otherChat = 'chat-elsewhere';

  /// Mount the harness with [messages] as the visible transcript of
  /// [activeChatId].
  Future<_HarnessState> pumpHarness(
    WidgetTester tester, {
    String? activeChatId = chatOnScreen,
    List<Map<String, String>>? messages,
  }) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _Harness(
          key: key,
          activeChatId: activeChatId,
          initialMessages:
              messages ??
              <Map<String, String>>[
                <String, String>{'text': 'hi', 'sender': 'user'},
                <String, String>{'text': '', 'sender': 'ai'},
              ],
        ),
      ),
    );
    return key.currentState!;
  }

  /// Tear the harness down while keeping [state] reachable — the widget is
  /// gone, the State object is not. This is the live shape of the bug: the
  /// stream is still delivering into a State whose `mounted` is false.
  Future<void> unmount(WidgetTester tester, _HarnessState state) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(state.mounted, isFalse, reason: 'the widget must really be gone');
  }

  setUp(() {
    ChatStorageService.isMessageOperationInProgress = false;
  });

  // --- updateToolCallsForMessage ------------------------------------------

  group('updateToolCallsForMessage', () {
    testWidgets('active chat, widget gone: the tool calls go to storage', (
      tester,
    ) async {
      final state = await pumpHarness(tester);
      await unmount(tester, state);

      state.updateToolCallsForMessage(1, <ToolCall>[
        ToolCall(id: 'tc-1', name: 'read_file', status: ToolCallStatus.running),
      ], chatOnScreen);

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, chatOnScreen);
      expect(update.messageIndex, 1);
      expect(_toolCallNames(update.toolCallsJson), <String>['read_file']);
      expect(
        update.immediate,
        isFalse,
        reason: 'a call still running may be coalesced by the debounce',
      );
    });

    testWidgets('active chat, index past the end: the tool calls go to storage',
        (tester) async {
      final state = await pumpHarness(tester);

      state.updateToolCallsForMessage(7, <ToolCall>[
        ToolCall(
          id: 'tc-2',
          name: 'write_file',
          status: ToolCallStatus.completed,
        ),
      ], chatOnScreen);

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, chatOnScreen);
      expect(update.messageIndex, 7);
      expect(_toolCallNames(update.toolCallsJson), <String>['write_file']);
      expect(
        update.immediate,
        isTrue,
        reason: 'nothing is still running, so this is the final state',
      );
      expect(state.persistChatCalls, 0);
    });

    testWidgets('active chat on screen: the live list takes it, storage does not',
        (tester) async {
      final state = await pumpHarness(tester);

      state.updateToolCallsForMessage(1, <ToolCall>[
        ToolCall(id: 'tc-3', name: 'search', status: ToolCallStatus.completed),
      ], chatOnScreen);
      await tester.pump();

      expect(_toolCallNames(state.messages[1]['toolCalls']), <String>[
        'search',
      ]);
      expect(state.persistChatCalls, 1);
      expect(state.persistenceHandler.updates, isEmpty);
    });

    testWidgets('another chat: the tool calls go to storage', (tester) async {
      final state = await pumpHarness(tester);

      state.updateToolCallsForMessage(1, <ToolCall>[
        ToolCall(id: 'tc-4', name: 'search', status: ToolCallStatus.completed),
      ], otherChat);

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, otherChat);
      expect(update.messageIndex, 1);
      expect(_toolCallNames(update.toolCallsJson), <String>['search']);
      expect(
        state.messages[1].containsKey('toolCalls'),
        isFalse,
        reason: 'the visible chat must not take another chat\'s tool calls',
      );
    });
  });

  // --- handleToolImagesProcessed ------------------------------------------

  group('handleToolImagesProcessed', () {
    const String metas = '[{"w":512,"h":512}]';
    const String toolCallsJson = '[{"id":"tc-img","name":"generate_image"}]';

    testWidgets('active chat, widget gone: the images go to storage', (
      tester,
    ) async {
      final state = await pumpHarness(tester);
      await unmount(tester, state);

      state.handleToolImagesProcessed(
        1,
        <String>['/tmp/a.png', '/tmp/b.png'],
        metas,
        '0.04',
        '2026-09-13T10:00:00Z',
        toolCallsJson,
        chatOnScreen,
      );

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, chatOnScreen);
      expect(update.messageIndex, 1);
      expect(jsonDecode(update.images!), <String>['/tmp/a.png', '/tmp/b.png']);
      expect(update.imageMetas, metas);
      expect(update.imageCostEur, '0.04');
      expect(update.imageGeneratedAt, '2026-09-13T10:00:00Z');
      expect(update.toolCallsJson, toolCallsJson);
      expect(update.immediate, isTrue);
    });

    testWidgets('active chat, index past the end: the images go to storage', (
      tester,
    ) async {
      final state = await pumpHarness(tester);

      state.handleToolImagesProcessed(
        9,
        <String>['/tmp/c.png'],
        metas,
        null,
        null,
        toolCallsJson,
        chatOnScreen,
      );

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, chatOnScreen);
      expect(update.messageIndex, 9);
      expect(jsonDecode(update.images!), <String>['/tmp/c.png']);
      expect(update.imageCostEur, isNull);
      expect(state.persistChatCalls, 0);
    });

    testWidgets('active chat on screen: the live list takes the images', (
      tester,
    ) async {
      final state = await pumpHarness(tester);

      state.handleToolImagesProcessed(
        1,
        <String>['/tmp/d.png'],
        metas,
        '0.02',
        '2026-09-13T11:00:00Z',
        toolCallsJson,
        chatOnScreen,
      );
      await tester.pump();

      expect(jsonDecode(state.messages[1]['images']!), <String>['/tmp/d.png']);
      expect(state.messages[1]['imageMetas'], metas);
      expect(state.messages[1]['imageCostEur'], '0.02');
      expect(state.messages[1]['imageGeneratedAt'], '2026-09-13T11:00:00Z');
      expect(state.messages[1]['toolCalls'], toolCallsJson);
      expect(state.persistChatCalls, 1);
      expect(state.persistenceHandler.updates, isEmpty);
    });

    testWidgets('another chat: the images go to storage', (tester) async {
      final state = await pumpHarness(tester);

      state.handleToolImagesProcessed(
        1,
        <String>['/tmp/e.png'],
        metas,
        null,
        null,
        toolCallsJson,
        otherChat,
      );

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, otherChat);
      expect(jsonDecode(update.images!), <String>['/tmp/e.png']);
      expect(state.messages[1].containsKey('images'), isFalse);
    });
  });

  // --- updateContentBlocksForMessage --------------------------------------

  group('updateContentBlocksForMessage', () {
    const String blocks = '[{"type":"text","text":"the answer"}]';

    testWidgets('active chat, widget gone: the blocks go to storage', (
      tester,
    ) async {
      final state = await pumpHarness(tester);
      await unmount(tester, state);

      state.updateContentBlocksForMessage(1, blocks, chatOnScreen);

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, chatOnScreen);
      expect(update.messageIndex, 1);
      expect(update.contentBlocksJson, blocks);
    });

    testWidgets('active chat, index past the end: the blocks go to storage', (
      tester,
    ) async {
      final state = await pumpHarness(tester);

      state.updateContentBlocksForMessage(5, blocks, chatOnScreen);

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, chatOnScreen);
      expect(update.messageIndex, 5);
      expect(update.contentBlocksJson, blocks);
    });

    testWidgets('active chat on screen: the live list takes the blocks', (
      tester,
    ) async {
      final state = await pumpHarness(tester);

      state.updateContentBlocksForMessage(1, blocks, chatOnScreen);
      await tester.pump();

      expect(state.messages[1]['contentBlocks'], blocks);
      expect(state.persistenceHandler.updates, isEmpty);
    });

    testWidgets('another chat: the blocks go to storage', (tester) async {
      final state = await pumpHarness(tester);

      state.updateContentBlocksForMessage(1, blocks, otherChat);

      final update = state.persistenceHandler.singleUpdate;
      expect(update.chatId, otherChat);
      expect(update.contentBlocksJson, blocks);
      expect(state.messages[1].containsKey('contentBlocks'), isFalse);
    });
  });

  // --- finalizeAiMessage ---------------------------------------------------

  group('finalizeAiMessage', () {
    /// The snapshot the streaming handler keeps for a chat that is no longer
    /// driving the visible list.
    List<Map<String, dynamic>> snapshotFor(String chatId) =>
        <Map<String, dynamic>>[
          <String, dynamic>{'text': 'hi', 'sender': 'user'},
          <String, dynamic>{'text': '', 'sender': 'ai', 'status': 'interrupted'},
        ];

    testWidgets('active chat, widget gone: the finished answer is persisted', (
      tester,
    ) async {
      final state = await pumpHarness(tester);
      state.streamingHandler.snapshots[chatOnScreen] = snapshotFor(
        chatOnScreen,
      );
      await unmount(tester, state);

      await state.finalizeAiMessage(1, 'the answer', 'because', chatOnScreen, 42.5);

      expect(
        state.persistenceHandler.persistedChats,
        hasLength(1),
        reason: 'the full snapshot is the write that survives a teardown',
      );
      final persisted = state.persistenceHandler.persistedChats.single;
      expect(persisted.chatId, chatOnScreen);
      expect(persisted.silent, isTrue);
      expect(persisted.messages[1]['text'], 'the answer');
      expect(persisted.messages[1]['reasoning'], 'because');
      expect(persisted.messages[1]['tps'], '42.5');
      expect(
        persisted.messages[1].containsKey('status'),
        isFalse,
        reason: 'a clean finalize drops the interrupted flag',
      );
    });

    // Bead cowork-9u1b: the widget is still mounted and the chat is still on
    // screen, but the index no longer exists — a trimmed transcript, a deleted
    // message, a reload racing the answer. That used to return from inside the
    // live branch and write the finished answer nowhere at all.
    testWidgets(
      'active chat, mounted, index past the end: storage still gets the answer',
      (tester) async {
        final state = await pumpHarness(tester);
        state.streamingHandler.snapshots[chatOnScreen] = snapshotFor(
          chatOnScreen,
        );
        expect(state.mounted, isTrue, reason: 'this is the mounted case');

        await state.finalizeAiMessage(
          99,
          'answer with nowhere to sit',
          '',
          chatOnScreen,
          null,
        );

        expect(
          state.persistenceHandler.persistedChats.length +
              state.persistenceHandler.updates.length,
          greaterThan(0),
          reason: 'the answer must reach storage, not vanish',
        );
      },
    );

    testWidgets(
      'active chat, widget gone, index past the snapshot: storage still gets the answer',
      (tester) async {
        final state = await pumpHarness(tester);
        state.streamingHandler.snapshots[chatOnScreen] = snapshotFor(
          chatOnScreen,
        );
        await unmount(tester, state);

        await state.finalizeAiMessage(9, 'late answer', '', chatOnScreen, null);

        expect(state.persistenceHandler.persistedChats, isEmpty);
        final update = state.persistenceHandler.singleUpdate;
        expect(update.chatId, chatOnScreen);
        expect(update.messageIndex, 9);
        expect(update.content, 'late answer');
        expect(update.status, 'sent');
        expect(update.immediate, isTrue);
      },
    );

    testWidgets(
      'active chat, widget gone, no snapshot at all: storage still gets the answer',
      (tester) async {
        final state = await pumpHarness(tester);
        await unmount(tester, state);

        await state.finalizeAiMessage(1, 'orphan answer', 'r', chatOnScreen, null);

        final update = state.persistenceHandler.singleUpdate;
        expect(update.chatId, chatOnScreen);
        expect(update.messageIndex, 1);
        expect(update.content, 'orphan answer');
        expect(update.reasoning, 'r');
        expect(update.status, 'sent');
      },
    );

    testWidgets('active chat on screen: the live list takes the answer', (
      tester,
    ) async {
      final state = await pumpHarness(
        tester,
        messages: <Map<String, String>>[
          <String, String>{'text': 'hi', 'sender': 'user'},
          <String, String>{
            'text': '',
            'sender': 'ai',
            'status': 'interrupted',
          },
        ],
      );
      state.isSendingMessage = true;

      await state.finalizeAiMessage(1, 'the answer', 'because', chatOnScreen, 12.0);
      await tester.pump();

      expect(state.messages[1]['text'], 'the answer');
      expect(state.messages[1]['reasoning'], 'because');
      expect(state.messages[1]['tps'], '12.0');
      expect(state.messages[1].containsKey('status'), isFalse);
      expect(state.isSendingMessage, isFalse);
      expect(state.persistChatCalls, 1);
      expect(state.drainCalls, 1);
      expect(state.persistenceHandler.updates, isEmpty);
      expect(state.persistenceHandler.persistedChats, isEmpty);
    });

    testWidgets('another chat: the snapshot is persisted, the live list is left alone',
        (tester) async {
      final state = await pumpHarness(tester);
      state.streamingHandler.snapshots[otherChat] = snapshotFor(otherChat);

      await state.finalizeAiMessage(1, 'background answer', '', otherChat, null);

      final persisted = state.persistenceHandler.persistedChats.single;
      expect(persisted.chatId, otherChat);
      expect(persisted.messages[1]['text'], 'background answer');
      expect(
        state.messages[1]['text'],
        '',
        reason: 'another chat\'s answer must not land in the visible list',
      );
      expect(
        state.drainCalls,
        0,
        reason: 'the outbox belongs to the visible chat',
      );
    });
  });
}

/// The names of the tool calls inside a `toolCalls` JSON blob.
List<String> _toolCallNames(String? json) {
  if (json == null) return const <String>[];
  return (jsonDecode(json) as List<dynamic>)
      .map((e) => (e as Map<String, dynamic>)['name'] as String)
      .toList();
}

/// One recorded call to [ChatPersistenceHandler.updateBackgroundChatMessage].
class _RecordedMessageUpdate {
  _RecordedMessageUpdate({
    required this.chatId,
    required this.messageIndex,
    required this.content,
    required this.reasoning,
    required this.toolCallsJson,
    required this.contentBlocksJson,
    required this.images,
    required this.imageMetas,
    required this.imageCostEur,
    required this.imageGeneratedAt,
    required this.tps,
    required this.status,
    required this.immediate,
  });

  final String chatId;
  final int messageIndex;
  final String? content;
  final String? reasoning;
  final String? toolCallsJson;
  final String? contentBlocksJson;
  final String? images;
  final String? imageMetas;
  final String? imageCostEur;
  final String? imageGeneratedAt;
  final String? tps;
  final String? status;
  final bool immediate;
}

/// One recorded call to [ChatPersistenceHandler.persistChat].
class _RecordedChatPersist {
  _RecordedChatPersist({
    required this.messages,
    required this.chatId,
    required this.isOffline,
    required this.silent,
  });

  final List<Map<String, String>> messages;
  final String? chatId;
  final bool isOffline;
  final bool silent;
}

/// Collects the storage writes instead of performing them. Both write entry
/// points are plain instance methods on the real handler, so overriding them
/// keeps every call site — and every argument — exactly as production sees it.
class _RecordingPersistenceHandler extends ChatPersistenceHandler {
  final List<_RecordedMessageUpdate> updates = <_RecordedMessageUpdate>[];
  final List<_RecordedChatPersist> persistedChats = <_RecordedChatPersist>[];

  _RecordedMessageUpdate get singleUpdate {
    expect(
      updates,
      hasLength(1),
      reason: 'exactly one storage write was expected',
    );
    return updates.single;
  }

  @override
  Future<void> updateBackgroundChatMessage({
    required String chatId,
    required int messageIndex,
    String? content,
    String? reasoning,
    String? toolCallsJson,
    String? contentBlocksJson,
    String? images,
    String? imageMetas,
    String? imageCostEur,
    String? imageGeneratedAt,
    String? tps,
    String? status,
    bool immediate = false,
  }) async {
    updates.add(
      _RecordedMessageUpdate(
        chatId: chatId,
        messageIndex: messageIndex,
        content: content,
        reasoning: reasoning,
        toolCallsJson: toolCallsJson,
        contentBlocksJson: contentBlocksJson,
        images: images,
        imageMetas: imageMetas,
        imageCostEur: imageCostEur,
        imageGeneratedAt: imageGeneratedAt,
        tps: tps,
        status: status,
        immediate: immediate,
      ),
    );
  }

  @override
  Future<StoredChat?> persistChat({
    required List<Map<String, String>> messages,
    String? chatId,
    bool waitForCompletion = false,
    bool isOffline = false,
    bool silent = false,
  }) async {
    persistedChats.add(
      _RecordedChatPersist(
        messages: messages
            .map((m) => Map<String, String>.from(m))
            .toList(growable: false),
        chatId: chatId,
        isOffline: isOffline,
        silent: silent,
      ),
    );
    return null;
  }
}

/// Hands out the per-chat streaming snapshot the finalize path rebuilds from.
class _RecordingStreamingHandler extends StreamingMessageHandler {
  final Map<String, List<Map<String, dynamic>>> snapshots =
      <String, List<Map<String, dynamic>>>{};

  @override
  List<Map<String, dynamic>>? getBackgroundMessages(String chatId) =>
      snapshots[chatId];
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.activeChatId,
    required this.initialMessages,
  });

  final String? activeChatId;
  final List<Map<String, String>> initialMessages;

  @override
  State<_Harness> createState() => _HarnessState();
}

/// The smallest host the write mixin accepts: the same three mixins the real
/// chat States use, and nothing else.
class _HarnessState extends State<_Harness>
    with
        ChatScrollMixin<_Harness>,
        RegenVariantSeedMixin<_Harness>,
        AssistantMessageWriteMixin<_Harness> {
  @override
  late final List<Map<String, String>> messages = widget.initialMessages;

  @override
  late final String? activeChatId = widget.activeChatId;

  @override
  final _RecordingPersistenceHandler persistenceHandler =
      _RecordingPersistenceHandler();

  @override
  final _RecordingStreamingHandler streamingHandler =
      _RecordingStreamingHandler();

  @override
  bool isSendingMessage = false;

  @override
  bool isAppInBackground = false;

  @override
  bool isOffline = false;

  @override
  String? get variantActiveChatId => activeChatId;

  int persistChatCalls = 0;
  int drainCalls = 0;

  @override
  Future<Object?> persistChat({bool waitForCompletion = false}) async {
    persistChatCalls++;
    return null;
  }

  @override
  void drainPendingMessages() => drainCalls++;

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
