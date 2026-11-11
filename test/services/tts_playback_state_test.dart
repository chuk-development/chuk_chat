import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tts_audio_service.dart';

/// A fake native player: it keeps a position, so a test can see whether a
/// resume continues or starts the audio again.
class _FakePlayer {
  final StreamController<void> completion = StreamController<void>.broadcast(
    sync: true,
  );
  final List<int> played = [];
  final List<String> calls = [];
  int position = 0;
  Completer<void> started = Completer<void>();

  Future<void> play(Uint8List bytes) async {
    played.add(bytes.first);
    position = 0;
    calls.add('play ${bytes.first}');
    if (!started.isCompleted) started.complete();
  }

  Future<void> pause() async => calls.add('pause@$position');
  Future<void> resume() async => calls.add('resume@$position');
  Future<void> stop() async {
    position = 0;
    calls.add('stop');
  }

  void finishChunk() => completion.add(null);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakePlayer player;
  late TtsPlaybackController playback;

  setUp(() {
    player = _FakePlayer();
    playback = TtsPlaybackController(
      playAudio: player.play,
      stopAudio: player.stop,
      pauseAudio: player.pause,
      resumeAudio: player.resume,
      onComplete: player.completion.stream,
    );
  });

  tearDown(() async {
    await playback.stop();
    await player.completion.close();
  });

  test('idle -> loading -> playing -> paused -> playing at the saved '
      'position -> idle', () async {
    expect(playback.phase.value, TtsPhase.idle);
    final audio = Completer<Uint8List>();
    final speaking = playback.speak(
      ['one'],
      answerText: 'Answer',
      loadAudio: (_) => audio.future,
      isCurrent: () => true,
    );
    await _settle();
    expect(playback.phase.value, TtsPhase.loading);
    expect(playback.isPlaying.value, isTrue);

    audio.complete(Uint8List.fromList([1]));
    await player.started.future;
    expect(playback.phase.value, TtsPhase.playing);

    player.position = 42;
    await playback.speak(
      ['one'],
      answerText: 'Answer',
      loadAudio: (_) => throw StateError('must not load again'),
      isCurrent: () => true,
    );
    expect(playback.phase.value, TtsPhase.paused);
    expect(playback.activeText.value, 'Answer');
    expect(player.calls.last, 'pause@42');

    await playback.speak(
      ['one'],
      answerText: 'Answer',
      loadAudio: (_) => throw StateError('must not load again'),
      isCurrent: () => true,
    );
    expect(playback.phase.value, TtsPhase.playing);
    // Resume continues at 42; the audio is not played again from the start.
    expect(player.calls.last, 'resume@42');
    expect(player.played, [1]);
    expect(player.calls.where((c) => c == 'stop').length, 1);

    player.finishChunk();
    await speaking;
    expect(playback.phase.value, TtsPhase.idle);
    expect(playback.activeText.value, isNull);
  });

  test('a tap while loading cancels the load and starts nothing', () async {
    final audio = Completer<Uint8List>();
    var loads = 0;
    final speaking = playback.speak(
      ['one'],
      answerText: 'Answer',
      loadAudio: (_) {
        loads++;
        return audio.future;
      },
      isCurrent: () => true,
    );
    await _settle();
    expect(playback.phase.value, TtsPhase.loading);
    await playback.toggle();
    await speaking;
    expect(playback.phase.value, TtsPhase.idle);
    audio.complete(Uint8List.fromList([1]));
    await _settle();
    expect(player.played, isEmpty);
    expect(loads, 1);
  });

  test('another answer resets a paused position', () async {
    final first = playback.speak(
      ['one'],
      answerText: 'First',
      loadAudio: (_) async => Uint8List.fromList([1]),
      isCurrent: () => true,
    );
    await player.started.future;
    player.position = 30;
    await playback.toggle();
    expect(playback.phase.value, TtsPhase.paused);

    player.started = Completer<void>();
    final second = playback.speak(
      ['two'],
      answerText: 'Second',
      loadAudio: (_) async => Uint8List.fromList([2]),
      isCurrent: () => true,
    );
    await first;
    await player.started.future;
    expect(playback.activeText.value, 'Second');
    expect(playback.phase.value, TtsPhase.playing);
    expect(player.played, [1, 2]);
    expect(player.position, 0);
    expect(player.calls, isNot(contains('resume@30')));

    player.finishChunk();
    await second;
    expect(playback.phase.value, TtsPhase.idle);
  });

  test(
    'the same answer after the end starts again from the beginning',
    () async {
      final first = playback.speak(
        ['one'],
        answerText: 'Answer',
        loadAudio: (_) async => Uint8List.fromList([1]),
        isCurrent: () => true,
      );
      await player.started.future;
      player.finishChunk();
      await first;
      expect(playback.phase.value, TtsPhase.idle);

      player.started = Completer<void>();
      final again = playback.speak(
        ['one'],
        answerText: 'Answer',
        loadAudio: (_) async => Uint8List.fromList([1]),
        isCurrent: () => true,
      );
      await player.started.future;
      expect(playback.phase.value, TtsPhase.playing);
      expect(player.played, [1, 1]);
      player.finishChunk();
      await again;
    },
  );

  test('a pause between chunks holds the next chunk until resume', () async {
    final speaking = playback.speak(
      ['one', 'two'],
      answerText: 'Answer',
      loadAudio: (chunk) async => Uint8List.fromList([chunk == 'one' ? 1 : 2]),
      isCurrent: () => true,
    );
    await player.started.future;
    await playback.pause();
    expect(playback.phase.value, TtsPhase.paused);
    // The first chunk ends at the pause point; the second must wait.
    player.finishChunk();
    await _settle();
    await _settle();
    expect(player.played, [1]);

    await playback.resume();
    await _settle();
    await _settle();
    expect(player.played, [1, 2]);
    // The finished chunk is not in the player, so no native resume.
    expect(player.calls.where((c) => c.startsWith('resume')), isEmpty);
    player.finishChunk();
    await speaking;
    expect(playback.phase.value, TtsPhase.idle);
  });

  test('stop while paused ends the answer', () async {
    final speaking = playback.speak(
      ['one'],
      loadAudio: (_) async => Uint8List.fromList([1]),
      isCurrent: () => true,
    );
    await player.started.future;
    await playback.pause();
    await playback.stop();
    await speaking;
    expect(playback.phase.value, TtsPhase.idle);
    expect(playback.isPlaying.value, isFalse);
    expect(playback.activeText.value, isNull);
  });
}
