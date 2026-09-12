import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/chat_message_list_item.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('maps shared row data, grouping, and variant navigation', (
    tester,
  ) async {
    final messages = <Map<String, String>>[
      {'sender': 'user', 'text': 'question'},
      {'sender': 'ai', 'text': 'first answer', 'messageId': 'answer-1'},
      {'sender': 'ai', 'text': 'second answer', 'messageId': 'answer-2'},
    ];
    final switchedTo = <int>[];
    var continued = false;
    const data = MessageRenderData(
      sender: 'ai',
      displayText: 'first answer',
      reasoning: 'because',
      isReasoningStreaming: false,
      modelLabel: 'Model',
      modelProvider: 'provider',
      tps: 42,
      variantIndex: 1,
      variantCount: 3,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageListItem(
            messages: messages,
            index: 1,
            data: data,
            uuid: const Uuid(),
            maxWidth: 500,
            activeChatId: null,
            flyInKey: null,
            showToolCalls: true,
            showReasoningTokens: true,
            showModelInfo: true,
            showTps: true,
            isEditing: false,
            actions: const <MessageBubbleAction>[],
            userMessageActions: const <MessageBubbleAction>[],
            onSwitchVariant: switchedTo.add,
            onContinueGeneration: () => continued = true,
          ),
        ),
      ),
    );
    await tester.pump();

    final bubble = tester.widget<MessageBubble>(find.byType(MessageBubble));
    expect(bubble.message, 'first answer');
    expect(bubble.reasoning, 'because');
    expect(bubble.startsNewGroup, isTrue);
    expect(bubble.endsGroup, isFalse);
    expect(bubble.maxWidth, 500);
    expect(bubble.modelLabel, 'Model');
    expect(bubble.tps, 42);
    expect(bubble.useSharedSelectionArea, isTrue);

    bubble.onPrevVariant!();
    bubble.onNextVariant!();
    bubble.onContinueGeneration!();
    expect(switchedTo, [0, 2]);
    expect(continued, isTrue);
  });

  testWidgets('rebuilds only the active assistant row from live stream data', (
    tester,
  ) async {
    final runtime = ChatRuntimeRegistry.instance.get('chat-1');
    runtime.beginStream(placeholderIndex: 0, modelId: 'model');
    runtime.pushStreamingText(
      index: 0,
      text: 'live first',
      reasoning: 'thinking first',
    );
    final messages = <Map<String, String>>[
      {'sender': 'ai', 'text': 'stale', 'messageId': 'answer-1'},
    ];

    Widget item() => MaterialApp(
      home: Scaffold(
        body: ChatMessageListItem(
          messages: messages,
          index: 0,
          data: const MessageRenderData(
            sender: 'ai',
            displayText: 'stale',
            reasoning: '',
            isReasoningStreaming: true,
            isStreamingMessage: true,
          ),
          uuid: const Uuid(),
          maxWidth: 500,
          activeChatId: 'chat-1',
          flyInKey: null,
          showToolCalls: true,
          showReasoningTokens: true,
          showModelInfo: true,
          showTps: true,
          isEditing: false,
          actions: const <MessageBubbleAction>[],
          userMessageActions: const <MessageBubbleAction>[],
          onSwitchVariant: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(item());
    await tester.pump();
    expect(
      tester.widget<MessageBubble>(find.byType(MessageBubble)).message,
      'live first',
    );

    runtime.pushStreamingText(
      index: 0,
      text: 'live second',
      reasoning: 'thinking second',
    );
    await tester.pump();
    final bubble = tester.widget<MessageBubble>(find.byType(MessageBubble));
    expect(bubble.message, 'live second');
    expect(bubble.reasoning, 'thinking second');

    await tester.pumpWidget(const SizedBox());
    runtime.endStream();
    expect(ChatRuntimeRegistry.instance.release('chat-1'), isTrue);
  });
}
