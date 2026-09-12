// The composer's outbox and its primary target (bead cowork-bj88).
//
// The user may fire as many messages as they want while the coworker works.
// Two things must hold: the messages go out in the order they were typed, and
// the send target never turns into a stop.
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/chat/composer_queue.dart';

void main() {
  group('PendingMessageQueue', () {
    test('two messages go out in the order they were typed', () {
      final PendingMessageQueue queue = PendingMessageQueue();
      queue.add('first');
      queue.add('second');

      expect(queue.length, 2);
      expect(queue.items, <String>['first', 'second']);
      expect(queue.next, 'first');
      expect(queue.takeNext(), 'first');
      expect(queue.takeNext(), 'second');
      expect(queue.takeNext(), isNull);
      expect(queue.isEmpty, isTrue);
    });

    test('three messages go out in the order they were typed', () {
      final PendingMessageQueue queue = PendingMessageQueue();
      queue.add('one');
      queue.add('two');
      queue.add('three');

      expect(queue.length, 3);
      final List<String> drained = <String>[];
      for (
        String? next = queue.takeNext();
        next != null;
        next = queue.takeNext()
      ) {
        drained.add(next);
      }
      expect(drained, <String>['one', 'two', 'three']);
      expect(queue.isEmpty, isTrue);
    });

    test('a second message never overwrites the first', () {
      // The single slot this replaced kept only the newest message.
      final PendingMessageQueue queue = PendingMessageQueue();
      queue.add('keep me');
      queue.add('and me');
      expect(queue.items, contains('keep me'));
      expect(queue.length, 2);
    });

    test('a message keeps its place while the queue drains and grows', () {
      final PendingMessageQueue queue = PendingMessageQueue();
      queue.add('a');
      queue.add('b');
      expect(queue.takeNext(), 'a');
      queue.add('c');
      expect(queue.items, <String>['b', 'c']);
      expect(queue.takeNext(), 'b');
      expect(queue.takeNext(), 'c');
    });

    test('blank text is not a message, and text is trimmed', () {
      final PendingMessageQueue queue = PendingMessageQueue();
      queue.add('   ');
      queue.add('\n\t');
      expect(queue.isEmpty, isTrue);
      queue.add('  padded  ');
      expect(queue.items, <String>['padded']);
    });

    test('clear drops everything and hands back what was dropped', () {
      final PendingMessageQueue queue = PendingMessageQueue();
      queue.add('one');
      queue.add('two');
      expect(queue.clear(), <String>['one', 'two']);
      expect(queue.isEmpty, isTrue);
      expect(queue.clear(), isEmpty);
    });

    test('items is a copy, so a caller cannot reorder the queue', () {
      final PendingMessageQueue queue = PendingMessageQueue();
      queue.add('one');
      expect(() => queue.items.add('two'), throwsUnsupportedError);
      expect(queue.length, 1);
    });
  });

  group('composerActionFor', () {
    test('a tap while the coworker works still sends', () {
      expect(
        composerActionFor(
          isRecording: false,
          isWorking: true,
          hasText: true,
          voiceModeEnabled: false,
        ),
        ComposerAction.send,
      );
    });

    test('working never changes what the primary target does', () {
      for (final bool isRecording in <bool>[false, true]) {
        for (final bool hasText in <bool>[false, true]) {
          for (final bool voiceMode in <bool>[false, true]) {
            final ComposerAction idle = composerActionFor(
              isRecording: isRecording,
              isWorking: false,
              hasText: hasText,
              voiceModeEnabled: voiceMode,
            );
            final ComposerAction working = composerActionFor(
              isRecording: isRecording,
              isWorking: true,
              hasText: hasText,
              voiceModeEnabled: voiceMode,
            );
            expect(
              working,
              idle,
              reason:
                  'recording=$isRecording text=$hasText voice=$voiceMode — '
                  'the send button must never change because a run is open',
            );
            // There is no stop action to fall into.
            expect(
              working,
              anyOf(
                ComposerAction.send,
                ComposerAction.sendAudio,
                ComposerAction.voiceMode,
              ),
            );
          }
        }
      }
    });

    test('recording sends the recording; an empty field offers voice mode', () {
      expect(
        composerActionFor(
          isRecording: true,
          isWorking: true,
          hasText: false,
          voiceModeEnabled: true,
        ),
        ComposerAction.sendAudio,
      );
      expect(
        composerActionFor(
          isRecording: false,
          isWorking: false,
          hasText: false,
          voiceModeEnabled: true,
        ),
        ComposerAction.voiceMode,
      );
      expect(
        composerActionFor(
          isRecording: false,
          isWorking: false,
          hasText: false,
          voiceModeEnabled: false,
        ),
        ComposerAction.send,
      );
    });
  });
}
