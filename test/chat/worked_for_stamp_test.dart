// How long the answer took, written down when it is saved.
//
// The header used to derive its number from the tool-call stamps, which say
// nothing about the wait before the first tool and are gone entirely once
// the chat is reopened. The turn now carries its own start and its own
// measured length; this is the half that writes the length down.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/handlers/chat_persistence_handler.dart';

Map<String, String> _assistant({String? startedAt, String? generationMs}) => {
  'sender': 'ai',
  'text': 'the answer',
  if (startedAt != null) 'startedAt': startedAt,
  if (generationMs != null) 'generationMs': generationMs,
};

void main() {
  group('stamping how long a turn took', () {
    test('an answer gets the time since its request went out', () {
      final messages = [
        {'sender': 'user', 'text': 'hi'},
        _assistant(
          startedAt: DateTime.now()
              .subtract(const Duration(seconds: 8))
              .toIso8601String(),
        ),
      ];

      ChatPersistenceHandler.stampWorkedFor(messages);

      final ms = int.parse(messages.last['generationMs']!);
      expect(ms, greaterThanOrEqualTo(8000));
      expect(ms, lessThan(9000));
    });

    test('the newest answer is restamped as its tool rounds go on', () {
      // A turn that runs tools is saved once per round. Each save is a
      // better estimate than the one before, so the last one wins.
      final messages = [
        _assistant(
          startedAt: DateTime.now()
              .subtract(const Duration(seconds: 30))
              .toIso8601String(),
          generationMs: '4000',
        ),
      ];

      ChatPersistenceHandler.stampWorkedFor(messages);

      expect(int.parse(messages.single['generationMs']!), greaterThan(29000));
    });

    test('an older answer keeps the number it settled on', () {
      // Otherwise every later save in the chat would inflate it.
      final messages = [
        _assistant(
          startedAt: DateTime.now()
              .subtract(const Duration(minutes: 20))
              .toIso8601String(),
          generationMs: '4000',
        ),
        {'sender': 'user', 'text': 'and now?'},
      ];

      ChatPersistenceHandler.stampWorkedFor(messages);

      expect(messages.first['generationMs'], '4000');
    });

    test('a user message is never stamped', () {
      final messages = [
        {
          'sender': 'user',
          'text': 'hi',
          'startedAt': DateTime.now().toIso8601String(),
        },
      ];

      ChatPersistenceHandler.stampWorkedFor(messages);

      expect(messages.single.containsKey('generationMs'), isFalse);
    });

    test('a message from before the stamp is left alone', () {
      final messages = [_assistant()];

      ChatPersistenceHandler.stampWorkedFor(messages);

      expect(messages.single.containsKey('generationMs'), isFalse);
    });

    test('a clock that moved backwards writes nothing', () {
      final messages = [
        _assistant(
          startedAt: DateTime.now()
              .add(const Duration(minutes: 5))
              .toIso8601String(),
        ),
      ];

      ChatPersistenceHandler.stampWorkedFor(messages);

      expect(messages.single.containsKey('generationMs'), isFalse);
    });
  });
}
