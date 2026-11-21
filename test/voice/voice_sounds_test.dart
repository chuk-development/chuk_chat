import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/voice/voice_sounds.dart';

void main() {
  test('the hang-up chime is a short quiet click-free mono WAV', () {
    final Uint8List bytes = VoiceSounds.wav(const <(double, double, double)>[
      (0.0, 987.77, 0.35),
      (0.11, 659.25, 0.5),
    ], gain: 0.22);
    final ByteData data = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(24, Endian.little), 24000);
    final int samples = (bytes.length - 44) ~/ 2;
    expect(samples / 24000, closeTo(0.61, 0.02));
    var peak = 0;
    for (var i = 0; i < samples; i++) {
      final int v = data.getInt16(44 + i * 2, Endian.little).abs();
      if (v > peak) peak = v;
    }
    expect(peak, lessThan(0.3 * 32767));
    expect(data.getInt16(44, Endian.little).abs(), lessThan(200));
    expect(data.getInt16(bytes.length - 2, Endian.little).abs(), lessThan(200));
  });

  test('hangUp is silent under flutter test', () {
    VoiceSounds.hangUp();
  });
}
