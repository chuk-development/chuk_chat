import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/chat_reply.dart';

void main() {
  test('reply preserves quoted context and typed answer across replay', () {
    const reply = ChatReply(
      author: 'AI',
      text: 'Old answer\nwith **Markdown**',
    );
    final prompt = reply.compose('Please explain this.');
    expect(prompt, contains('> Old answer\n> with **Markdown**'));
    final parsed = ChatReply.parse(prompt)!;
    expect(parsed.reply.author, 'AI');
    expect(parsed.reply.text, reply.text);
    expect(parsed.message, 'Please explain this.');
  });
  test('ordinary messages are not interpreted as reply metadata', () {
    expect(ChatReply.parse('Hello\n\nworld'), isNull);
    expect(ChatReply.parse('> ordinary quote\n\nanswer'), isNull);
  });
  test('very long quotes are bounded without truncating the user answer', () {
    final prompt = ChatReply(author: 'You', text: 'x' * 7000).compose('Answer');
    final parsed = ChatReply.parse(prompt)!;
    expect(parsed.reply.text, endsWith('[quote shortened]'));
    expect(parsed.message, 'Answer');
  });
}
