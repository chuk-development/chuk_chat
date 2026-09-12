import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/assistant/assistant_microphone.dart';

/// One chunk of PCM16 at the given amplitude (0..1), as a 400 Hz tone so the
/// RMS is a real signal rather than a DC offset.
Uint8List _chunk({required double amplitude, Duration length = _frame}) {
  final samples =
      (length.inMicroseconds / 1e6 * AssistantMicrophone.sampleRate).round();
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    final value =
        math.sin(2 * math.pi * 400 * i / AssistantMicrophone.sampleRate) *
        amplitude *
        32767;
    view.setInt16(i * 2, value.round(), Endian.little);
  }
  return bytes;
}

const Duration _frame = Duration(milliseconds: 32);

void _feed(
  AssistantMicrophone mic, {
  required double amplitude,
  required Duration total,
}) {
  final frames = (total.inMilliseconds / _frame.inMilliseconds).ceil();
  for (var i = 0; i < frames; i++) {
    mic.debugFeed(_chunk(amplitude: amplitude));
  }
}

void main() {
  group('pcmToWav', () {
    test('writes a 44 byte RIFF header in front of the samples', () {
      final pcm = Uint8List.fromList(List<int>.filled(320, 7));
      final wav = pcmToWav(pcm, sampleRate: 16000, channels: 1);

      expect(wav.length, 44 + pcm.length);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');

      final header = ByteData.sublistView(wav, 0, 44);
      expect(header.getUint32(4, Endian.little), 36 + pcm.length);
      expect(header.getUint16(20, Endian.little), 1, reason: 'PCM format tag');
      expect(header.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint32(28, Endian.little), 32000, reason: 'byte rate');
      expect(header.getUint16(34, Endian.little), 16, reason: 'bit depth');
      expect(header.getUint32(40, Endian.little), pcm.length);
      expect(wav.sublist(44), pcm);
    });
  });

  group('AssistantMicrophone endpointing', () {
    test('silence alone never produces an utterance', () {
      final utterances = <Uint8List>[];
      final mic = AssistantMicrophone(onUtterance: utterances.add);

      _feed(mic, amplitude: 0.001, total: const Duration(seconds: 3));

      expect(utterances, isEmpty);
    });

    test('speech followed by silence closes exactly one utterance', () {
      final utterances = <Uint8List>[];
      final mic = AssistantMicrophone(onUtterance: utterances.add);

      _feed(mic, amplitude: 0.002, total: const Duration(milliseconds: 500));
      _feed(mic, amplitude: 0.35, total: const Duration(milliseconds: 900));
      _feed(mic, amplitude: 0.002, total: const Duration(milliseconds: 1200));

      expect(utterances, hasLength(1));
      // The pre-roll must be in front of the speech, so the utterance is
      // longer than the speech alone.
      final pcmBytes = utterances.single.length - 44;
      const speechBytes = 900 * 2 * AssistantMicrophone.sampleRate ~/ 1000;
      expect(pcmBytes, greaterThan(speechBytes));
    });

    test('a click shorter than the minimum is discarded', () {
      final utterances = <Uint8List>[];
      final mic = AssistantMicrophone(onUtterance: utterances.add);

      _feed(mic, amplitude: 0.002, total: const Duration(milliseconds: 400));
      _feed(mic, amplitude: 0.4, total: const Duration(milliseconds: 64));
      _feed(mic, amplitude: 0.002, total: const Duration(milliseconds: 1200));

      expect(utterances, isEmpty);
    });

    test('two utterances separated by silence are reported separately', () {
      final utterances = <Uint8List>[];
      final mic = AssistantMicrophone(onUtterance: utterances.add);

      for (var turn = 0; turn < 2; turn++) {
        _feed(mic, amplitude: 0.3, total: const Duration(milliseconds: 800));
        _feed(mic, amplitude: 0.002, total: const Duration(milliseconds: 1200));
      }

      expect(utterances, hasLength(2));
    });

    test('nothing is reported while paused, and listening resumes after', () {
      final utterances = <Uint8List>[];
      final mic = AssistantMicrophone(onUtterance: utterances.add);

      mic.pause();
      _feed(mic, amplitude: 0.4, total: const Duration(milliseconds: 900));
      _feed(mic, amplitude: 0.002, total: const Duration(milliseconds: 1200));
      expect(utterances, isEmpty, reason: 'the assistant was speaking');

      mic.resume();
      _feed(mic, amplitude: 0.4, total: const Duration(milliseconds: 900));
      _feed(mic, amplitude: 0.002, total: const Duration(milliseconds: 1200));
      expect(utterances, hasLength(1));
    });

    test('loud room noise raises the floor instead of triggering forever', () {
      final utterances = <Uint8List>[];
      final mic = AssistantMicrophone(onUtterance: utterances.add);

      // Constant noise well above the absolute floor: the tracker has to catch
      // up, so the stream must not decay into one endless utterance.
      _feed(mic, amplitude: 0.05, total: const Duration(seconds: 6));

      expect(utterances.length, lessThanOrEqualTo(1));
    });

    test('level callback reports a rising level for louder input', () {
      final levels = <double>[];
      final mic = AssistantMicrophone(
        onUtterance: (_) {},
        onLevel: levels.add,
      );

      _feed(mic, amplitude: 0.02, total: const Duration(milliseconds: 200));
      final quiet = levels.last;
      _feed(mic, amplitude: 0.6, total: const Duration(milliseconds: 400));

      expect(levels.last, greaterThan(quiet));
      expect(levels.every((level) => level >= 0 && level <= 1), isTrue);
    });
  });
}
