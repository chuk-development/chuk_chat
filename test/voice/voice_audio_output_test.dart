import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/voice/voice_audio_output.dart';
import 'package:chuk_chat/voice/voice_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chuk/voice_call');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'getCallVolume' => 0.4,
            'setCallVolume' => 0.8,
            _ => null,
          };
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'call slider reads actual hardware level and honors native rounding',
    () async {
      const output = VoiceAudioOutput();
      expect(await output.readVolume(), 0.4);
      expect(await output.setVolume(0.75), 0.8);
      expect(calls.last.arguments, {'volume': 0.75});
      await output.setCallActive(true);
      expect(calls.last.method, 'setCallVolumeControls');
      expect(calls.last.arguments, {'active': true});
      await output.setCallActive(false);
      expect(calls.last.arguments, {'active': false});
    },
  );

  test('other platforms do not touch the Android volume channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    const output = VoiceAudioOutput();
    expect(await output.readVolume(), isNull);
    expect(await output.setVolume(1.8), 1);
    await output.setCallActive(true);
    expect(calls, isEmpty);
  });

  test('default voice remains separate for each signed-in account', () async {
    SharedPreferences.setMockInitialValues({});
    await VoicePreferences.saveLocal('user-a', 'Ashley');
    await VoicePreferences.saveLocal('user-b', 'Dennis');
    expect(await VoicePreferences.loadLocal('user-a'), 'Ashley');
    expect(await VoicePreferences.loadLocal('user-b'), 'Dennis');
    expect(await VoicePreferences.loadLocal('user-c'), isNull);
  });
}
