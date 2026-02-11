// test/services/streaming_manager_test.dart
//
// Unit tests for StreamingManager — verifies that streaming responses
// are preserved when the user switches between chats.

import 'dart:async';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // StreamingManager is a singleton, so we clean up between tests
  final manager = StreamingManager();

  tearDown(() async {
    await manager.cancelAllStreams();
  });

  // ---------------------------------------------------------------------------
  // Helper: create a controllable stream and start it on the manager
  // ---------------------------------------------------------------------------
  Future<_TestStreamContext> startTestStream({
    String chatId = 'chat-1',
    int messageIndex = 1,
    String? chatTitle,
  }) async {
    final controller = StreamController<ChatStreamEvent>();
    String lastContent = '';
    String lastReasoning = '';
    double? lastTps;
    bool completed = false;
    String? errorMsg;

    await manager.startStream(
      chatId: chatId,
      messageIndex: messageIndex,
      stream: controller.stream,
      chatTitle: chatTitle,
      onUpdate: (content, reasoning) {
        lastContent = content;
        lastReasoning = reasoning;
      },
      onComplete: (content, reasoning, tps) {
        lastContent = content;
        lastReasoning = reasoning;
        lastTps = tps;
        completed = true;
      },
      onError: (error) {
        errorMsg = error;
      },
    );

    return _TestStreamContext(
      controller: controller,
      getContent: () => lastContent,
      getReasoning: () => lastReasoning,
      getTps: () => lastTps,
      isCompleted: () => completed,
      getError: () => errorMsg,
    );
  }

  group('active streaming', () {
    test('isStreaming returns true while stream is active', () async {
      final ctx = await startTestStream();

      expect(manager.isStreaming('chat-1'), isTrue);
      expect(manager.hasActiveStreams, isTrue);

      await ctx.controller.close();
      // Allow async handlers to process
      await Future.delayed(Duration.zero);
    });

    test('content events accumulate in buffer', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('Hello '));
      await Future.delayed(Duration.zero);
      expect(ctx.getContent(), equals('Hello '));
      expect(manager.getBufferedContent('chat-1'), equals('Hello '));

      ctx.controller.add(const ContentEvent('world!'));
      await Future.delayed(Duration.zero);
      expect(ctx.getContent(), equals('Hello world!'));
      expect(manager.getBufferedContent('chat-1'), equals('Hello world!'));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('reasoning events accumulate in buffer', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ReasoningEvent('Let me think'));
      await Future.delayed(Duration.zero);
      expect(ctx.getReasoning(), equals('Let me think'));
      expect(manager.getBufferedReasoning('chat-1'), equals('Let me think'));

      ctx.controller.add(const ReasoningEvent('... more'));
      await Future.delayed(Duration.zero);
      expect(ctx.getReasoning(), equals('Let me think... more'));
      expect(manager.getBufferedReasoning('chat-1'), equals('Let me think... more'));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('TPS event is stored', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const TpsEvent(42.5));
      await Future.delayed(Duration.zero);
      expect(manager.getTps('chat-1'), equals(42.5));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('getStreamingMessageIndex returns correct index', () async {
      await startTestStream(messageIndex: 3);

      expect(manager.getStreamingMessageIndex('chat-1'), equals(3));

      await manager.cancelStream('chat-1');
    });
  });

  group('stream completion — the chat-switch bug fix', () {
    test('DoneEvent completes stream but preserves buffered content', () async {
      final ctx = await startTestStream();

      // Simulate AI generating content
      ctx.controller.add(const ReasoningEvent('Thinking about the answer...'));
      await Future.delayed(Duration.zero);
      ctx.controller.add(const ContentEvent('Here is the answer.'));
      await Future.delayed(Duration.zero);
      ctx.controller.add(const TpsEvent(35.0));
      await Future.delayed(Duration.zero);
      ctx.controller.add(const DoneEvent());
      await Future.delayed(Duration.zero);

      // Stream should no longer be "actively streaming"
      expect(manager.isStreaming('chat-1'), isFalse);
      expect(manager.hasActiveStreams, isFalse);

      // But the completed stream data should still be available
      // (this is the core fix — previously this data was lost)
      expect(manager.hasCompletedStream('chat-1'), isTrue);
      expect(manager.getBufferedContent('chat-1'), equals('Here is the answer.'));
      expect(
        manager.getBufferedReasoning('chat-1'),
        equals('Thinking about the answer...'),
      );
      expect(manager.getStreamingMessageIndex('chat-1'), equals(1));

      // The onComplete callback should have been called
      expect(ctx.isCompleted(), isTrue);
      expect(ctx.getContent(), equals('Here is the answer.'));
      expect(ctx.getReasoning(), equals('Thinking about the answer...'));
      expect(ctx.getTps(), equals(35.0));
    });

    test('stream close (no DoneEvent) also preserves content', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('Partial response'));
      await Future.delayed(Duration.zero);

      // Close stream without DoneEvent (e.g., server closed connection)
      await ctx.controller.close();
      await Future.delayed(Duration.zero);

      // Content should still be available
      expect(manager.hasCompletedStream('chat-1'), isTrue);
      expect(manager.getBufferedContent('chat-1'), equals('Partial response'));
      expect(ctx.isCompleted(), isTrue);
    });

    test('consumeCompletedStream removes the entry', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('Done'));
      await Future.delayed(Duration.zero);
      ctx.controller.add(const DoneEvent());
      await Future.delayed(Duration.zero);

      expect(manager.hasCompletedStream('chat-1'), isTrue);

      // Simulate the UI consuming the completed stream data
      manager.consumeCompletedStream('chat-1');

      expect(manager.hasCompletedStream('chat-1'), isFalse);
      expect(manager.getBufferedContent('chat-1'), isNull);
      expect(manager.getBufferedReasoning('chat-1'), isNull);
      expect(manager.getStreamingMessageIndex('chat-1'), isNull);
    });

    test('consumeCompletedStream does not affect active streams', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('Still streaming'));
      await Future.delayed(Duration.zero);

      // Try to consume while still active — should be a no-op
      manager.consumeCompletedStream('chat-1');

      expect(manager.isStreaming('chat-1'), isTrue);
      expect(manager.getBufferedContent('chat-1'), equals('Still streaming'));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });
  });

  group('edge cases', () {
    test('DoneEvent with no content still marks stream as completed', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const DoneEvent());
      await Future.delayed(Duration.zero);

      expect(manager.hasCompletedStream('chat-1'), isTrue);
      expect(manager.getBufferedContent('chat-1'), isNull); // empty buffer
      expect(ctx.isCompleted(), isTrue);
      expect(ctx.getContent(), equals('')); // callback receives empty string
    });

    test('UsageEvent and MetaEvent are silently ignored', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const UsageEvent({'prompt_tokens': 10}));
      ctx.controller.add(const MetaEvent({'model': 'gpt-4'}));
      ctx.controller.add(const ContentEvent('After meta'));
      await Future.delayed(Duration.zero);

      expect(ctx.getContent(), equals('After meta'));
      expect(manager.isStreaming('chat-1'), isTrue);

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('TPS returns null after stream completion', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const TpsEvent(42.5));
      await Future.delayed(Duration.zero);
      expect(manager.getTps('chat-1'), equals(42.5));

      ctx.controller.add(const DoneEvent());
      await Future.delayed(Duration.zero);
      expect(manager.getTps('chat-1'), isNull);
    });

    test('rapid content events accumulate in order', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('a'));
      ctx.controller.add(const ContentEvent('b'));
      ctx.controller.add(const ContentEvent('c'));
      await Future.delayed(Duration.zero);

      expect(manager.getBufferedContent('chat-1'), equals('abc'));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });
  });

  group('error handling', () {
    test('ErrorEvent cleans up stream immediately (no completed entry)', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('Partial'));
      await Future.delayed(Duration.zero);
      ctx.controller.add(const ErrorEvent('API rate limit exceeded'));
      await Future.delayed(Duration.zero);

      // Error should clean up the stream entirely
      expect(manager.isStreaming('chat-1'), isFalse);
      expect(manager.hasCompletedStream('chat-1'), isFalse);
      expect(manager.getBufferedContent('chat-1'), isNull);

      // Error callback should have fired
      expect(ctx.getError(), equals('API rate limit exceeded'));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('subscription error cleans up stream', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('Before error'));
      await Future.delayed(Duration.zero);
      ctx.controller.addError('Stream transport error');
      await Future.delayed(Duration.zero);

      expect(manager.isStreaming('chat-1'), isFalse);
      expect(manager.hasCompletedStream('chat-1'), isFalse);
      expect(ctx.getError(), contains('Stream transport error'));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });
  });

  group('cancel stream', () {
    test('cancelStream stops and removes stream', () async {
      final ctx = await startTestStream();

      ctx.controller.add(const ContentEvent('Will be cancelled'));
      await Future.delayed(Duration.zero);

      await manager.cancelStream('chat-1');

      expect(manager.isStreaming('chat-1'), isFalse);
      expect(manager.hasCompletedStream('chat-1'), isFalse);
      expect(manager.getBufferedContent('chat-1'), isNull);

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('cancelAllStreams stops all streams', () async {
      final ctx1 = await startTestStream(chatId: 'chat-1');
      final ctx2 = await startTestStream(chatId: 'chat-2');

      ctx1.controller.add(const ContentEvent('Chat 1'));
      ctx2.controller.add(const ContentEvent('Chat 2'));
      await Future.delayed(Duration.zero);

      await manager.cancelAllStreams();

      expect(manager.isStreaming('chat-1'), isFalse);
      expect(manager.isStreaming('chat-2'), isFalse);
      expect(manager.hasActiveStreams, isFalse);

      await ctx1.controller.close();
      await ctx2.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('starting a new stream on same chat cancels the old one', () async {
      final ctx1 = await startTestStream(chatId: 'chat-1');
      ctx1.controller.add(const ContentEvent('Old response'));
      await Future.delayed(Duration.zero);

      // Start a new stream on the same chat
      final ctx2 = await startTestStream(chatId: 'chat-1');
      ctx2.controller.add(const ContentEvent('New response'));
      await Future.delayed(Duration.zero);

      expect(manager.isStreaming('chat-1'), isTrue);
      expect(manager.getBufferedContent('chat-1'), equals('New response'));

      await ctx1.controller.close();
      await ctx2.controller.close();
      await Future.delayed(Duration.zero);
    });
  });

  group('multiple concurrent chats', () {
    test('independent streams in different chats', () async {
      final ctx1 = await startTestStream(chatId: 'chat-1', messageIndex: 0);
      final ctx2 = await startTestStream(chatId: 'chat-2', messageIndex: 3);

      ctx1.controller.add(const ContentEvent('Response A'));
      ctx2.controller.add(const ContentEvent('Response B'));
      await Future.delayed(Duration.zero);

      expect(manager.getBufferedContent('chat-1'), equals('Response A'));
      expect(manager.getBufferedContent('chat-2'), equals('Response B'));
      expect(manager.getStreamingMessageIndex('chat-1'), equals(0));
      expect(manager.getStreamingMessageIndex('chat-2'), equals(3));

      // Complete one, other continues
      ctx1.controller.add(const DoneEvent());
      await Future.delayed(Duration.zero);

      expect(manager.isStreaming('chat-1'), isFalse);
      expect(manager.isStreaming('chat-2'), isTrue);
      expect(manager.hasActiveStreams, isTrue);
      expect(manager.hasCompletedStream('chat-1'), isTrue);
      expect(manager.getBufferedContent('chat-1'), equals('Response A'));

      await ctx2.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('getActiveStreamsInfo shows correct state', () async {
      final ctx1 = await startTestStream(chatId: 'chat-1');
      final ctx2 = await startTestStream(chatId: 'chat-2');

      ctx1.controller.add(const DoneEvent());
      await Future.delayed(Duration.zero);

      final info = manager.getActiveStreamsInfo();
      expect(info['chat-1'], isFalse); // completed
      expect(info['chat-2'], isTrue); // still active

      await ctx2.controller.close();
      await Future.delayed(Duration.zero);
    });
  });

  group('background messages', () {
    test('store and retrieve background messages with content and reasoning', () async {
      final ctx = await startTestStream(chatId: 'chat-1', messageIndex: 1);

      // Simulate some content and reasoning
      ctx.controller.add(const ContentEvent('Hello'));
      ctx.controller.add(const ReasoningEvent('Thinking...'));
      await Future.delayed(Duration.zero);

      // Simulate user switching away — store current messages
      final messages = [
        {'role': 'user', 'text': 'Hi there'},
        {'role': 'assistant', 'text': '', 'reasoning': ''},
      ];
      manager.setBackgroundMessages('chat-1', messages,
          modelId: 'gpt-4', provider: 'openai');

      expect(manager.hasBackgroundMessages('chat-1'), isTrue);

      // More content arrives while in background
      ctx.controller.add(const ContentEvent(' world!'));
      await Future.delayed(Duration.zero);

      // Retrieve background messages — should have updated content and reasoning
      final retrieved = manager.getBackgroundMessages('chat-1');
      expect(retrieved, isNotNull);
      expect(retrieved![1]['text'], equals('Hello world!'));
      expect(retrieved[1]['reasoning'], equals('Thinking...'));

      await ctx.controller.close();
      await Future.delayed(Duration.zero);
    });

    test('background messages not available for completed streams', () async {
      final ctx = await startTestStream(chatId: 'chat-1', messageIndex: 1);

      ctx.controller.add(const ContentEvent('Done'));
      await Future.delayed(Duration.zero);

      manager.setBackgroundMessages('chat-1', [
        {'role': 'user', 'text': 'Hi'},
        {'role': 'assistant', 'text': ''},
      ]);

      ctx.controller.add(const DoneEvent());
      await Future.delayed(Duration.zero);

      // After completion, background messages should not be available
      // (the stream is no longer active)
      expect(manager.hasBackgroundMessages('chat-1'), isFalse);
      expect(manager.getBackgroundMessages('chat-1'), isNull);
    });

    test('setBackgroundMessages is a no-op for nonexistent chat', () {
      manager.setBackgroundMessages('nonexistent', [
        {'role': 'user', 'text': 'Hi'},
      ]);
      expect(manager.hasBackgroundMessages('nonexistent'), isFalse);
    });
  });

  group('nonexistent chat queries', () {
    test('all getters return null/false for unknown chats', () {
      expect(manager.isStreaming('nonexistent'), isFalse);
      expect(manager.hasCompletedStream('nonexistent'), isFalse);
      expect(manager.getBufferedContent('nonexistent'), isNull);
      expect(manager.getBufferedReasoning('nonexistent'), isNull);
      expect(manager.getStreamingMessageIndex('nonexistent'), isNull);
      expect(manager.getTps('nonexistent'), isNull);
      expect(manager.hasBackgroundMessages('nonexistent'), isFalse);
      expect(manager.getBackgroundMessages('nonexistent'), isNull);
    });
  });

  group('eviction of completed streams', () {
    test('max completed streams limit is enforced', () async {
      // Create and complete more than _maxCompletedStreams (5) streams
      for (int i = 0; i < 7; i++) {
        final ctx = await startTestStream(
          chatId: 'evict-$i',
          messageIndex: i,
        );
        ctx.controller.add(ContentEvent('Content $i'));
        await Future.delayed(Duration.zero);
        ctx.controller.add(const DoneEvent());
        await Future.delayed(Duration.zero);
      }

      // Should only keep the most recent 5 completed streams
      // Oldest (evict-0, evict-1) should have been evicted
      int completedCount = 0;
      for (int i = 0; i < 7; i++) {
        if (manager.hasCompletedStream('evict-$i')) {
          completedCount++;
        }
      }
      expect(completedCount, lessThanOrEqualTo(5));

      // Most recent should definitely still be there
      expect(manager.hasCompletedStream('evict-6'), isTrue);
      expect(manager.getBufferedContent('evict-6'), equals('Content 6'));
    });
  });

  group('lifecycle callbacks', () {
    test('onAppLifecycleChanged does not crash on Linux', () {
      // Just verify it doesn't throw — the Android-specific logic
      // won't execute on Linux
      expect(
        () => manager.onAppLifecycleChanged(isInBackground: true),
        returnsNormally,
      );
      expect(
        () => manager.onAppLifecycleChanged(isInBackground: false),
        returnsNormally,
      );
    });
  });
}

/// Helper class to hold test stream state
class _TestStreamContext {
  final StreamController<ChatStreamEvent> controller;
  final String Function() getContent;
  final String Function() getReasoning;
  final double? Function() getTps;
  final bool Function() isCompleted;
  final String? Function() getError;

  _TestStreamContext({
    required this.controller,
    required this.getContent,
    required this.getReasoning,
    required this.getTps,
    required this.isCompleted,
    required this.getError,
  });
}
