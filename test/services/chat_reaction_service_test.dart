import 'package:chuk_chat/services/chat_reaction_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reaction persists across reload and toggles off', () async {
    final service = ChatReactionService();
    await service.toggle('chat', 'message', '❤️', userId: 'alice');
    final restored = ChatReactionService();
    await restored.load('chat', userId: 'alice');
    expect(restored.peek('chat', 'message', userId: 'alice'), '❤️');
    await restored.toggle('chat', 'message', '❤️', userId: 'alice');
    expect(restored.peek('chat', 'message', userId: 'alice'), isNull);
    final again = ChatReactionService();
    await again.load('chat', userId: 'alice');
    expect(again.peek('chat', 'message', userId: 'alice'), isNull);
  });

  test('account, chat and message scopes stay isolated', () async {
    final service = ChatReactionService();
    await service.toggle('chat', 'message', '👍', userId: 'alice');
    await service.load('chat', userId: 'bob');
    await service.load('other', userId: 'alice');
    expect(service.peek('chat', 'message', userId: 'bob'), isNull);
    expect(service.peek('other', 'message', userId: 'alice'), isNull);
    expect(service.peek('chat', 'other', userId: 'alice'), isNull);
  });

  test(
    'overlapping toggles serialize without dropping other messages',
    () async {
      final service = ChatReactionService();
      await Future.wait([
        service.toggle('chat', 'first', '👍', userId: 'a'),
        service.toggle('chat', 'second', '❤️', userId: 'a'),
        service.toggle('chat', 'first', '😂', userId: 'a'),
      ]);
      expect(service.peek('chat', 'first', userId: 'a'), '😂');
      expect(service.peek('chat', 'second', userId: 'a'), '❤️');
    },
  );

  test(
    'persisted ID survives content edits and legacy key survives replay',
    () {
      expect(
        ChatReactionService.messageKey({
          'messageId': 'stable',
          'text': 'before',
        }),
        ChatReactionService.messageKey({
          'messageId': 'stable',
          'text': 'after',
        }),
      );
      final first = {
        'sender': 'user',
        'text': 'Hey',
        'sentAt': '2026-09-10',
        '_uiKey': 'random1',
      };
      final replay = {...first, '_uiKey': 'random2'};
      expect(
        ChatReactionService.messageKey(first),
        ChatReactionService.messageKey(replay),
      );
      expect(
        ChatReactionService.messageKey(first),
        isNot(ChatReactionService.messageKey({...first, 'sender': 'ai'})),
      );
    },
  );
}
