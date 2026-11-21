import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plain call sounds played by the app.
///
/// The connect chime and the "working" pulse come from the voice worker on
/// the call's own audio track (api_server `voice/earcons.py`). The hang-up
/// sound plays here, because the room is already gone when it is due. It is
/// made in code with the worker's note shape, so both sound like one set.
class VoiceSounds {
  VoiceSounds._();

  static AudioPlayer? _player;
  static Uint8List? _hangUp;

  static bool get _enabled {
    if (kIsWeb) return true;
    try {
      return !Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return true;
    }
  }

  /// Two falling notes (B5 -> E5), quiet.
  static void hangUp() {
    if (!_enabled) return;
    unawaited(() async {
      try {
        final AudioPlayer player = _player ??= AudioPlayer()
          ..setPlayerMode(PlayerMode.lowLatency);
        final Uint8List sound = _hangUp ??= wav(<(double, double, double)>[
          (0.0, 987.77, 0.35),
          (0.11, 659.25, 0.5),
        ], gain: 0.22);
        await player.play(BytesSource(sound, mimeType: 'audio/wav'));
      } catch (e) {
        if (kDebugMode)
          debugPrint('[VoiceCall] hang-up sound: ${e.runtimeType}');
      }
    }());
  }

  /// A 16-bit mono 24 kHz WAV of soft bell notes `(start s, Hz, length s)`.
  @visibleForTesting
  static Uint8List wav(
    List<(double, double, double)> notes, {
    required double gain,
    int sampleRate = 24000,
  }) {
    final double end = notes.map((n) => n.$1 + n.$3).fold<double>(0, math.max);
    final int count = (end * sampleRate).ceil();
    final Float64List mix = Float64List(count);
    for (final (double start, double freq, double length) in notes) {
      final int offset = (start * sampleRate).round();
      final int n = (length * sampleRate).round();
      final int attack = (0.008 * sampleRate).round();
      final int tail = (0.02 * sampleRate).round();
      for (var i = 0; i < n && offset + i < count; i++) {
        final double t = i / sampleRate;
        double env = math.exp(-6 * t);
        if (i < attack) env *= i / attack;
        if (i > n - tail) env *= (n - i) / tail;
        final double wave =
            math.sin(2 * math.pi * freq * t) +
            0.18 * math.sin(2 * math.pi * 2 * freq * t);
        mix[offset + i] += wave * env / 1.18;
      }
    }
    final ByteData data = ByteData(44 + count * 2);
    void ascii(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + count * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, count * 2, Endian.little);
    for (var i = 0; i < count; i++) {
      final int v = (mix[i] * gain * 32767).round().clamp(-32768, 32767);
      data.setInt16(44 + i * 2, v, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
