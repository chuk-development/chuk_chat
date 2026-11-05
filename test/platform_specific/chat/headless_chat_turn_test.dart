// test/platform_specific/chat/headless_chat_turn_test.dart
//
// The headless send of a queued message with the FULL tool loop
// (docs/OFFLINE_SEND.md, bead chuk_chat-gzd8): it runs the chat screen's
// streaming handler with no screen, inside HeadlessTurnScope, and writes
// the answer (text, tool calls, content blocks) right after its question.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:chuk_chat/platform_specific/chat/headless_chat_turn.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/chat_compaction.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/client_request_ids.dart';
import 'package:chuk_chat/services/headless_turn_scope.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';

/// What the fake handler saw, and what it does.
class _Script {
  List<Map<String, String>>? messages;

  /// The handler's own list (the compaction writes onto it).
  List<Map<String, String>>? live;
  int? placeholderIndex;
  String? userInput;
  List<AttachedFile>? files;
  String? systemPrompt;
  String? scopeChat;
  String? requestBase;
  bool toolCalling = false;
  bool runtimeBusyDuringTurn = false;
  Future<void> Function(_FakeHandler h, int placeholder)? run;
}

class _FakeHandler extends StreamingMessageHandler {
  _FakeHandler(this.script);

  final _Script script;
  bool _sending = false;

  @override
  bool get isSending => _sending;
  @override
  bool get isStreaming => false;

  void end() {
    _sending = false;
    onUpdateUI?.call();
  }

  @override
  Future<void> sendMessage({
    required String userInput,
    required List<AttachedFile> attachedFiles,
    required String selectedModelId,
    required String? selectedProviderSlug,
    required List<Map<String, String>> messages,
    required String? systemPrompt,
    required String? activeChatId,
    required int placeholderIndex,
    required Future<String?> Function() getProviderSlug,
    required bool isOffline,
    bool includeRecentImagesInHistory = true,
    bool includeAllImagesInHistory = false,
    bool includeReasoningInHistory = false,
    bool includeToolResultsInHistory = true,
    bool toolCallingEnabled = true,
    bool toolDiscoveryMode = true,
    String? reasoningEffort,
    String? continuePriorText,
    String? continuePriorContentBlocksJson,
    bool regenerate = false,
    bool modelSelectionCaptured = false,
  }) async {
    script
      ..messages = messages.map(Map<String, String>.of).toList()
      ..live = messages
      ..placeholderIndex = placeholderIndex
      ..userInput = userInput
      ..files = attachedFiles
      ..systemPrompt = systemPrompt
      ..scopeChat = HeadlessTurnScope.chatId
      ..requestBase = ClientRequestIds.take(activeChatId)
      ..toolCalling = toolCallingEnabled
      ..runtimeBusyDuringTurn = OfflineSendExecutor.isTurnRunning(
        activeChatId!,
      );
    _sending = true;
    onUpdateUI?.call();
    await script.run?.call(this, placeholderIndex);
  }
}

QueuedMessage _row(String id) => QueuedMessage(
  id: id,
  chatId: 'chat-1',
  sendPayload: const <String, dynamic>{},
  attemptCount: 0,
  createdAt: 0,
  updatedAt: 0,
);

StoredChat _chat(List<ChatMessage> messages) => StoredChat(
  id: 'chat-1',
  messages: messages,
  createdAt: DateTime(2026),
  isStarred: false,
);

const OfflineSendPayload _payload = OfflineSendPayload(
  chatId: 'chat-1',
  messageText: 'what is the weather',
  modelId: 'model-x',
  providerSlug: 'prov',
  systemPrompt: 'be brief',
  imagesJson: '["u/1.enc"]',
  reasoningEffort: 'low',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<ChatMessage> stored;
  late _Script script;
  List<Map<String, dynamic>>? saved;
  var accepted = false;

  setUp(() {
    saved = null;
    accepted = false;
    script = _Script();
    stored = [
      ChatMessage(role: 'user', text: 'earlier'),
      ChatMessage(role: 'assistant', text: 'earlier answer'),
      ChatMessage(
        role: 'user',
        text: 'old failed',
        status: ChatMessageStatus.failed,
        queueId: 'q0',
      ),
      ChatMessage(
        role: 'user',
        text: 'what is the weather',
        status: ChatMessageStatus.pending,
        queueId: 'q1',
        sentAt: '2026-11-05T10:00:00.000',
      ),
      ChatMessage(
        role: 'user',
        text: 'later',
        status: ChatMessageStatus.pending,
        queueId: 'q2',
      ),
    ];
    OfflineSendExecutor.loadChat = (_) async => _chat(stored);
    OfflineSendExecutor.saveChat = (_, maps) async => saved = maps;
    HeadlessChatTurn.handlerFactory = () => _FakeHandler(script);
    HeadlessChatTurn.serverAccepted = (_) => accepted;
    HeadlessChatTurn.settings = () => const HeadlessTurnSettings();
    HeadlessChatTurn.resolveSystemPrompt = (_) async => 'resolved prompt';
  });

  tearDown(() {
    OfflineSendExecutor.resetSeams();
    HeadlessChatTurn.resetSeams();
  });

  test('runs the tool loop and writes the answer right after its question',
      () async {
    script.run = (h, p) async {
      accepted = true;
      h.onToolCallsUpdate?.call(p, [
        ToolCall(
          id: 't1',
          name: 'weather',
          arguments: const {'city': 'Kiel'},
          status: ToolCallStatus.completed,
          result: 'sunny',
        ),
      ], 'chat-1');
      h.onContentBlocksUpdate?.call(p, '[{"type":"text","text":"x"}]', 'chat-1');
      h.onMessageFinalize?.call(p, 'It is sunny.', 'thought', 'chat-1', 12.5);
      h.end();
    };

    final result = await HeadlessChatTurn.run(_row('q1'), _payload);

    expect(result.success, isTrue);
    // The handler saw the delivered history, the queued message as
    // delivered (its send time, no waiting marks), then the placeholder.
    final seen = script.messages!;
    expect(seen.map((m) => m['text']).toList(), [
      'earlier',
      'earlier answer',
      'what is the weather',
      'Thinking...',
    ]);
    expect(seen[2]['sender'], 'user');
    expect(seen[2].containsKey('status'), isFalse);
    expect(seen[2].containsKey('queueId'), isFalse);
    expect(seen[2]['sentAt'], '2026-11-05T10:00:00.000');
    expect(script.placeholderIndex, 3);
    // The row's own request ids: derived from the row, the same each send.
    expect(script.requestBase, 'ob-q1');
    expect(ClientRequestIds.take('chat-1'), isNull);
    expect(script.userInput, 'what is the weather');
    expect(script.files!.single.encryptedImagePath, 'u/1.enc');
    expect(script.files!.single.isImage, isTrue);
    expect(script.systemPrompt, 'be brief');
    expect(script.toolCalling, isTrue);
    // Runs as a headless turn of this chat, and marks the chat busy.
    expect(script.scopeChat, 'chat-1');
    expect(script.runtimeBusyDuringTurn, isTrue);
    expect(OfflineSendExecutor.isTurnRunning('chat-1'), isFalse);

    final maps = saved!;
    expect(maps.map((m) => m['text']).toList(), [
      'earlier',
      'earlier answer',
      'old failed',
      'what is the weather',
      'It is sunny.',
      'later',
    ]);
    final question = maps[3];
    expect(question.containsKey('status'), isFalse);
    expect(question.containsKey('queueId'), isFalse);
    final answer = maps[4];
    expect(answer['sender'], 'ai');
    expect(answer['reasoning'], 'thought');
    expect(answer['toolCalls'], contains('weather'));
    expect(answer['contentBlocks'], contains('text'));
    expect(answer['modelId'], 'model-x');
    expect(maps[5]['queueId'], 'q2');
    ChatRuntimeRegistry.instance.clear();
  });

  test('a send that never reached the server goes back to the outbox',
      () async {
    script.run = (h, p) async {
      await h.onSendNotAccepted?.call('chat-1', p);
      h.end();
    };
    final result = await HeadlessChatTurn.run(_row('q1'), _payload);
    expect(result.success, isFalse);
    expect(result.error, startsWith('network'));
    expect(saved, isNull);
  });

  test('an error before the server answered fails with its text', () async {
    script.run = (h, p) async {
      h.onShowSnackBar?.call('Invalid model');
      h.onMessageFinalize?.call(p, 'Invalid model', '', 'chat-1', null);
      h.end();
    };
    final result = await HeadlessChatTurn.run(_row('q1'), _payload);
    expect(result.success, isFalse);
    expect(result.accepted, isFalse);
    expect(result.error, 'Invalid model');
    expect(saved, isNull);
  });

  test('an error after the server took the turn is kept as the answer',
      () async {
    script.run = (h, p) async {
      accepted = true;
      h.onMessageUpdate?.call(p, 'half an answer', '', 'chat-1');
      h.onMessageFinalize?.call(
        p,
        'half an answer\n\nConnection lost',
        '',
        'chat-1',
        null,
      );
      h.onStreamInterrupted?.call('chat-1', p);
      h.end();
    };
    final result = await HeadlessChatTurn.run(_row('q1'), _payload);
    expect(result.success, isTrue);
    final answer = saved![4];
    expect(answer['text'], contains('half an answer'));
    expect(answer['status'], 'interrupted');
  });

  test('a row queued with no system prompt resolves it at send time',
      () async {
    script.run = (h, p) async {
      accepted = true;
      h.onMessageFinalize?.call(p, 'ok', '', 'chat-1', null);
      h.end();
    };
    await HeadlessChatTurn.run(
      _row('q1'),
      const OfflineSendPayload(
        chatId: 'chat-1',
        messageText: 'what is the weather',
        modelId: 'model-x',
        providerSlug: 'prov',
        resolvePromptAtSend: true,
      ),
    );
    expect(script.systemPrompt, 'resolved prompt');
  });

  test('a turn that ends after sendMessage returned is awaited', () async {
    script.run = (h, p) async {
      // The tool loop goes on after the first pass returned.
      Future<void>.delayed(const Duration(milliseconds: 30), () {
        accepted = true;
        h.onMessageFinalize?.call(p, 'late answer', '', 'chat-1', null);
        h.end();
      });
    };
    final result = await HeadlessChatTurn.run(_row('q1'), _payload);
    expect(result.success, isTrue);
    expect(saved![4]['text'], 'late answer');
  });

  group('request idempotency', () {
    test('a stored base wins over the row id', () async {
      script.run = (h, p) async {
        accepted = true;
        h.onMessageFinalize?.call(p, 'ok', '', 'chat-1', null);
        h.end();
      };
      await HeadlessChatTurn.run(
        _row('q1'),
        const OfflineSendPayload(
          chatId: 'chat-1',
          messageText: 'what is the weather',
          modelId: 'model-x',
          providerSlug: 'prov',
          clientRequestBase: 'c-turn',
        ),
      );
      expect(script.requestBase, 'c-turn');
    });

    test('a dropped socket after acceptance goes back to the outbox',
        () async {
      script.run = (h, p) async {
        accepted = true;
        h.onMessageUpdate?.call(p, 'half an answer', '', 'chat-1');
        h.onMessageFinalize?.call(p, 'half\n\nConnection lost', '', 'c', null);
        h.onTurnError?.call(
          'chat-1',
          p,
          'Connection lost',
          StreamErrorCodes.connectionLost,
        );
        h.end();
      };
      final result = await HeadlessChatTurn.run(_row('q1'), _payload);
      // Re-sent later with the same ids: the server answers it from its
      // record, billed once. Nothing is stored now.
      expect(result.success, isFalse);
      expect(result.accepted, isFalse);
      expect(result.error, startsWith('network'));
      expect(saved, isNull);
    });

    test('an answer still being written goes back to the outbox', () async {
      script.run = (h, p) async {
        accepted = true;
        h.onTurnError?.call('chat-1', p, 'busy', StreamErrorCodes.requestPending);
        h.end();
      };
      final result = await HeadlessChatTurn.run(_row('q1'), _payload);
      expect(result.error, startsWith('network'));
      expect(saved, isNull);
    });

    test('a turn that ran tools keeps its error (no tool runs twice)',
        () async {
      script.run = (h, p) async {
        accepted = true;
        h.onToolCallsUpdate?.call(p, [
          ToolCall(
            id: 't1',
            name: 'weather',
            arguments: const {},
            status: ToolCallStatus.completed,
            result: 'sunny',
          ),
        ], 'chat-1');
        h.onMessageFinalize?.call(p, 'Connection lost', '', 'chat-1', null);
        h.onTurnError?.call(
          'chat-1',
          p,
          'Connection lost',
          StreamErrorCodes.connectionLost,
        );
        h.end();
      };
      final result = await HeadlessChatTurn.run(_row('q1'), _payload);
      expect(result.success, isTrue);
      expect(saved![4]['text'], 'Connection lost');
    });

    test('an error the server cannot de-duplicate is kept as the answer',
        () async {
      expect(
        HeadlessChatTurn.resendable(
          StreamErrorCodes.upstreamInterrupted,
          const {},
        ),
        isFalse,
      );
      expect(HeadlessChatTurn.resendable(null, const {}), isFalse);
      expect(
        HeadlessChatTurn.resendable(StreamErrorCodes.connectionLost, const {
          'toolCalls': '[]',
        }),
        isTrue,
      );
    });
  });

  group('compaction (bead chuk_chat-3b2q)', () {
    test('a summary on the queued message is stored with it', () async {
      script.run = (h, p) async {
        // ChatCompactionRunner writes onto the handler's own rows; here the
        // kept tail starts at the queued message (the row before p).
        script.live![p - 1][ChatCompaction.fieldKey] = '{"summary":"s"}';
        accepted = true;
        h.onMessageFinalize?.call(p, 'ok', '', 'chat-1', null);
        h.end();
      };
      final result = await HeadlessChatTurn.run(_row('q1'), _payload);
      expect(result.success, isTrue);
      final question = saved![3];
      expect(question['text'], 'what is the weather');
      expect(question[ChatCompaction.fieldKey], '{"summary":"s"}');
      expect(question['sentAt'], '2026-11-05T10:00:00.000');
      expect(saved![0].containsKey(ChatCompaction.fieldKey), isFalse);
    });

    test('a summary on an earlier row is stored on that row', () async {
      script.run = (h, p) async {
        script.live![0][ChatCompaction.fieldKey] = '{"summary":"e"}';
        accepted = true;
        h.onMessageFinalize?.call(p, 'ok', '', 'chat-1', null);
        h.end();
      };
      await HeadlessChatTurn.run(_row('q1'), _payload);
      expect(saved![0][ChatCompaction.fieldKey], '{"summary":"e"}');
      expect(saved![3].containsKey(ChatCompaction.fieldKey), isFalse);
    });

    test('a bubble with no text (voice) is sent with the queued text', () {
      final row = HeadlessChatTurn.queuedRow(
        ChatMessage(
          role: 'user',
          text: '',
          status: ChatMessageStatus.pending,
          queueId: 'q9',
        ),
        'transcript',
      );
      expect(row['text'], 'transcript');
      expect(row['sentAt'], isNotEmpty);
      expect(row.containsKey('queueId'), isFalse);
    });
  });

  test('the queued message is the turn being sent, not history', () async {
    // A bubble that shows only the document names: the handler gets the
    // queued text (documents inlined) both as userInput and as the row.
    final row = HeadlessChatTurn.queuedRow(
      ChatMessage(
        role: 'user',
        text: 'Documents: a.txt\n\nsum it up',
        status: ChatMessageStatus.pending,
        queueId: 'q1',
        sentAt: '2026-11-05T10:00:00.000',
      ),
      'Document: "a.txt"\nbody\n\nsum it up',
    );
    final history = await ChatHistoryBuilder.build(
      messages: [
        {'sender': 'user', 'text': 'earlier', 'sentAt': '2026-11-05T09:00:00.000'},
        {'sender': 'ai', 'text': 'earlier answer'},
        row,
      ],
      pendingUserText: 'Document: "a.txt"\nbody\n\nsum it up',
    );
    expect(history, hasLength(2));
    expect(history.last['role'], 'assistant');
  });
}
