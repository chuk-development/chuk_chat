import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the newest sentAt/startedAt wins; none gives null', () {
    expect(newestMessageTime(null), isNull);
    expect(newestMessageTime(const <ChatMessage>[]), isNull);
    final messages = <ChatMessage>[
      ChatMessage.fromJson({'role': 'user', 'content': 'a', 'sentAt': '2026-09-20T08:00:00Z'}),
      ChatMessage.fromJson({'role': 'assistant', 'content': 'b', 'startedAt': '2026-09-22T09:00:00Z'}),
      ChatMessage.fromJson({'role': 'user', 'content': 'c'}),
    ];
    expect(newestMessageTime(messages)?.toUtc(), DateTime.utc(2026, 9, 22, 9));
  });
}
