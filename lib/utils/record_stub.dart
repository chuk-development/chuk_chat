// lib/utils/record_stub.dart
// Web stub for package:record
import 'dart:async';

class AudioRecorder {
  Future<bool> hasPermission() async => false;
  Future<void> start(RecordConfig config, {required String path}) async {}
  Future<String?> stop() async => null;
  Future<void> dispose() async {}
  Future<bool> isRecording() async => false;
  Stream<Amplitude> onAmplitudeChanged(Duration interval) {
    return Stream.empty();
  }
}

class RecordConfig {
  final AudioEncoder encoder;
  final int sampleRate;
  final int bitRate;

  const RecordConfig({
    this.encoder = AudioEncoder.wav,
    this.sampleRate = 16000,
    this.bitRate = 128000,
  });
}

enum AudioEncoder { wav, aacLc, flac, opus }

class Amplitude {
  final double current;
  final double max;
  const Amplitude({this.current = -160.0, this.max = -160.0});
}
