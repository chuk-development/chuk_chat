import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Continuous microphone capture with energy-based endpointing.
///
/// The assistant listens without a push-to-talk button, so something has to
/// decide where one utterance ends. This does it on the raw PCM the `record`
/// package already streams for voice input: an adaptive noise floor, a short
/// pre-roll so the first syllable is not clipped, and a silence hold that
/// closes the utterance.
///
/// A neural endpointer (Silero) would be more precise, but the `vad` package
/// pins `record` at ^6.1.2 while this app is on ^7.1.1 — taking it would drag
/// the whole voice-input path back a major version for one screen.
class AssistantMicrophone {
  AssistantMicrophone({required this.onUtterance, this.onLevel});

  /// One complete utterance as a 16 kHz mono WAV file.
  final void Function(Uint8List wav) onUtterance;

  /// Smoothed input level, 0..1, for the waveform.
  final void Function(double level)? onLevel;

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int _bytesPerSample = 2;

  /// Audio kept before speech is confirmed, so the onset is not cut off.
  static const Duration _preRoll = Duration(milliseconds: 320);

  /// Silence after speech that closes the utterance.
  static const Duration _silenceHold = Duration(milliseconds: 750);

  /// Speech shorter than this is a cough, a door, or a clipped word.
  static const Duration _minUtterance = Duration(milliseconds: 350);

  /// Hard cap so a noisy room cannot record forever.
  static const Duration _maxUtterance = Duration(seconds: 30);

  /// Absolute floor. Below this nothing counts as speech, however quiet the
  /// room is — otherwise the noise floor adapts down to silence itself.
  static const double _absoluteFloor = 0.012;

  /// Speech must exceed the tracked noise floor by this factor.
  static const double _floorMultiplier = 3.2;

  /// Created on first use, not in the constructor: building one touches a
  /// platform channel, and the endpointer itself is pure arithmetic that has
  /// to stay constructible without a Flutter binding.
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;

  final BytesBuilder _utterance = BytesBuilder(copy: false);
  final List<Uint8List> _preRollChunks = <Uint8List>[];
  int _preRollBytes = 0;

  double _noiseFloor = _absoluteFloor;
  double _level = 0;
  bool _inSpeech = false;
  Duration _speechLength = Duration.zero;
  Duration _silenceLength = Duration.zero;
  bool _paused = false;
  bool _running = false;

  bool get isRunning => _running;
  bool get isPaused => _paused;
  double get level => _level;

  AudioRecorder get _activeRecorder => _recorder ??= AudioRecorder();

  /// True when the OS granted the microphone. Asks if it has not been asked.
  Future<bool> hasPermission() => _activeRecorder.hasPermission();

  Future<bool> start() async {
    if (_running) return true;
    if (!await _activeRecorder.hasPermission()) return false;
    try {
      final stream = await _activeRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: channels,
        ),
      );
      _subscription = stream.listen(_onChunk, onError: (Object error) {
        if (kDebugMode) debugPrint('assistant mic stream error: $error');
      });
      _running = true;
      return true;
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint('assistant mic failed to start: $error\n$stack');
      }
      return false;
    }
  }

  /// Stops feeding the endpointer without tearing the recorder down. Used
  /// while the answer is spoken, so the assistant never transcribes itself.
  void pause() {
    if (_paused) return;
    _paused = true;
    _resetUtterance();
    _setLevel(0);
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _resetUtterance();
  }

  Future<void> dispose() async {
    _running = false;
    await _subscription?.cancel();
    _subscription = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {
        // Already stopped, or the platform tore the session down for us.
      }
      await recorder.dispose();
    }
    _resetUtterance();
  }

  /// Feeds one PCM chunk through the endpointer without a real recorder.
  @visibleForTesting
  void debugFeed(Uint8List chunk) => _onChunk(chunk);

  void _onChunk(Uint8List chunk) {
    if (chunk.length < _bytesPerSample) return;
    final duration = _durationOf(chunk.length);
    final rms = _rms(chunk);
    _setLevel(math.min(1.0, rms * 4));

    if (_paused) {
      // Still track the room while muted, so resuming does not start with a
      // stale floor from before the speech output.
      _trackNoiseFloor(rms);
      return;
    }

    final threshold = math.max(_absoluteFloor, _noiseFloor * _floorMultiplier);
    final isSpeech = rms >= threshold;

    if (!_inSpeech) {
      _trackNoiseFloor(rms);
      if (!isSpeech) {
        _pushPreRoll(chunk);
        return;
      }
      // Speech started. The pre-roll carries the onset that is already gone.
      // This chunk is NOT in it — it is appended below like every other one,
      // and pushing it here first would write it into the utterance twice.
      _inSpeech = true;
      _speechLength = Duration.zero;
      _silenceLength = Duration.zero;
      for (final buffered in _preRollChunks) {
        _utterance.add(buffered);
      }
      _preRollChunks.clear();
      _preRollBytes = 0;
    }

    _utterance.add(chunk);
    _speechLength += duration;
    _silenceLength = isSpeech ? Duration.zero : _silenceLength + duration;

    if (_silenceLength >= _silenceHold || _speechLength >= _maxUtterance) {
      _finishUtterance();
    }
  }

  void _finishUtterance() {
    final voiced = _speechLength - _silenceLength;
    final pcm = _utterance.takeBytes();
    _resetUtterance();
    if (voiced < _minUtterance) return;
    onUtterance(pcmToWav(pcm, sampleRate: sampleRate, channels: channels));
  }

  void _resetUtterance() {
    _utterance.clear();
    _preRollChunks.clear();
    _preRollBytes = 0;
    _inSpeech = false;
    _speechLength = Duration.zero;
    _silenceLength = Duration.zero;
  }

  void _pushPreRoll(Uint8List chunk) {
    _preRollChunks.add(chunk);
    _preRollBytes += chunk.length;
    final limit = _bytesOf(_preRoll);
    while (_preRollBytes > limit && _preRollChunks.length > 1) {
      _preRollBytes -= _preRollChunks.removeAt(0).length;
    }
  }

  /// Slow exponential tracking of the room. Rises slowly and falls quickly, so
  /// a passing truck does not deafen the assistant for the next minute.
  void _trackNoiseFloor(double rms) {
    final alpha = rms > _noiseFloor ? 0.02 : 0.15;
    _noiseFloor = _noiseFloor * (1 - alpha) + rms * alpha;
    if (_noiseFloor < _absoluteFloor / 4) _noiseFloor = _absoluteFloor / 4;
  }

  void _setLevel(double value) {
    final smoothed = _level * 0.6 + value.clamp(0.0, 1.0) * 0.4;
    if ((smoothed - _level).abs() < 0.01 && value != 0) return;
    _level = smoothed;
    onLevel?.call(_level);
  }

  static Duration _durationOf(int bytes) => Duration(
    microseconds:
        (bytes / (_bytesPerSample * channels) / sampleRate * 1e6).round(),
  );

  static int _bytesOf(Duration duration) =>
      (duration.inMicroseconds / 1e6 * sampleRate).round() *
      _bytesPerSample *
      channels;

  static double _rms(Uint8List chunk) {
    final view = ByteData.sublistView(chunk);
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      final sample = view.getInt16(i, Endian.little) / 32768.0;
      sum += sample * sample;
      count++;
    }
    if (count == 0) return 0;
    return math.sqrt(sum / count);
  }
}

/// Wraps raw 16-bit little-endian PCM in a 44-byte RIFF header.
Uint8List pcmToWav(
  Uint8List pcm, {
  required int sampleRate,
  required int channels,
}) {
  const int bitsPerSample = 16;
  final int byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final int blockAlign = channels * (bitsPerSample ~/ 8);
  final int dataSize = pcm.length;

  final header = ByteData(44);
  _writeAscii(header, 0, 'RIFF');
  header.setUint32(4, 36 + dataSize, Endian.little);
  _writeAscii(header, 8, 'WAVE');
  _writeAscii(header, 12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  _writeAscii(header, 36, 'data');
  header.setUint32(40, dataSize, Endian.little);

  final out = Uint8List(44 + dataSize);
  out.setRange(0, 44, header.buffer.asUint8List());
  out.setRange(44, 44 + dataSize, pcm);
  return out;
}

void _writeAscii(ByteData buffer, int offset, String value) {
  for (var i = 0; i < value.length; i++) {
    buffer.setUint8(offset + i, value.codeUnitAt(i));
  }
}
