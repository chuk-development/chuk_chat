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

  /// The effective communication output, confirmed by Android.
  ///
  /// Returns `speaker`, `earpiece`, `bluetooth`, `wired`, or `unknown`; other
  /// platforms return null and continue using their LiveKit audio handling.
  Future<String?> readRoute() async {
    if (!isAndroid) return null;
    return channel.invokeMethod<String>('getCallAudioRoute');
  }

  /// Switches the actual Android call output and waits for confirmation.
  ///
  /// Call after changing LiveKit's speaker preference so that both routing
  /// owners agree. A refused or unconfirmed change throws [PlatformException]
  /// rather than making the UI display a route that never became active.
  Future<String?> setSpeaker(bool speaker) async {
    if (!isAndroid) return null;
    return channel.invokeMethod<String>('setCallSpeaker', {'speaker': speaker});
  }

  /// Every output the call can use now (`speaker`, `earpiece`, `bluetooth`,
  /// `wired`), Bluetooth with the headset's name. Empty off Android.
  Future<List<VoiceOutputDevice>> readDevices() async {
    if (!isAndroid) return const <VoiceOutputDevice>[];
    final raw = await channel.invokeListMethod<Object?>('getCallAudioDevices');
    return <VoiceOutputDevice>[
      for (final entry in raw ?? const <Object?>[])
        if (entry is Map && entry['route'] is String)
          VoiceOutputDevice(
            route: entry['route'] as String,
            name: (entry['name'] as String?) ?? '',
          ),
    ];
  }

  /// Switches the call to [route] and waits for Android to confirm it.
  Future<String?> setRoute(String route) async {
    if (!isAndroid) return null;
    return channel.invokeMethod<String>('setCallAudioRoute', {'route': route});
  }

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

/// One call audio output as Android lists it.
@immutable
class VoiceOutputDevice {
  const VoiceOutputDevice({required this.route, this.name = ''});

  /// `speaker`, `earpiece`, `bluetooth` or `wired`.
  final String route;

  /// The device's own name, e.g. the Bluetooth headset's. May be empty.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is VoiceOutputDevice && other.route == route && other.name == name;

  @override
  int get hashCode => Object.hash(route, name);
}
