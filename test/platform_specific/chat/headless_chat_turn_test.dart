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
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/headless_turn_scope.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';

/// What the fake handler saw, and what it does.
class _Script {
  List<Map<String, String>>? messages;
  int? placeholderIndex;
  String? userInput;
  List<AttachedFile>? files;
  String? systemPrompt;
  String? scopeChat;
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
      ..placeholderIndex = placeholderIndex
      ..userInput = userInput
      ..files = attachedFiles
      ..systemPrompt = systemPrompt
      ..scopeChat = HeadlessTurnScope.chatId
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
    // The handler saw the delivered history only, then the placeholder.
    final seen = script.messages!;
    expect(seen.map((m) => m['text']).toList(), [
      'earlier',
      'earlier answer',
      'Thinking...',
    ]);
    expect(script.placeholderIndex, 2);
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
}
