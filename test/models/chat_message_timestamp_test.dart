import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('actual timestamp survives JSON copy and raw UI projection', () {
    final message = ChatMessage(
      role: 'assistant',
      text: 'Hello',
      sentAt: '2026-09-08T12:30:05.000Z',
      startedAt: '2026-09-08T12:30:00.000Z',
      generationMs: '5000',
    );
    final loaded = ChatMessage.fromJson(message.toJson()).copyWith(text: 'Hi');
    expect(loaded.sentAt, message.sentAt);
    expect(loaded.workedFor, const Duration(seconds: 5));
    expect(ChatUiHelpers.messageToRawMap(loaded)['sentAt'], message.sentAt);
  });

  test('legacy history without timestamp does not invent one', () {
    final message = ChatMessage.fromJson({'role': 'user', 'text': 'old'});
    expect(message.sentAt, isNull);
    expect(message.toJson().containsKey('sentAt'), isFalse);
    expect(
      ChatUiHelpers.messageToRawMap(message).containsKey('sentAt'),
      isFalse,
    );
  });
}
