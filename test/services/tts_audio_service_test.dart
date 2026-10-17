import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tts_audio_service.dart';

void main() {
  test('idle controls do not initialize native playback', () async {
    expect(TtsAudioService.activeText.value, isNull);
    expect(TtsAudioService.isPlaying.value, isFalse);
    await TtsAudioService.stop();
  });

  group('read-aloud playback cancellation', () {
    late StreamController<void> completion;
    late List<int> played;
    late TtsPlaybackController playback;
    late Completer<void> started;
    var scopeIsCurrent = true;

    setUp(() {
      completion = StreamController<void>.broadcast(sync: true);
      played = [];
      started = Completer<void>();
      scopeIsCurrent = true;
      playback = TtsPlaybackController(
        playAudio: (bytes) async {
          played.add(bytes.first);
          if (!started.isCompleted) started.complete();
        },
        stopAudio: () async {},
        onComplete: completion.stream,
      );
    });

    tearDown(() async {
      await playback.stop();
      await completion.close();
    });

    test(
      'stopping completes a call without a native completion event',
      () async {
        final speaking = playback.speak(
          ['one', 'two'],
          loadAudio: (_) async => Uint8List.fromList([1]),
          isCurrent: () => scopeIsCurrent,
        );
        await started.future;
        expect(playback.isPlaying.value, isTrue);
        await playback.stop();
        await speaking;
        expect(played, [1]);
        expect(playback.isPlaying.value, isFalse);
      },
    );

    test('the same answer stops while audio is still loading', () async {
      final audio = Completer<Uint8List>();
      final loading = Completer<void>();
      final speaking = playback.speak(
        ['one'],
        answerText: 'Complete answer',
        loadAudio: (_) {
          loading.complete();
          return audio.future;
        },
        isCurrent: () => true,
      );
      await loading.future;
      expect(playback.activeText.value, 'Complete answer');
      expect(playback.isPlaying.value, isTrue);
      await playback.speak(
        ['one'],
        answerText: 'Complete answer',
        loadAudio: (_) => throw StateError('must not generate twice'),
        isCurrent: () => true,
      );
      await speaking;
      expect(playback.activeText.value, isNull);
      expect(playback.isPlaying.value, isFalse);
      audio.complete(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      expect(played, isEmpty);
    });

    test('the same answer stops during playback', () async {
      final speaking = playback.speak(
        ['one'],
        loadAudio: (_) async => Uint8List.fromList([1]),
        isCurrent: () => true,
      );
      await started.future;
      expect(playback.activeText.value, 'one');
      await playback.speak(
        ['one'],
        loadAudio: (_) => throw StateError('must not generate twice'),
        isCurrent: () => true,
      );
      await speaking;
      expect(playback.activeText.value, isNull);
      expect(played, [1]);
    });

    test('new answer interrupts loading and old audio never starts', () async {
      final oldAudio = Completer<Uint8List>();
      final loading = Completer<void>();
      final old = playback.speak(
        ['old'],
        loadAudio: (_) {
          loading.complete();
          return oldAudio.future;
        },
        isCurrent: () => scopeIsCurrent,
      );
      await loading.future;
      final next = playback.speak(
        ['next'],
        loadAudio: (_) async => Uint8List.fromList([2]),
        isCurrent: () => scopeIsCurrent,
      );
      await started.future;
      oldAudio.complete(Uint8List.fromList([1]));
      await old;
      expect(played, [2]);
      completion.add(null);
      await next;
      expect(playback.isPlaying.value, isFalse);
    });

    test('changed auth or encryption scope discards generated audio', () async {
      final audio = Completer<Uint8List>();
      final loading = Completer<void>();
      final speaking = playback.speak(
        ['private'],
        loadAudio: (_) {
          loading.complete();
          return audio.future;
        },
        isCurrent: () => scopeIsCurrent,
      );
      await loading.future;
      scopeIsCurrent = false;
      audio.complete(Uint8List.fromList([1]));
      await speaking;
      expect(played, isEmpty);
      expect(playback.isPlaying.value, isFalse);
    });

    test('older pending stop cannot replace a newer answer', () async {
      final firstStop = Completer<void>();
      var stopCount = 0;
      playback = TtsPlaybackController(
        playAudio: (bytes) async {
          played.add(bytes.first);
          if (!started.isCompleted) started.complete();
        },
        stopAudio: () {
          stopCount++;
          return stopCount == 1 ? firstStop.future : Future.value();
        },
        onComplete: completion.stream,
      );
      final old = playback.speak(
        ['old'],
        loadAudio: (_) async => Uint8List.fromList([1]),
        isCurrent: () => true,
      );
      final next = playback.speak(
        ['new'],
        loadAudio: (_) async => Uint8List.fromList([2]),
        isCurrent: () => true,
      );
      await started.future;
      firstStop.complete();
      await old;
      expect(played, [2]);
      completion.add(null);
      await next;
    });

    test(
      'generation error clears busy state and allows a new answer',
      () async {
        await expectLater(
          playback.speak(
            ['failed'],
            loadAudio: (_) async => throw StateError('service unavailable'),
            isCurrent: () => true,
          ),
          throwsStateError,
        );
        expect(playback.isPlaying.value, isFalse);
        final next = playback.speak(
          ['retry'],
          loadAudio: (_) async => Uint8List.fromList([2]),
          isCurrent: () => true,
        );
        await started.future;
        completion.add(null);
        await next;
        expect(played, [2]);
      },
    );
  });
  group('TtsAudioService text chunking', () {
    test('keeps short answers in a single chunk', () {
      expect(TtsAudioService.splitTextForTesting('Hello, world!'), <String>[
        'Hello, world!',
      ]);
    });

    test('splits long answers below the provider limit', () {
      final text = List<String>.filled(9000, 'a').join();

      final chunks = TtsAudioService.splitTextForTesting(text);

      expect(chunks.length, 3);
      expect(chunks.every((chunk) => chunk.length <= 3800), isTrue);
      expect(chunks.join(), text);
    });

    test('never splits an emoji surrogate pair', () {
      final text = '${List<String>.filled(3799, 'a').join()}😀tail';

      final chunks = TtsAudioService.splitTextForTesting(text);

      expect(chunks.join(), text);
      expect(chunks.any((chunk) => chunk.contains('😀')), isTrue);
      expect(chunks.every((chunk) => chunk.length <= 3800), isTrue);
    });
  });
}
