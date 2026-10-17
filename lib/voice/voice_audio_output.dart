import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android WebRTC uses the call-volume stream, independent of media volume.
class VoiceAudioOutput {
  const VoiceAudioOutput({
    this.channel = const MethodChannel('chuk/voice_call'),
  });

  final MethodChannel channel;

  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<double?> readVolume() async {
    if (!isAndroid) return null;
    final value = await channel.invokeMethod<num>('getCallVolume');
    return value?.toDouble().clamp(0.0, 1.0);
  }

  Future<double> setVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0);
    if (!isAndroid) return normalized;
    final actual = await channel.invokeMethod<num>('setCallVolume', {
      'volume': normalized,
    });
    return actual?.toDouble().clamp(0.0, 1.0) ?? normalized;
  }

  /// Makes the phone's physical volume buttons adjust this same stream.
  Future<void> setCallActive(bool active) async {
    if (!isAndroid) return;
    await channel.invokeMethod<void>('setCallVolumeControls', {
      'active': active,
    });
  }
}
