import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';

void main() {
  group('assistant message read-aloud action', () {
    test('adds speaker after copy for a completed assistant answer', () {
      final handler = MessageActionsHandler();
      final actions = handler.buildActionsForMessage(
        index: 0,
        messageText: 'A completed answer',
        isUser: false,
        isStreaming: false,
        onEdit: (_) {},
        onResendMessage: (_) {},
        onSpeak: (_) async {},
      );

      expect(
        actions.map((action) => action.icon),
        contains(Icons.volume_up_outlined),
      );
      expect(actions.map((action) => action.label), contains('Read aloud'));
      expect(actions.first.label, 'Copy');
    });

    test('active answer offers stop and invokes the speech toggle', () {
      String? toggled;
      final actions = MessageActionsHandler().buildActionsForMessage(
        index: 0,
        messageText: 'A completed answer',
        isUser: false,
        isStreaming: false,
        onEdit: (_) {},
        onResendMessage: (_) {},
        onSpeak: (text) async => toggled = text,
        activeSpeechText: 'A completed answer',
      );
      final stop = actions.singleWhere((action) => action.label == 'Stop');
      expect(stop.icon, Icons.stop_rounded);
      stop.onPressed();
      expect(toggled, 'A completed answer');
    });

    test(
      'another answer keeps its read-aloud action while speech is active',
      () {
        final actions = MessageActionsHandler().buildActionsForMessage(
          index: 0,
          messageText: 'A different answer',
          isUser: false,
          isStreaming: false,
          onEdit: (_) {},
          onResendMessage: (_) {},
          onSpeak: (_) async {},
          activeSpeechText: 'Currently speaking',
        );
        expect(actions.any((action) => action.label == 'Read aloud'), isTrue);
        expect(actions.any((action) => action.label == 'Stop'), isFalse);
      },
    );

    test('does not offer speech while the assistant is streaming', () {
      final actions = MessageActionsHandler().buildActionsForMessage(
        index: 0,
        messageText: 'Partial answer',
        isUser: false,
        isStreaming: true,
        onEdit: (_) {},
        onResendMessage: (_) {},
        onSpeak: (_) async {},
      );

      expect(actions.any((action) => action.label == 'Read aloud'), isFalse);
    });
  });
}
